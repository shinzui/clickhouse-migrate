-- | Opt-in qualification of actual private core sources. Never a public SQL API.
module Main (main) where

import ClickHouseMigrate.Definition qualified as Def
import ClickHouseMigrate.ExclusiveAccess
import ClickHouseMigrate.Internal.Exclusive
import ClickHouseMigrate.Internal.ExclusiveTypes (AccessResult (..))
import ClickHouseMigrate.Internal.Http
import ClickHouseMigrate.Internal.Identity
import ClickHouseMigrate.Internal.LedgerCodec qualified as Codec
import ClickHouseMigrate.Internal.LedgerStore qualified as Store
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Projection qualified as Projection
import ClickHouseMigrate.Internal.ServerPolicy
import ClickHouseMigrate.Internal.TargetTypes qualified as TargetTypes
import ClickHouseMigrate.Internal.Transport
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Target
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)
import Text.Read (readMaybe)

main :: IO ()
main = do
  result <- try @SomeException run
  case result of
    Right () -> pure ()
    Left _ -> Lazy.putStrLn (Aeson.encode (object ["driverError" .= ("qualification-driver-failed" :: String)])) >> exitFailure

run :: IO ()
run = do
  args <- getArgs
  case args of
    [operation, endpoint, identity, file, microsText, bytesText] -> do
      micros <- maybe (fail "Invalid timeout") pure (readMaybe microsText)
      maxBytes <- maybe (fail "Invalid response bound") pure (readMaybe bytesText)
      user <- Text.pack . fromMaybe "default" <$> lookupEnv "CHM_TEST_USER"
      password <- Text.pack . fromMaybe "test-password" <$> lookupEnv "CHM_TEST_PASSWORD"
      expected <- Text.pack . fromMaybe "00000000-0000-0000-0000-000000000000" <$> lookupEnv "CHM_EXPECTED_SERVER_ID"
      namespace <- Text.pack . fromMaybe "migration_history" <$> lookupEnv "CHM_LEDGER_NAMESPACE"
      expectedLedger <- lookupEnv "CHM_EXPECTED_LEDGER_ID"
      binding <- maybe (pure FirstUse) (fmap ExistingLedger . either (const (fail "Invalid ledger binding")) pure . ledgerId . Text.pack) expectedLedger
      config <-
        either (const (fail "Invalid target")) pure $
          targetConfig
            <$> targetKey ("test-target/" <> namespace)
            <*> directEndpoint (Text.pack endpoint)
            <*> serverId expected
            <*> ledgerNamespace namespace
            <*> pure binding
            <*> basicCredentials user password
            <*> httpLimits micros maxBytes
      query <- either (const (fail "Invalid query id")) pure (queryId (Text.pack identity))
      sql <- BS.readFile file
      case operation of
        "ledger-smoke" -> ledgerSmoke config query
        mode | mode `elem` ["ledger-sequence", "ledger-recovery-sequence", "ledger-adoption-sequence", "ledger-read", "ledger-no-authorization"] -> ledgerProtocol mode config query
        mode | mode `elem` ["guarded-command", "guarded-reuse"] -> do
          probe <- either (const (fail "Invalid probe id")) pure (queryId (Text.pack (identity ++ "-identity")))
          result <- withTransport config probe $ \transport -> do
            first <- request transport query Command sql
            if mode == "guarded-command"
              then pure [first]
              else do
                secondId <- either (const (fail "Invalid second id")) pure (queryId (Text.pack (identity ++ "-second")))
                second <- request transport secondId Command sql
                pure [first, second]
          Lazy.putStrLn (Aeson.encode (guardedValue result))
        "cancel" -> do
          _ <- withHttp config $ \http -> do
            _ <- forkIO (submit http query Command sql >> pure ())
            threadDelay 250000
            throwIO ThreadKilled
          fail "Cancellation unexpectedly returned"
        "after-scope" -> do
          escaped <- withHttp config pure
          case escaped of
            ScopeResult (Right http) cleanup -> do
              outcome <- submit http query Command sql
              Lazy.putStrLn (Aeson.encode (scopeValue (ScopeResult (Right [outcome]) cleanup)))
            _ -> fail "Failed to create scope"
        _ -> do
          let scoped = case operation of
                "cleanup-failure" -> withHttpFinalizer config (fail "Synthetic cleanup failure")
                "cleanup-timeout" -> withHttpFinalizer config (threadDelay 2000000)
                _ -> withHttp config
          result <- scoped $ \http -> case operation of
            mode | mode `elem` ["command", "linger", "cleanup-failure", "cleanup-timeout"] -> (: []) <$> submit http query Command sql
            "read" -> (: []) <$> submit http query JsonRows sql
            "reuse" -> do
              first <- submit http query Command sql
              secondId <- either (const (fail "Invalid second id")) pure (queryId (Text.pack (identity ++ "-second")))
              second <- submit http secondId Command sql
              pure [first, second]
            _ -> fail "Unsupported driver operation"
          Lazy.putStrLn (Aeson.encode (scopeValue result))
          if operation == "linger" then hFlush stdout >> threadDelay 2000000 else pure ()
    _ -> fail "Expected operation endpoint query-id sql-file timeout-micros max-response-bytes"

