module LedgerIntegration (ledgerFaultCases) where

import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target qualified as Target
import ClickHouseMigrate.TestSupport.ExclusiveAccess (hostLocalExclusiveAccess)
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Concurrent (threadDelay)
import Data.Aeson (FromJSON, Key, Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

assert :: String -> Bool -> IO ()
assert label predicate = unless predicate (fail ("ledger integration: " ++ label))

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

field :: (FromJSON a) => Key -> Value -> IO a
field key (Object members) = maybe (fail "Missing ledger test field") convert (KM.lookup key members)
field _ _ = fail "Invalid ledger test object"

convert :: (FromJSON a) => Value -> IO a
convert value = case Aeson.fromJSON value of Aeson.Success result -> pure result; Aeson.Error _ -> fail "Invalid ledger test field type"

data FixtureTarget = FixtureTarget !Server !Text !Target.TargetKey !Target.ServerId !Target.LedgerId

newTarget :: Server -> Text -> IO FixtureTarget
newTarget server namespace = do
  _ <- right (Target.ledgerNamespace namespace)
  key <- right (Target.targetKey ("test-target/" <> namespace))
  rows <- queryServer server "SELECT toString(serverUUID()) AS server_id" >>= convert :: IO [Value]
  identity <- case rows of [row] -> field "server_id" row >>= right . Target.serverId; _ -> fail "Missing server identity"
  ledger <- Target.newLedgerId
  pure (FixtureTarget server namespace key identity ledger)

configFor :: FixtureTarget -> Text -> Target.LedgerBinding -> IO Target.TargetConfig
configFor (FixtureTarget _ namespace key serverId _) endpoint binding =
  Target.targetConfig key <$> right (Target.directEndpoint endpoint) <*> pure serverId <*> right (Target.ledgerNamespace namespace) <*> pure binding <*> right (Target.basicCredentials "default" "test-password") <*> pure Target.defaultHttpLimits

fixtureProvider :: IO Access.ExclusiveAccess
-- The parent owns the entire isolated job. Local callback return never admits a
-- mutating successor: the parent waits for every controlled request to drain.
-- Diagnostic reconciliation is allowed while the same outer job still excludes
-- all other administrators; it never grants sequence reuse or SQL continuation.
fixtureProvider = right (Access.externallySerialized "owned-fixture-serialized-job" "complete owned target; parent excludes mutating successors until all prior requests drain" 1000000 (const (pure ())) (const (pure ())) (const (pure True)))

initialize :: FixtureTarget -> IO Ledger.LedgerPosition
initialize target@(FixtureTarget server _ key _ ledger) = do
  config <- configFor target (serverEndpoint server) Target.FirstUse
  provider <- fixtureProvider
  audit <- right (Ledger.auditContext "fixture operator" "explicit bootstrap/resumption after controlled requests finished" ["fault proxy has consumed the full upstream response; predecessor client scope closed"])
  quiet <- right (Ledger.attestQuiescence key audit)
  report <- Ledger.initializeLedger config provider (Ledger.authorizeInitialization key ledger audit) quiet
  assert "Bootstrap cleanup failed" (null (Ledger.cleanupErrors report))
  right (Ledger.result report)

runProtocol :: FilePath -> FixtureTarget -> Text -> String -> IO Value
runProtocol = runProtocolWithLimit 10000000

runProtocolWithLimit :: Int -> FilePath -> FixtureTarget -> Text -> String -> IO Value
runProtocolWithLimit micros driver (FixtureTarget server namespace _ identity ledger) endpoint operation = do
  let file = serverLogDirectory server </> Text.unpack namespace ++ "-" ++ operation ++ ".sql"
  BS.writeFile file ""
  inherited <- getEnvironment
  let overrides = [("CHM_EXPECTED_SERVER_ID", Text.unpack (Target.serverIdText identity)), ("CHM_LEDGER_NAMESPACE", Text.unpack namespace), ("CHM_LEDGER_ID", Text.unpack (Target.ledgerIdText ledger)), ("CHM_TEST_USER", "default"), ("CHM_TEST_PASSWORD", "test-password")]
      configured = overrides ++ filter (\(key, _) -> key `notElem` ("CHM_EXPECTED_LEDGER_ID" : map fst overrides)) inherited
  (status, output, _) <- readCreateProcessWithExitCode ((proc driver [operation, Text.unpack endpoint, "ledger-protocol", file, show micros, "1048576"]) {env = Just configured}) ""
  assert "Private protocol process failed" (status == ExitSuccess)
  value <- either (const (fail "Invalid private ledger protocol")) pure (Aeson.eitherDecodeStrict' (Encoding.encodeUtf8 (Text.pack output)))
  scope <- field "scopeError" value :: IO Value
  verification <- field "verificationError" value :: IO Value
  cleanup <- field "cleanupErrors" value :: IO [Value]
  access <- field "accessCleanup" value :: IO [Value]
  assert "Scope/admission/cleanup failure" (scope == Null && verification == Null && null cleanup && null access)
  pure value

store :: Value -> IO Value
store = field "store"

success :: Value -> IO Value
success value = store value >>= field "success"

readHistory :: FilePath -> FixtureTarget -> IO Value
readHistory driver target@(FixtureTarget server _ _ _ _) = runProtocol driver target (serverEndpoint server) "ledger-read" >>= success

scalar :: Server -> Text -> IO Int
scalar server sql = do
  rows <- queryServer server sql >>= convert :: IO [Value]
  case rows of [row] -> field "value" row; _ -> fail "Invalid independent ledger observation"

effect :: FixtureTarget -> IO Bool
effect (FixtureTarget server namespace _ _ _) = do
  rows <- queryServer server ("EXISTS TABLE default." <> namespace <> "_effects") >>= convert :: IO [Value]
  case rows of [row] -> (== (1 :: Int)) <$> field "result" row; _ -> fail "Invalid effect observation"

rowCount :: FixtureTarget -> IO Int
rowCount (FixtureTarget server namespace _ _ _) = scalar server ("SELECT toUInt32(count()) AS value FROM `" <> namespace <> "`.events")

reconcile :: FixtureTarget -> Ledger.AppendReceipt -> IO (Ledger.Reconciliation, Ledger.ExpectedLedgerState)
reconcile target@(FixtureTarget server _ _ _ _) receipt = do
  config <- configFor target (serverEndpoint server) Target.FirstUse
  provider <- fixtureProvider
  report <- Ledger.reconcileAppend config provider receipt
  assert "Reconciliation cleanup failed" (null (Ledger.cleanupErrors report))
  right (Ledger.result report)

ledgerFaultCases :: FilePath -> Server -> IO ()
ledgerFaultCases driver server = do
  unauthorized <- newTarget server "no_authorization"
  rejected <- runProtocol driver unauthorized (serverEndpoint server) "ledger-no-authorization" >>= store
  field "ledgerError" rejected >>= assert "Missing ledger was implicitly initialized" . (== ("InitializationNotAuthorized" :: Text))
  absent <- readHistory driver unauthorized
  field "observation" absent >>= assert "Read-only inspection initialized storage" . (== ("missing" :: Text))
  forM_Indexed
    [ (DatabaseCreation, "ddl-database", DropResponse, 0, False),
      (TableCreation, "ddl-table", DropResponse, 0, False),
      (Initialization, "initialized", DropResponse, 1, False),
      (MigrationStart, "migration-started", DropResponse, 2, False),
      (StepStart, "step-started", DropResponse, 3, False),
      (StepSuccess, "step-succeeded", DropResponse, 4, True),
      (MigrationCompletion, "migration-completed", DropResponse, 5, True),
      (StepStart, "step-started", LateError, 3, False)
    ]
    $ \index (stage, label, mode, count, hasEffect) -> do
      target <- newTarget server ("ack_fault_" <> Text.pack (show index))
      withFaultProxy server $ \proxy -> do
        setLedgerFault proxy stage mode
        report <- runProtocol driver target (proxyEndpoint proxy) "ledger-sequence"
        detail <- store report
        request <- field "request" detail :: IO Value
        field "outcome" request >>= assert "Wrong append evidence" . (== (if mode == LateError then "observed-server-failure" else "submission-uncertain" :: Text))
        received <- proxyEvents proxy >>= convert :: IO [Value]
        labels <- mapM (field "stage") received :: IO [Maybe Text]
        assert "Faulted request replayed or followed by another request" (length (filter (== Just label) labels) == 1 && last labels == Just label)
        assert "Application SQL replayed or preceded acknowledged intent" (length (filter (== Just "application-sql") labels) == if hasEffect then 1 else 0)
        assert "Forbidden SQL after unacknowledged intent" . (== hasEffect) =<< effect target
        if count == 0
          then do
            position <- initialize target
            assert "Resumed empty bootstrap changed identity" (Target.ledgerIdText (targetLedger target) `Text.isInfixOf` Ledger.ledgerPositionText position)
            assert "DDL bootstrap resumption wrote extra events" . (== 1) =<< rowCount target
          else do
            encoded <- field "receipt" detail :: IO Text
            receipt <- right (Ledger.parseAppendReceipt encoded)
            (classification, _) <- reconcile target receipt
            assert "Exact event not reconciled" (classification == Ledger.PresentIdentical)
            assert "Reconciliation duplicated a row" . (== count) =<< rowCount target
            inspected <- readHistory driver target
            field "eventCount" inspected >>= assert "Wrong event prefix" . (== count)
            field "unresolved" inspected >>= assert "Interrupted state incorrectly resolved" . (== (count `elem` [2, 3, 4]))
            when (count > 1) (field "poisoned" report >>= assert "Unacknowledged append allowed another store write")
            -- Tokens are observations, not permission; differing digest/unknown
            -- identity returns a read-only classification at the same position.
            let parts = Text.splitOn ":" encoded
            case parts of
              [version, key, ledger, number, event, digest, query] -> do
                wrong <- right (Ledger.parseAppendReceipt (Text.intercalate ":" [version, key, ledger, number, event, if digest == Text.replicate 64 "b" then Text.replicate 64 "c" else Text.replicate 64 "b", query]))
                (conflict, _) <- reconcile target wrong
                assert "Conflicting receipt accepted" (conflict == Ledger.Conflicting)
                missing <- right (Ledger.parseAppendReceipt (Text.intercalate ":" [version, key, ledger, "999999", "00000000-0000-4000-8000-000000999999", digest, query]))
                (notObserved, _) <- reconcile target missing
                assert "NotObserved result wrong" (notObserved == Ledger.NotObserved)
                assert "Read-only reconciliation mutated history" . (== count) =<< rowCount target
              _ -> fail "Unexpected validated receipt format"
        putStrLn ("ledger fault " ++ show stage ++ "/" ++ show mode ++ ": one submission; no successor write; exact guarded reconciliation")
  protocolFamilyCases driver server
  delayedEventCases driver server
  delayedInitialization server
  bindingAndSchemaCases driver server
  corruptionCases driver server
  durable <- newTarget server "restart_history"
  before <- runProtocol driver durable (serverEndpoint server) "ledger-sequence" >>= success
  restartCandidateServer server
  after <- readHistory driver durable
  assert "Acknowledged history changed after owned server SIGKILL/restart" (before == after)
  putStrLn "ledger durability: acknowledged intent/outcomes and pinned server UUID survive owned SIGKILL/restart; no power-loss claim"
  where
    targetLedger (FixtureTarget _ _ _ _ ledger) = ledger

forM_Indexed :: [a] -> (Int -> a -> IO ()) -> IO ()
forM_Indexed values action = sequence_ (zipWith action [0 ..] values)

bindingAndSchemaCases :: FilePath -> Server -> IO ()
bindingAndSchemaCases driver server = do
  target@(FixtureTarget _ namespace key serverId ledger) <- newTarget server "binding_history"
  first <- initialize target
  second <- initialize target
  assert "Reopening bootstrap changed UUID/position" (first == second)
  foreignLedger <- Target.newLedgerId
  audit <- right (Ledger.auditContext "fixture" "test foreign identity" ["owned fixture and no outstanding requests"])
  quiet <- right (Ledger.attestQuiescence key audit)
  provider <- fixtureProvider
  wrong <- configFor target (serverEndpoint server) (Target.ExistingLedger foreignLedger)
  rejected <- Ledger.initializeLedger wrong provider (Ledger.authorizeInitialization key foreignLedger audit) quiet
  assert "Existing UUID mismatch accepted" (Ledger.result rejected == Left (Ledger.LedgerRejected Ledger.LedgerIdentityMismatch))
  wrongKey <- right (Target.targetKey "different-target")
  wrongConfig <- Target.targetConfig wrongKey <$> right (Target.directEndpoint (serverEndpoint server)) <*> pure serverId <*> right (Target.ledgerNamespace namespace) <*> pure Target.FirstUse <*> right (Target.basicCredentials "default" "test-password") <*> pure Target.defaultHttpLimits
  wrongQuiet <- right (Ledger.attestQuiescence wrongKey audit)
  misrouted <- Ledger.initializeLedger wrongConfig provider (Ledger.authorizeInitialization wrongKey ledger audit) wrongQuiet
  assert "Target binding mismatch accepted" (Ledger.result misrouted == Left (Ledger.LedgerRejected Ledger.LedgerIdentityMismatch))
  invalidDatabase <- newTarget server "wrong_database"
  _ <- queryServer server "CREATE DATABASE wrong_database ENGINE=Memory"
  databaseRejected <- runProtocol driver invalidDatabase (serverEndpoint server) "ledger-sequence" >>= store
  field "ledgerError" databaseRejected >>= assert "Non-Atomic database accepted" . (== ("InvalidLedgerSchema" :: Text))
  forM_Indexed [("wrong_engine", "Memory", "event String"), ("wrong_columns", "MergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'", "event UInt64")] $ \_ (name, engine, column) -> do
    invalid <- newTarget server name
    _ <- queryServer server ("CREATE DATABASE `" <> name <> "` ENGINE=Atomic")
    _ <- queryServer server ("CREATE TABLE `" <> name <> "`.events (sequence UInt64,event_id UUID,ledger_id UUID," <> column <> ") ENGINE=" <> engine)
    result <- runProtocol driver invalid (serverEndpoint server) "ledger-sequence" >>= store
    field "ledgerError" result >>= assert "Wrong engine/schema accepted" . (== ("InvalidLedgerSchema" :: Text))
    assert "Invalid schema executed application SQL" . not =<< effect invalid
  remote@(FixtureTarget _ remoteName remoteKey _ remoteLedger) <- newTarget server "remote_storage"
  withFaultProxy server $ \proxy -> do
    setFault proxy WeakenedStorage
    config <- configFor remote (proxyEndpoint proxy) Target.FirstUse
    remoteQuiet <- right (Ledger.attestQuiescence remoteKey audit)
    result <- Ledger.initializeLedger config provider (Ledger.authorizeInitialization remoteKey remoteLedger audit) remoteQuiet
    assert "Unqualified remote storage accepted" (Ledger.result result == Left (Ledger.LedgerRejected Ledger.UnsupportedLedgerStorage))
    count <- scalar server ("SELECT toUInt32(count()) AS value FROM system.databases WHERE name='" <> remoteName <> "'")
    assert "Remote storage rejection created objects" (count == 0)
  putStrLn "ledger preflight: absent authorization, foreign ledger/target, wrong engine/columns and unqualified remote storage reject before application writes"

corruptionCases :: FilePath -> Server -> IO ()
corruptionCases driver server = forM_Indexed ["duplicate", "gap", "sequence-conflict", "identity-conflict", "unknown-version", "foreign-ledger", "missing-initialization"] $ \index corruption -> do
  target@(FixtureTarget _ namespace _ _ _) <- newTarget server ("corruption_" <> Text.pack (show index))
  _ <- runProtocol driver target (serverEndpoint server) "ledger-sequence" >>= success
  rows <- queryServer server ("SELECT toString(sequence) AS sequence,toString(event_id) AS event_id,toString(ledger_id) AS ledger_id,event FROM `" <> namespace <> "`.events ORDER BY sequence SETTINGS max_result_rows=0,result_overflow_mode='throw'") >>= convert :: IO [Value]
  latest <- case reverse rows of row : _ -> pure row; _ -> fail "Missing corruption fixture"
  numberText <- field "sequence" latest :: IO Text
  identity <- field "event_id" latest :: IO Text
  ledger <- field "ledger_id" latest :: IO Text
  original <- field "event" latest :: IO Text
  let old = read (Text.unpack numberText) :: Int
      newNumber = if corruption `elem` ["gap", "identity-conflict"] then old + 2 else if corruption == "foreign-ledger" then old + 1 else old
      newId = if corruption `elem` ["gap", "sequence-conflict", "foreign-ledger"] then "00000000-0000-4000-8000-000000999998" else identity
      newLedger = if corruption == "foreign-ledger" then "00000000-0000-4000-8000-000000999997" else ledger
      bytes =
        Text.replace ("\"eventId\":\"" <> identity <> "\"") ("\"eventId\":\"" <> newId <> "\"") $
          Text.replace ("\"ledgerId\":\"" <> ledger <> "\"") ("\"ledgerId\":\"" <> newLedger <> "\"") $
            Text.replace ("\"sequence\":" <> numberText) ("\"sequence\":" <> Text.pack (show newNumber)) original
      changed = if corruption == "unknown-version" then Text.replace "\"version\":1" "\"version\":2" bytes else bytes
      payload = object ["sequence" .= newNumber, "event_id" .= newId, "ledger_id" .= newLedger, "event" .= changed]
  _ <-
    if corruption == "missing-initialization"
      then
        queryServer server ("ALTER TABLE `" <> namespace <> "`.events DELETE WHERE sequence=1 SETTINGS mutations_sync=1")
      else queryServer server ("INSERT INTO `" <> namespace <> "`.events SETTINGS async_insert=0 FORMAT JSONEachRow\n" <> Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode payload)))
  value <- runProtocol driver target (serverEndpoint server) "ledger-read" >>= store
  if corruption == "duplicate"
    then do
      state <- field "success" value
      field "eventCount" state >>= assert "Exact duplicate did not collapse" . (== (5 :: Int))
    else do
      code <- field "ledgerError" value :: IO Text
      let expected = case corruption of "gap" -> "SequenceGap"; "sequence-conflict" -> "SequenceConflict"; "identity-conflict" -> "EventIdentityConflict"; "foreign-ledger" -> "LedgerIdentityMismatch"; "missing-initialization" -> "MissingInitialization"; _ -> "InvalidEvent"
      assert ("Corrupt history accepted: " ++ Text.unpack corruption) (code == expected)
  putStrLn ("ledger corruption " ++ Text.unpack corruption ++ ": strict full-history fold; no winner selected")

