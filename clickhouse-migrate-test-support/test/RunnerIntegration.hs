module RunnerIntegration (runnerEarlyCases, runnerValidationCases, fixture, fixtureWithLimits, provider, planFor, scalar, assert, right, field, fromJson) where

import ClickHouseMigrate
import ClickHouseMigrate.Adoption qualified as Adoption
import ClickHouseMigrate.Event qualified as Event
import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Inspection qualified as Inspect
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (FromJSON, Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.FilePath ((</>))

assert :: String -> Bool -> IO ()
assert label predicate = unless predicate (fail ("runner early integration: " ++ label))

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

field :: (FromJSON a) => Aeson.Key -> Value -> IO a
field key value = case Aeson.fromJSON value :: Aeson.Result Aeson.Object of
  Aeson.Success row -> case KM.lookup key row of
    Just member -> case Aeson.fromJSON member of
      Aeson.Success result -> pure result
      _ -> fail "Invalid runner field"
    _ -> fail "Missing runner field"
  _ -> fail "Invalid runner object"

fixture :: Server -> Text.Text -> Text.Text -> LedgerBinding -> IO TargetConfig
fixture = fixtureWithLimits defaultHttpLimits

fixtureWithLimits :: HttpLimits -> Server -> Text.Text -> Text.Text -> LedgerBinding -> IO TargetConfig
fixtureWithLimits limits server label endpoint binding = do
  rows <- queryServer server "SELECT toString(serverUUID()) AS server_id" >>= fromJson :: IO [Value]
  identity <- case rows of [row] -> field "server_id" row; _ -> fail "Missing server identity"
  targetConfig <$> right (targetKey ("runner-tests/" <> label)) <*> right (directEndpoint endpoint) <*> right (serverId identity) <*> right (ledgerNamespace (label <> "_history")) <*> pure binding <*> right (basicCredentials "default" "test-password") <*> pure limits

fromJson :: (FromJSON a) => Value -> IO a
fromJson value = case Aeson.fromJSON value of Aeson.Success result -> pure result; _ -> fail "Invalid independent runner observation"

provider :: IO Access.ExclusiveAccess
provider = right (Access.externallySerialized "owned-fixture-serialized-job" "parent owns target and admits no mutating successor before all predecessor requests drain" 1000000 (const (pure ())) (const (pure ())) (const (pure True)))

planFor :: Text.Text -> Int -> IO MigrationPlan
planFor label value = do
  create <- right (sqlStep "create" (Encoding.encodeUtf8 ("CREATE TABLE default." <> label <> " (id UInt8, secret String) ENGINE=MergeTree ORDER BY id")))
  insert <- right (sqlStep "insert" (Encoding.encodeUtf8 ("INSERT INTO default." <> label <> " VALUES (" <> Text.pack (show value) <> ",'SQL_SECRET_MARKER')")))
  migration <- right (sqlMigration "one" (create :| [insert]))
  component <- right (migrationComponent "app" Set.empty (migration :| []))
  right (migrationPlan (component :| []))

scalar :: Server -> Text.Text -> IO Int
scalar server sql = do
  rows <- queryServer server sql >>= fromJson :: IO [Value]
  case rows of [row] -> field "value" row; _ -> fail "Invalid independent scalar"

runnerEarlyCases :: Server -> IO ()
runnerEarlyCases server = do
  scheduleUpgrade server
  audit <- right (Ledger.auditContext "runner fixture" "explicit isolated first run" ["owned server and controlled parent job"])
  access <- provider
  -- Required first producer/consumer check, before the full crash matrix.
  withFaultProxy server $ \proxy -> do
    let label = "runner_early"
    ledger <- newLedgerId
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    key <- right (targetKey ("runner-tests/" <> label))
    trace <- newIORef []
    let sink event@(Event.RunEvent phase _ _ _ step query _) = do
          modifyIORef' trace (++ [event])
          when (phase == Event.BeforeSql && step == Just "insert") $ case query of
            Just identity -> setFaultForQuery proxy (queryIdText identity) DropResponse
            _ -> fail "Step intent lacks its query identity"
        context = Run.mutationContext config access sink Event.redactedDiagnostics
    plan <- planFor label 7
    result <- Run.up context (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) plan
    failure <- case result of Left value -> pure value; Right _ -> fail "Lost response was acknowledged"
    let R.RunFailure primary report secondary = failure
        R.RunReport _ _ _ acquired snapshot migrations observations initialized = report
    assert "Primary lost-response identity missing" (case primary of R.SqlFailed (R.StepReference "app" "one" "insert" _ _) _ Ledger.UncertainSubmission _ -> True; _ -> False)
    assert "Acknowledged partial progress missing" (acquired && null secondary && initialized == Just ledger && length observations == 2)
    assert "Earlier successful step was lost" (case migrations of [R.MigrationSummary _ R.InProgress (Just _) [R.StepSummary "create" _ R.StepObservedSuccess _ _, R.StepSummary "insert" _ R.StepUncertain _ _]] -> True; _ -> False)
    assert "SQL leaked in default failure/report" (not ("SQL_SECRET_MARKER" `Text.isInfixOf` Text.pack (show failure)))
    count <- scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
    assert "Lost response did not commit exactly one effect" (count == 1)
    let R.HistoryReport _ _ _ position _ events _ unresolved = snapshot
    assert "Latest acknowledged checkpoint wrong" (isJust position && length events == 5 && unresolved)
    token <- maybe (fail "Missing checkpoint") pure position
    assert "Expected-position token not roundtrippable" (Ledger.parseLedgerPosition (Ledger.ledgerPositionText token) == Right token)
    setFault proxy Pass
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    guarded <- Inspect.status (Inspect.Guarded access) bound plan >>= right
    assert "Guarded inspection lost state" (case guarded of R.InspectionReport (R.HistoryReport _ _ _ observed (R.GuardedObservation _) _ _ _) _ issues -> observed == position && not (null issues); _ -> False)
    repeated <- Run.up (Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit Nothing) plan
    assert "Ordinary up resumed unresolved history" (case repeated of Left (R.RunFailure (R.LedgerFailed Ledger.UnresolvedHistory) _ _) -> True; _ -> False)
    received <- proxyEvents proxy >>= fromJson :: IO [Value]
    kinds <- mapM (field "stage") received :: IO [Maybe Text.Text]
    assert "Ordinary restart replayed an application statement" (length (filter (== Just "application-sql") kinds) == 2)
    callbacks <- readIORef trace
    assert "Completion callback preceded ledger acknowledgement" (length [() | Event.RunEvent Event.StepSucceeded _ _ _ _ _ _ <- callbacks] == 1 && null [() | Event.RunEvent Event.MigrationCompleted _ _ _ _ _ _ <- callbacks])
    putStrLn "runner early case: lost second response; one effect; first checkpoint retained; guarded status; ordinary up refuses replay"
  withFaultProxy server $ \proxy -> do
    let label = "runner_normal"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    first <- Run.up (Run.mutationContext config access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) plan >>= right
    let R.RunReport _ _ _ _ snapshot _ _ returned = first
    persisted <- case returned of
      Nothing -> fail "Bootstrap did not return its ledger identity"
      Just value -> do
        let file = serverLogDirectory server </> "runner-ledger-id.txt"
        BS.writeFile file (Encoding.encodeUtf8 (ledgerIdText value))
        BS.readFile file >>= right . ledgerId . Encoding.decodeUtf8
    assert "Normal run did not complete" (case snapshot of R.HistoryReport _ _ (R.LedgerInitializedAt actual) (Just _) _ _ [R.MigrationSummary _ R.Applied _ _] False -> actual == ledger; _ -> False)
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger persisted)
    _ <- Run.up (Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit Nothing) plan >>= right
    received <- proxyEvents proxy >>= fromJson :: IO [Value]
    kinds <- mapM (field "stage") received :: IO [Maybe Text.Text]
    assert "Completed migration replayed" (length (filter (== Just "application-sql") kinds) == 2)
    _ <- Inspect.verify Inspect.Observe bound (Inspect.verifyOptions True) plan >>= right
    changed <- planFor label 8
    blocked <- Run.up (Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit Nothing) changed
    assert "Modified applied SQL accepted" (case blocked of Left (R.RunFailure (R.IncompatibleHistory _) _ _) -> True; _ -> False)
    putStrLn "runner normal case: ordered two-step completion, verify current, second run skips, changed applied SQL blocks"

