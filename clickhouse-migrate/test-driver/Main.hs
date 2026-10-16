-- | Opt-in qualification of actual private core sources. Never a public SQL API.
module Main (main) where

import ClickHouseMigrate.Internal.Http
import ClickHouseMigrate.Internal.ServerPolicy
import ClickHouseMigrate.Internal.Transport
import ClickHouseMigrate.Target
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Maybe (fromMaybe)
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