protocolFamilyCases :: FilePath -> Server -> IO ()
protocolFamilyCases driver server = do
  forM_Indexed
    [ (RecoveryAuthorization, "recovery-authorized", "ledger-recovery-sequence", 5, True),
      (StepAcceptance, "step-accepted", "ledger-recovery-sequence", 6, True),
      (AdoptionStart, "adoption-started", "ledger-adoption-sequence", 2, False),
      (AdoptionEntry, "adoption-entry", "ledger-adoption-sequence", 3, False),
      (AdoptionCompletion, "adoption-completed", "ledger-adoption-sequence", 4, False)
    ]
    $ \index (stage, label, operation, count, recovery) -> do
      target@(FixtureTarget _ namespace _ _ _) <- newTarget server ("family_fault_" <> Text.pack (show index))
      when recovery (void (queryServer server ("CREATE TABLE default." <> namespace <> "_effects (id UInt8) ENGINE=MergeTree ORDER BY id")))
      withFaultProxy server $ \proxy -> do
        setLedgerFault proxy stage DropResponse
        report <- runProtocol driver target (proxyEndpoint proxy) operation
        detail <- store report
        receipt <- field "receipt" detail >>= right . Ledger.parseAppendReceipt
        field "poisoned" report >>= assert "Family append did not stop store"
        requests <- proxyEvents proxy >>= convert :: IO [Value]
        labels <- mapM (field "stage") requests :: IO [Maybe Text]
        assert "Family event replay or successor" (length (filter (== Just label) labels) == 1 && last labels == Just label)
        assert "Adoption executed SQL or recovery replayed query" (length (filter (== Just "application-sql") labels) == if recovery then 1 else 0)
        (classification, _) <- reconcile target receipt
        assert "Family event not reconciled" (classification == Ledger.PresentIdentical)
        assert "Family reconciliation wrote history" . (== count) =<< rowCount target
        state <- readHistory driver target
        field "unresolved" state >>= assert "Interrupted family incorrectly resolved" . (== (stage /= AdoptionCompletion))
        putStrLn ("ledger family " ++ show stage ++ ": one event; exact reconciliation; no implicit continuation")
  complete@(FixtureTarget _ namespace _ _ _) <- newTarget server "complete_recovery"
  _ <- queryServer server ("CREATE TABLE default." <> namespace <> "_effects (id UInt8) ENGINE=MergeTree ORDER BY id")
  state <- runProtocol driver complete (serverEndpoint server) "ledger-recovery-sequence" >>= success
  field "eventCount" state >>= assert "Recovery protocol missing evidence" . (== (8 :: Int))
  field "unresolved" state >>= assert "Complete recovery remains unresolved" . not
  putStrLn "ledger family: failure, recovery authorization, accepted step and explicit finalize roundtrip without replaying SQL"