scopeValue :: ScopeResult [TransportOutcome] -> Value
scopeValue (ScopeResult result cleanup) =
  object
    [ "outcomes" .= either (const ([] :: [Value])) (map outcomeValue) result,
      "scopeError" .= either (Just . errorValue) (const Nothing) result,
      "cleanupErrors" .= map errorValue cleanup
    ]

outcomeValue :: TransportOutcome -> Value
outcomeValue (NotSubmitted failure) = object ["outcome" .= ("not-submitted" :: String), "error" .= errorValue failure]
outcomeValue (SubmissionUncertain failure) = object ["outcome" .= ("submission-uncertain" :: String), "error" .= errorValue failure]
outcomeValue (ObservedServerFailure failure) = object ["outcome" .= ("observed-server-failure" :: String), "error" .= errorValue failure]
outcomeValue (AcknowledgedSuccess payload) = object ["outcome" .= ("acknowledged-success" :: String), "rows" .= case payload of CommandAccepted -> toJSON ([] :: [Value]); Rows rows -> toJSON rows]

errorValue :: TransportError -> Value
errorValue (TransportError code status serverCode) = object ["code" .= show code, "httpStatus" .= status, "serverCode" .= serverCode]

guardedValue :: ScopeResult (Either TargetCheckError [TransportOutcome]) -> Value
guardedValue (ScopeResult result cleanup) =
  object
    [ "outcomes" .= case result of Right (Right values) -> map outcomeValue values; _ -> [],
      "scopeError" .= case result of Left failure -> Just (errorValue failure); _ -> Nothing,
      "verificationError" .= case result of Right (Left failure) -> Just (checkValue failure); _ -> Nothing,
      "cleanupErrors" .= map errorValue cleanup
    ]

checkValue :: TargetCheckError -> Value
checkValue (TargetRejected failure) = object ["rejected" .= errorValue failure]
checkValue (ProbeFailure failure) = object ["probeFailure" .= outcomeValue failure]

-- The fixture owns a fresh isolated server, and this explicit provider represents
-- its single administrative process. It is not an application/default provider.
ledgerSmoke :: TargetConfig -> QueryId -> IO ()
ledgerSmoke config@(TargetTypes.TargetConfig key _ _ _ _ _ _) probe = do
  audit <- either (fail . show) pure (Ledger.auditContext "test operator's \"review\" 雪" "roundtrip\nencoding" ["owned isolated fixture"])
  quiet <- either (fail . show) pure (Ledger.attestQuiescence key audit)
  uuid <- freshUuid >>= either (fail . show) pure . ledgerId
  runIdentity <- freshUuid
  provider <- either (fail . show) pure (externallySerialized "owned-fixture-single-process" "complete isolated test target" 1000000 (const (pure ())) (const (pure ())) (const (pure True)))
  result <- withExclusive provider key $ \guard -> withTransport config probe $ \transport -> Store.storeResult $ do
    absent <- Store.load (Just guard) transport config
    unlessTest (absent == Store.Missing) "Fresh fixture already has a ledger"
    store <- Store.openStore guard transport config (Just (Ledger.authorizeInitialization key uuid audit)) quiet runIdentity
    initial <- Store.storeProjection store
    step <- either (fail . show) pure (Def.sqlStep "first" "CREATE TABLE app.events (id UInt8)")
    migration <- either (fail . show) pure (Def.sqlMigration "m" (step :| []))
    component <- either (fail . show) pure (Def.migrationComponent "app" Set.empty (migration :| []))
    plan <- either (fail . show) pure (Plan.migrationPlan (component :| []))
    definition <- case Codec.definitions plan of [value] -> pure value; _ -> fail "Unexpected test plan"
    identity <- freshUuid
    attempt <- freshUuid
    time <- diagnosticTime
    context <- either (fail . show) pure (Codec.contextFor definition Nothing)
    let event = L.LedgerEvent 2 identity uuid runIdentity (Just attempt) time audit "0.1.0.0" (Just context) (L.StartMigration definition)
    local <- Store.append store event
    loaded <- Store.load (Just guard) transport config
    unlessTest (loaded == Store.History local) "Stored event differs from projected event"
    pure (object ["position" .= Ledger.ledgerPositionText (L.position local), "initializedPosition" .= Ledger.ledgerPositionText (L.position initial), "roundtrip" .= True])
  case result of
    AccessResult (Right (ScopeResult (Right (Right (Right value))) [])) [] -> Lazy.putStrLn (Aeson.encode value)
    _ -> Lazy.putStrLn (Aeson.encode (object ["failure" .= show result])) >> exitFailure
  where
    unlessTest condition message = if condition then pure () else fail message