runnerValidationCases :: Server -> IO ()
runnerValidationCases server = do
  audit <- right (Ledger.auditContext "validation fixture" "owned isolated target" ["parent serializes and drains all requests"])
  access <- provider
  withFaultProxy server $ \proxy -> do
    let label = "runtime_validation"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    touched <- newIORef False
    counting <- right (Access.externallySerialized "preflight-counter" "owned fixture" 1000000 (const (writeIORef touched True)) (const (pure ())) (const (pure True)))
    forbidden <- right (sqlStep "reserved" "CREATE TABLE runtime_validation_history.forbidden (id UInt8) ENGINE=Memory")
    migration <- right (sqlMigration "forbidden" (forbidden :| []))
    component <- right (migrationComponent "app" Set.empty (migration :| []))
    bad <- right (migrationPlan (component :| []))
    rejected <- Run.up (Run.mutationContext config counting Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) bad
    assert "Dynamic namespace was not rejected in pure preflight" (case rejected of Left (R.RunFailure (R.LedgerNamespaceInSql _) _ _) -> True; _ -> False)
    assert "Invalid plan acquired access" . not =<< readIORef touched
    empty <- proxyEvents proxy >>= fromJson :: IO [Value]
    assert "Invalid plan contacted server" (null empty)
    valid <- planFor label 7
    missing <- Inspect.status Inspect.Observe bound valid >>= right
    assert "Missing inspection created ledger" (case missing of R.InspectionReport (R.HistoryReport _ _ R.LedgerMissing _ R.UnguardedObservation [] _ _) _ _ -> True; _ -> False)
    _ <- Inspect.verify Inspect.Observe bound (Inspect.verifyOptions False) valid >>= right
    repeated <- Run.up (Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit Nothing) valid
    assert "Recurring run initialized absent history" (case repeated of Left (R.RunFailure R.LedgerRequired _ _) -> True; _ -> False)
    -- A two-component prefix retains dependency and global ordering evidence.
    seedStep <- right (sqlStep "seed" "CREATE TABLE default.validation_seed (id UInt8) ENGINE=Memory")
    seedMigration <- right (sqlMigration "seed" (seedStep :| []))
    seed <- right (migrationComponent "seed" Set.empty (seedMigration :| []))
    appStep <- right (sqlStep "app" "CREATE TABLE default.validation_app (id UInt8) ENGINE=Memory")
    appMigration <- right (sqlMigration "app" (appStep :| []))
    dependent <- right (migrationComponent "app" (Set.singleton "seed") (appMigration :| []))
    independent <- right (migrationComponent "app" Set.empty (appMigration :| []))
    original <- right (migrationPlan (seed :| [dependent]))
    _ <- Run.up (Run.mutationContext config access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) original >>= right
    changedDependencies <- right (migrationPlan (seed :| [independent]))
    reordered <- right (migrationPlan (independent :| [seed]))
    unknownStored <- right (migrationPlan (seed :| []))
    forM_ [changedDependencies, reordered, unknownStored] $ \changed -> do
      result <- Run.up (Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit Nothing) changed
      assert "Incompatible global history permitted mutation" (case result of Left (R.RunFailure (R.IncompatibleHistory _) _ _) -> True; _ -> False)
      verification <- Inspect.verify Inspect.Observe bound (Inspect.verifyOptions False) changed
      assert "Verify accepted changed global prefix" (case verification of Left (R.InspectionFailure (R.IncompatibleHistory _) _ _) -> True; _ -> False)
      _ <- Inspect.history Inspect.Observe bound >>= right
      pure ()
    void (queryServer server "INSERT INTO runtime_validation_history.events SELECT sequence,event_id,ledger_id,concat(event,' ') FROM runtime_validation_history.events WHERE sequence=1 SETTINGS async_insert=0")
    corrupt <- Run.up (Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics) (Run.upOptions audit Nothing) original
    assert "Conflicting physical history permitted execution" (case corrupt of Left (R.RunFailure (R.LedgerFailed _) _ _) -> True; _ -> False)
    requests <- proxyEvents proxy >>= fromJson :: IO [Value]
    stages <- mapM (field "stage") requests :: IO [Maybe Text.Text]
    assert "Validation failures submitted application SQL" (length (filter (== Just "application-sql") stages) == 2)
    putStrLn "runtime validation: pure namespace preflight; absent observation without initialization; changed dependencies/order/unknown stored item/corruption refuse SQL"