-- Hold the first INSERT after the client has sent it but before the server sees
-- it. An empty independent read (and absent system.processes entry) cannot make
-- its sequence or a new ledger UUID safe to reuse.
delayedInitialization :: Server -> IO ()
delayedInitialization server = do
  binary <- getExecutablePath
  FixtureTarget _ namespace _ identity ledger <- newTarget server "delayed_initialization"
  key <- right (Target.targetKey ("ledger-tests/" <> namespace))
  let target = FixtureTarget server namespace key identity ledger
      root = serverLogDirectory server </> "delayed-locks"
      command endpoint candidate evidence = proc binary ["exclusive-child", Text.unpack endpoint, Text.unpack (Target.serverIdText identity), Text.unpack namespace, Text.unpack (Target.ledgerIdText candidate), root, "1000000", evidence]
      launch micros candidate = do
        inherited <- getEnvironment
        let configured = ("CHM_CHILD_HTTP_MICROS", micros) : filter ((/= "CHM_CHILD_HTTP_MICROS") . fst) inherited
        (status, output, _) <- readCreateProcessWithExitCode (candidate {env = Just configured}) ""
        assert "Delayed bootstrap child failed" (status == ExitSuccess)
        value <- either (const (fail "Invalid delayed child protocol")) pure (Aeson.eitherDecodeStrict' (Encoding.encodeUtf8 (Text.pack output)))
        cleanup <- field "cleanupErrors" value :: IO [Value]
        assert "Delayed child cleanup failed" (null cleanup)
        pure value
      waitFor action = do
        ready <- action
        unless ready (threadDelay 10000 >> waitFor action)
  withFaultProxy server $ \proxy -> do
    setLedgerFault proxy Initialization HoldBeforeForward
    failed <- launch "1000000" (command (proxyEndpoint proxy) ledger "yes")
    field "outcome" failed >>= assert "Held INSERT did not remain uncertain" . (== ("request-failed" :: Text))
    field "evidence" failed >>= assert "Held INSERT was called absent" . (== ("UncertainSubmission" :: Text))
    receipt <- field "receipt" failed >>= right . Ledger.parseAppendReceipt
    assert "First event arrived before controlled release" . (== 0) =<< rowCount target
    active <- scalar server ("SELECT toUInt32(count()) AS value FROM system.processes WHERE query_id='" <> Target.queryIdText (Ledger.appendQueryId receipt) <> "'")
    assert "Held INSERT already active on server" (active == 0)
    different <- Target.newLedgerId
    blocked <- launch "10000000" (command (serverEndpoint server) different "no")
    field "code" blocked >>= assert "Empty read allowed different bootstrap UUID/sequence" . (== ("PredecessorQuiescenceRequired" :: Text))
    assert "Successor wrote before predecessor quiescence" . (== 0) =<< rowCount target
    releaseFault proxy
    arrived <- timeout 5000000 (waitFor ((== 1) <$> rowCount target))
    drained <- timeout 5000000 (waitFor ((== 0) <$> proxyConnections proxy))
    assert "Delayed first event never arrived/drained" (isJust arrived && isJust drained)
    -- The parent now knows every controlled request completed and the original
    -- client process ended, and explicitly attests that evidence to the SAME OS
    -- coordinator. This is stronger than observing an empty row/process query.
    audit <- right (Ledger.auditContext "fixture recovery operator" "all controlled predecessor requests drained" ["original client process exited; proxy consumed sole upstream response and closed its handler"])
    quiet <- right (Ledger.attestQuiescence key audit)
    provider <- hostLocalExclusiveAccess root 1000000 (Just quiet) >>= right
    config <- configFor target (serverEndpoint server) Target.FirstUse
    inspected <- Ledger.reconcileAppend config provider receipt
    assert "Delayed event not reconciled" (case Ledger.result inspected of Right (Ledger.PresentIdentical, _) -> null (Ledger.cleanupErrors inspected); _ -> False)
    resumed <- Ledger.initializeLedger config provider (Ledger.authorizeInitialization key ledger audit) quiet
    assert "Bootstrap UUID not retained after reconciliation" (case Ledger.result resumed of Right position -> Target.ledgerIdText ledger `Text.isInfixOf` Ledger.ledgerPositionText position && null (Ledger.cleanupErrors resumed); _ -> False)
    requests <- proxyEvents proxy >>= convert :: IO [Value]
    stages <- mapM (field "stage") requests :: IO [Maybe Text]
    assert "Held initialization was replayed" (length (filter (== Just "initialized") stages) == 1)
    assert "Reconciled bootstrap duplicated event" . (== 1) =<< rowCount target
    putStrLn "delayed first event: empty row/process reads; different-UUID successor blocked; later single commit reconciled only after explicit proven quiescence"

-- The parent retains the externally serialized job through diagnostics/drain;
-- no new mutating job is admitted on the basis of NotObserved. This exercises
-- the same append boundary for intent, completion and adoption payloads.
delayedEventCases :: FilePath -> Server -> IO ()
delayedEventCases driver server = forM_Indexed [(StepStart, "step-started", "ledger-sequence", 2, False), (StepSuccess, "step-succeeded", "ledger-sequence", 3, True), (AdoptionEntry, "adoption-entry", "ledger-adoption-sequence", 2, False)] $ \index (stage, label, operation, before, effected) -> do
  target <- newTarget server ("delayed_event_" <> Text.pack (show index))
  withFaultProxy server $ \proxy -> do
    setLedgerFault proxy stage HoldBeforeForward
    failed <- runProtocolWithLimit 1000000 driver target (proxyEndpoint proxy) operation
    field "poisoned" failed >>= assert "Delayed append did not stop store"
    detail <- store failed
    pending <- field "request" detail :: IO Value
    field "outcome" pending >>= assert "Delayed append classified as absent" . (== ("submission-uncertain" :: Text))
    receipt <- field "receipt" detail >>= right . Ledger.parseAppendReceipt
    assert "Delayed event already committed" . (== before) =<< rowCount target
    (notObserved, observed) <- reconcile target receipt
    assert "In-flight absent event not classified read-only" (notObserved == Ledger.NotObserved && case observed of Ledger.ExpectPosition _ -> True; _ -> False)
    assert "NotObserved mutated or reused sequence" . (== before) =<< rowCount target
    assert "Delayed boundary application effect wrong" . (== effected) =<< effect target
    releaseFault proxy
    let wait action = action >>= \ready -> unless ready (threadDelay 10000 >> wait action)
    arrived <- timeout 5000000 (wait ((== before + 1) <$> rowCount target))
    drained <- timeout 5000000 (wait ((== 0) <$> proxyConnections proxy))
    assert "Delayed event never committed/drained" (isJust arrived && isJust drained)
    (present, _) <- reconcile target receipt
    assert "Delayed event did not reconcile exactly" (present == Ledger.PresentIdentical)
    state <- readHistory driver target
    field "unresolved" state >>= assert "Late event silently resumed migration/adoption"
    requests <- proxyEvents proxy >>= convert :: IO [Value]
    stages <- mapM (field "stage") requests :: IO [Maybe Text]
    assert "Delayed event or SQL replayed" (length (filter (== Just label) stages) == 1 && length (filter (== Just "application-sql") stages) == if effected then 1 else 0)
    assert "Reconciliation appended anything" . (== before + 1) =<< rowCount target
    putStrLn ("delayed " ++ show stage ++ ": NotObserved under retained job; one late commit; unresolved state retained; no successor admitted before drain")