ledgerProtocol :: String -> TargetConfig -> QueryId -> IO ()
ledgerProtocol mode config@(TargetTypes.TargetConfig key _ _ namespace _ _ _) probe = do
  audit <- either (fail . show) pure (Ledger.auditContext "protocol test administrator" "one-shot ledger qualification" ["owned isolated fixture; predecessor requests are quiescent"])
  quiet <- either (fail . show) pure (Ledger.attestQuiescence key audit)
  requested <- lookupEnv "CHM_LEDGER_ID"
  identity <- maybe freshUuid (pure . Text.pack) requested >>= either (fail . show) pure . ledgerId
  runIdentity <- freshUuid
  attempt <- freshUuid
  provider <- either (fail . show) pure (externallySerialized "owned-fixture-single-administrator" "complete isolated test target" 1000000 (const (pure ())) (const (pure ())) (const (pure True)))
  poisoned <- newIORef False
  result <- withExclusive provider key $ \guard -> do
    let check = checkGuard guard >>= pure . either (const (Left (TransportError AdministrativeAccessLost Nothing Nothing))) (const (Right ()))
    withTransportChecked config probe check $ \transport ->
      Store.storeResult $
        if mode == "ledger-read"
          then observationValue <$> Store.load (Just guard) transport config
          else do
            let authorization = if mode == "ledger-no-authorization" then Nothing else Just (Ledger.authorizeInitialization key identity audit)
            store <- Store.openStore guard transport config authorization quiet runIdentity
            let sql = Encoding.encodeUtf8 ("CREATE TABLE default." <> ledgerNamespaceText namespace <> "_effects (id UInt8) ENGINE=MergeTree ORDER BY id")
            step <- either (fail . show) pure (Def.sqlStep "create" sql)
            migration <- either (fail . show) pure (Def.sqlMigration "one" (step :| []))
            component <- either (fail . show) pure (Def.migrationComponent "app" Set.empty (migration :| []))
            plan <- either (fail . show) pure (Plan.migrationPlan (component :| []))
            definition <- case Codec.definitions plan of [value] -> pure value; _ -> fail "Unexpected test definition"
            let append current body index = do
                  previous <- Store.storeProjection store
                  let L.LedgerPosition _ number _ = L.position previous
                  eventIdentity <- freshUuid
                  time <- diagnosticTime
                  context <- case body of L.StartAdoption _ -> pure Nothing; L.AdoptEntry _ _ -> Just <$> either (fail . show) pure (Codec.contextFor definition Nothing); L.CompleteAdoption _ -> pure Nothing; _ -> Just <$> either (fail . show) pure (Codec.contextFor definition index)
                  let event = L.LedgerEvent (number + 1) eventIdentity identity runIdentity current time audit "0.1.0.0" context body
                  submitted <- Store.storeResult (Store.append store event)
                  case submitted of
                    Right _ -> pure ()
                    Left failure@(Store.RequestProblem _ _) -> do
                      successor <- freshUuid
                      blocked <- Store.storeResult (Store.append store event {L.eventId = successor})
                      if blocked == Left failure then writeIORef poisoned True >> Store.abort failure else fail "Unacknowledged append did not poison store"
                    Left failure -> Store.abort failure
            if mode == "ledger-adoption-sequence"
              then do
                let digest = Text.replicate 64 "a"
                    evidence = L.Evidence L.OperatorAttestation ["protocol fixture: no predecessor checksum claim"]
                append Nothing (L.StartAdoption (L.AdoptionBatch "protocol-fixture" digest digest (Codec.definitionsDigest [definition]) 1)) Nothing
                append Nothing (L.AdoptEntry definition evidence) Nothing
                append Nothing (L.CompleteAdoption digest) Nothing
              else do
                append (Just attempt) (L.StartMigration definition) Nothing
                query <- Store.newQueryId
                append (Just attempt) (L.StartStep 0 (queryIdText query)) (Just 0)
                outcome <- request transport query Command (Plan.stepSql (NE.head (Plan.migrationSteps (NE.head (Plan.componentMigrations (NE.head (Plan.inspectPlan plan)))))))
                if mode == "ledger-recovery-sequence"
                  then do
                    failure <- case outcome of ObservedServerFailure value -> pure value; _ -> fail "Recovery fixture requires an observed server error"
                    append (Just attempt) (L.FailStep 0 (queryIdText query) (L.FailureEvidence (Text.pack (show (code failure))) (httpStatus failure) (serverCode failure))) (Just 0)
                    previous <- Store.storeProjection store
                    acceptedAttempt <- freshUuid
                    append (Just acceptedAttempt) (L.AuthorizeRecovery (L.Recovery (L.AcceptStep 0) (L.position previous) attempt acceptedAttempt quiet)) (Just 0)
                    append (Just acceptedAttempt) (L.AcceptCompletion 0 (L.Evidence L.OperatorAttestation ["fixture operator independently inspected preexisting intended table"])) (Just 0)
                    accepted <- Store.storeProjection store
                    finalAttempt <- freshUuid
                    append (Just finalAttempt) (L.AuthorizeRecovery (L.Recovery L.Finalize (L.position accepted) acceptedAttempt finalAttempt quiet)) Nothing
                    append (Just finalAttempt) L.CompleteMigration Nothing
                  else do
                    case outcome of AcknowledgedSuccess CommandAccepted -> pure (); _ -> Store.abort (Store.RequestProblem outcome Nothing)
                    append (Just attempt) (L.SucceedStep 0 (queryIdText query)) (Just 0)
                    append (Just attempt) L.CompleteMigration Nothing
            local <- Store.storeProjection store
            observed <- Store.load (Just guard) transport config
            if observed == Store.History local then pure (observationValue observed) else fail "Protocol read differs from local state"
  stopped <- readIORef poisoned
  let value = case ledgerProtocolValue result of Object fields -> Object (KM.insert "poisoned" (toJSON stopped) fields); other -> other
  Lazy.putStrLn (Aeson.encode value)

