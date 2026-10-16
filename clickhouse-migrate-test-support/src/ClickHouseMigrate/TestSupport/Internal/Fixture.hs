-- | Private RPC/process ownership for native fixtures. Stdout is protocol only.
module ClickHouseMigrate.TestSupport.Internal.Fixture
  ( Fixture,
    Server (..),
    withFixture,
    fixtureRpc,
    fixtureEndpoint,
    fixtureRoot,
    fixtureVersion,
    field,
  )
where

import ClickHouseMigrate.Prelude
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeAsyncException, SomeException, fromException, mask, onException, throwIO, try)
import Data.Aeson (FromJSON, Key, Result (..), Value (..), fromJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text qualified as Text
import Paths_clickhouse_migrate_test_support (getDataFileName)
import System.IO (Handle, hClose, hFlush, openTempFile)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc, terminateProcess, waitForProcess)
import System.Timeout (timeout)

data Server = Server !Fixture

data Fixture = Fixture !Handle !Handle !ProcessHandle !(MVar ()) !Text !FilePath !Text

field :: (FromJSON a) => Key -> Value -> IO a
field key (Object value) = case KM.lookup key value of
  Just member -> case fromJSON member of
    Success result -> pure result
    Error _ -> fail "Invalid fixture response field"
  Nothing -> fail "Missing fixture response field"
field _ _ = fail "Invalid fixture response object"

withFixture :: Text -> (Fixture -> IO a) -> IO a
withFixture entry action = mask $ \restore -> do
  script <- getDataFileName "test/scripts/native_fixture.py"
  matrix <- getDataFileName "test/data/clickhouse-matrix.json"
  (logPath, logHandle) <- openTempFile "/tmp" "clickhouse-migrate-fixture.log"
  pipes <-
    createProcess
      ( (proc "python3" [script, "--matrix", matrix, "--entry", Text.unpack entry])
          { std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = UseHandle logHandle
          }
      )
      `onException` hClose logHandle
  case pipes of
    (Just input, Just output, _, process) -> do
      ready <- try @SomeException $ do
        line <- timeout 40000000 (BS.hGetLine output)
        value <- maybe (fail "Fixture startup deadline expired") (either (const (fail "Fixture startup failed")) pure . Aeson.eitherDecodeStrict') line
        endpoint <- field "endpoint" value
        root <- field "root" value
        version <- field "version" value
        gate <- newMVar ()
        pure (Fixture input output process gate endpoint root version)
      case ready of
        Left exception -> do
          terminateProcess process
          _ <- timeout 20000000 (waitForProcess process)
          hClose input
          hClose output
          hClose logHandle
          case fromException exception :: Maybe SomeAsyncException of
            Just _ -> throwIO exception
            Nothing -> fail ("Owned fixture startup failed; evidence: " ++ logPath)
        Right fixture -> do
          result <- try @SomeException (restore (action fixture))
          cleanup <- try @SomeException $ do
            _ <- fixtureRpc fixture (object ["operation" .= ("stop" :: Text), "success" .= either (const False) (const True) result])
            stopped <- timeout 20000000 (waitForProcess process)
            case stopped of
              Nothing -> terminateProcess process >> void (timeout 20000000 (waitForProcess process)) >> fail "Fixture cleanup deadline expired"
              Just _ -> pure ()
          case cleanup of
            Left _ -> terminateProcess process >> void (timeout 20000000 (waitForProcess process))
            Right () -> pure ()
          hClose input
          hClose output
          hClose logHandle
          case result of
            Left exception -> throwIO exception
            Right value -> case cleanup of
              Left exception -> case fromException exception :: Maybe SomeAsyncException of
                Just _ -> throwIO exception
                Nothing -> fail ("Owned fixture cleanup failed; evidence: " ++ logPath)
              Right () -> pure value
    _ -> hClose logHandle >> fail "Owned fixture pipes unavailable"

fixtureRpc :: Fixture -> Value -> IO Value
fixtureRpc (Fixture input output _ gate _ root _) request = withMVar gate $ \() -> do
  Lazy.hPutStrLn input (Aeson.encode request)
  -- ByteString writes to a Handle still use its buffering policy.
  hFlush input
  line <- timeout 15000000 (BS.hGetLine output)
  reply <- maybe (fail ("Fixture RPC deadline expired; evidence: " ++ root)) (either (const (fail "Invalid fixture protocol")) pure . Aeson.eitherDecodeStrict') line
  case reply of
    Object members -> maybe (fail ("Owned fixture operation failed; evidence: " ++ root)) pure (KM.lookup "result" members)
    _ -> fail "Invalid fixture protocol object"

fixtureEndpoint :: Fixture -> Text
fixtureEndpoint (Fixture _ _ _ _ endpoint _ _) = endpoint

fixtureRoot :: Fixture -> FilePath
fixtureRoot (Fixture _ _ _ _ _ root _) = root

fixtureVersion :: Fixture -> Text
fixtureVersion (Fixture _ _ _ _ _ _ version) = version