-- Public producer/consumer proof, including original-prefix rejection.
scheduleUpgrade :: Server -> IO ()
scheduleUpgrade server = do
  access <- provider
  audit <- right (Ledger.auditContext "schedule fixture" "append earlier component upgrade" ["owned disposable server"])
  ledger <- newLedgerId
  let label = "schedule_upgrade"
  config <- fixture server label (serverEndpoint server) FirstUse
  bound <- fixture server label (serverEndpoint server) (ExistingLedger ledger)
  key <- right (targetKey ("runner-tests/" <> label))
  stepA <- right (sqlStep "create" "CREATE TABLE default.schedule_a (id UInt8) ENGINE=Memory")
  stepB <- right (sqlStep "create" "CREATE TABLE default.schedule_b (id UInt8) ENGINE=Memory")
  stepA2 <- right (sqlStep "insert" "INSERT INTO default.schedule_a VALUES (2)")
  a1 <- right (sqlMigration "one" (stepA :| []))
  b1 <- right (sqlMigration "one" (stepB :| []))
  a2 <- right (sqlMigration "two" (stepA2 :| []))
  a <- right (migrationComponent "a" Set.empty (a1 :| []))
  upgraded <- right (migrationComponent "a" Set.empty (a1 :| [a2]))
  b <- right (migrationComponent "b" (Set.singleton "a") (b1 :| []))
  initial <- right (migrationPlan (a :| [b]))
  let ident c m = migrationIdFromNames <$> componentName c <*> migrationName m
  ids <- mapM (right . uncurry ident) [("a", "one"), ("b", "one"), ("a", "two")]
  full <- right (scheduledMigrationPlanFromList [upgraded, b] ids)
  let context target = Run.mutationContext target access Event.quietEvents Event.redactedDiagnostics
  _ <- Run.up (context config) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) initial >>= right
  -- Old grouping would put A.two before the already-recorded B.one.
  grouped <- right (migrationPlan (upgraded :| [b]))
  refused <- Run.up (context bound) (Run.upOptions audit Nothing) grouped
  assert "changed prefix accepted" (case refused of Left (R.RunFailure (R.IncompatibleHistory _) _ _) -> True; _ -> False)
  result <- Run.up (context bound) (Run.upOptions audit Nothing) full >>= right
  assert "upgrade reran old migrations" (case result of R.RunReport _ _ _ _ _ _ observations _ -> length observations == 1)
  count <- scalar server "SELECT toUInt32(count()) AS value FROM default.schedule_a"
  assert "A.two missing or replayed" (count == 1)
  repeated <- Run.up (context bound) (Run.upOptions audit Nothing) full >>= right
  assert "repeat submitted SQL" (case repeated of R.RunReport _ _ _ _ _ _ observations _ -> null observations)
  _ <- Inspect.verify Inspect.Observe bound (Inspect.verifyOptions True) full >>= right
  putStrLn "schedule: A.one B.one preserved; only appended A.two executes; changed prefix refused; repeat no-op; require-current passes"

  -- Adoption maps the explicit prefix A.one, B.one, leaving A.two pending.
  adoptLedger <- newLedgerId
  let adoptLabel = "schedule_adoption"
  adoptConfig <- fixture server adoptLabel (serverEndpoint server) FirstUse
  adoptBound <- fixture server adoptLabel (serverEndpoint server) (ExistingLedger adoptLedger)
  adoptKey <- right (targetKey ("runner-tests/" <> adoptLabel))
  quiet <- right (Ledger.attestQuiescence adoptKey audit)
  let views = take 2 (NE.toList (inspectSchedule full))
  rows <- mapM (\name -> right (Adoption.legacyRow name "2020-01-01T00:00:00Z" Nothing)) ["a.sql", "b.sql"]
  mappings <- mapM (\(name, view) -> right (Adoption.attestedMapping name (componentNameText (migrationIdComponent (migrationId view))) "one" (migrationChecksumHex (migrationChecksum view)) ["reviewed schedule prefix"])) (zip ["a.sql", "b.sql"] views)
  request <- case (rows, mappings) of
    (r : rs, m : ms) -> right (Adoption.adoptionRequest adoptKey (Ledger.ExpectAbsent adoptKey) (Just (Ledger.authorizeInitialization adoptKey adoptLedger audit)) quiet audit "schedule-fixture" "immutable-prefix" (r :| rs) (m :| ms))
    _ -> fail "Missing adoption fixture"
  observed <- Inspect.status Inspect.Observe adoptConfig full >>= right
  adoption <- right (Adoption.planAdoption full observed request)
  _ <- Adoption.applyAdoption (context adoptConfig) full adoption >>= right
  let stop (Event.RunEvent phase _ component migration _ _ _) = when (phase == Event.BeforeSql && component == Just "a" && migration == Just "two") (fail "interrupt appended schedule migration")
  stopped <- Run.up (Run.mutationContext adoptBound access stop Event.redactedDiagnostics) (Run.upOptions audit Nothing) full
  (position, attempt, selected) <- case stopped of
    Left (R.RunFailure (R.CallbackFailed _) (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just position) _ _ _ _) [_, _, R.MigrationSummary (R.DefinitionSummary 2 0 "a" _ "two" _ _) _ (Just attempt) [R.StepSummary _ _ _ (Just selected) _]] _ _) _) -> pure (position, attempt, selected)
    _ -> fail "Interleaved recovery selected wrong definition"
  evidence <- right (Repair.recoveryEvidence audit quiet [])
  retry <- right (Repair.retryStepRequest position attempt selected evidence)
  retried <- Repair.repair (context adoptBound) full retry >>= right
  (nextPosition, nextAttempt) <- case retried of
    R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just position') _ _ _ _) [_, _, R.MigrationSummary _ _ (Just attempt') _] _ _ -> pure (position', attempt')
    _ -> fail "Missing recovered schedule migration"
  finalize <- right (Repair.finalizeRequest nextPosition nextAttempt evidence)
  _ <- Repair.repair (context adoptBound) full finalize >>= right
  _ <- Inspect.verify Inspect.Observe adoptBound (Inspect.verifyOptions True) full >>= right
  putStrLn "schedule: adoption maps A.one B.one; interrupted A.two repairs ordinal 2/component 0 and finalizes"