observationValue :: Store.Observation -> Value
observationValue = \case
  Store.Missing -> object ["observation" .= ("missing" :: String)]
  Store.EmptyNamespace -> object ["observation" .= ("uninitialized" :: String)]
  Store.History state -> let L.LedgerPosition ledger _ _ = L.position state in object ["observation" .= ("history" :: String), "position" .= Ledger.ledgerPositionText (L.position state), "ledgerId" .= ledgerIdText ledger, "eventCount" .= length (L.events state), "unresolved" .= Projection.unresolved state]

ledgerProtocolValue :: AccessResult (ScopeResult (Either TargetCheckError (Either Store.StoreError Value))) -> Value
ledgerProtocolValue (AccessResult acquired accessCleanup) = case acquired of
  Left failure -> object ["accessFailure" .= show failure, "accessCleanup" .= map show accessCleanup]
  Right (ScopeResult scoped cleanup) ->
    object
      [ "scopeError" .= either (Just . errorValue) (const Nothing) scoped,
        "verificationError" .= (case scoped of Right (Left failure) -> Just (checkValue failure); _ -> Nothing),
        "cleanupErrors" .= map errorValue cleanup,
        "accessCleanup" .= map show accessCleanup,
        "store"
          .= ( case scoped of
                 Right (Right (Right value)) -> object ["success" .= value]
                 Right (Right (Left failure)) -> storeErrorValue failure
                 _ -> object []
             )
      ]

storeErrorValue :: Store.StoreError -> Value
storeErrorValue = \case
  Store.LedgerProblem problem -> object ["ledgerError" .= show problem]
  Store.AccessProblem problem -> object ["accessError" .= show problem]
  Store.RequestProblem outcome receipt -> object ["request" .= outcomeValue outcome, "receipt" .= fmap Ledger.appendReceiptText receipt]
  Store.InitializationProblem ledger stage query outcome -> object ["initializationStage" .= stage, "ledgerId" .= ledgerIdText ledger, "queryId" .= queryIdText query, "request" .= outcomeValue outcome]
