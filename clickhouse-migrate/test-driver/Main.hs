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
import ClickHouseMigrate.Internal.ServerPolicy
import ClickHouseMigrate.Internal.Transport
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Target
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
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
      config <-
        either (const (fail "Invalid target")) pure $
          targetConfig
            <$> targetKey "test-target"
            <*> directEndpoint (Text.pack endpoint)
            <*> serverId expected
            <*> ledgerNamespace "migration_history"
            <*> pure FirstUse
            <*> basicCredentials user password
            <*> httpLimits micros maxBytes
      query <- either (const (fail "Invalid query id")) pure (queryId (Text.pack identity))
      sql <- BS.readFile file
      case operation of
        "ledger-smoke" -> ledgerSmoke config query
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
ledgerSmoke config probe = do
  key <- either (fail . show) pure (targetKey "test-target")
  audit <- either (fail . show) pure (Ledger.auditContext "test operator's \"review\"" "roundtrip\nencoding" ["owned isolated fixture"])
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
