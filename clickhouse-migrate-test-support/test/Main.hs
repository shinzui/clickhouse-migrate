module Main (main) where

import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target qualified as Target
import ClickHouseMigrate.TestSupport.ExclusiveAccess (hostLocalExclusiveAccess)
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay, tryReadMVar)
import Control.Exception (bracket, finally, throwIO)
import Data.Aeson (FromJSON, Key, Object, Result (..), Value (..), fromJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import LedgerIntegration (ledgerFaultCases)
import System.Environment (getArgs, getEnv, getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), createProcess, getProcessExitCode, proc, readCreateProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

field :: (FromJSON a) => Key -> Value -> IO a
field key (Object value) = maybe (fail "Missing result field") convert (KM.lookup key value)
field _ _ = fail "Invalid result object"

convert :: (FromJSON a) => Value -> IO a
convert value = case fromJSON value of Success result -> pure result; Error _ -> fail "Invalid result type"

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["exclusive-child", endpoint, identity, namespace, ledger, root, micros, evidence] -> exclusiveChild endpoint identity namespace ledger root micros evidence
    _ -> integrationMain args

integrationMain :: [String] -> IO ()
integrationMain args = do
  driver <- if args == ["exclusive"] then pure "" else getEnv "CLICKHOUSE_MIGRATE_TEST_DRIVER"
  finished <- timeout 180000000 $ withCandidateServer "lts-native" $ \server -> do
    putStrLn ("Candidate ClickHouse " ++ Text.unpack (serverVersion server))
    case args of
      [] -> transportCases driver server
      ["transport"] -> transportCases driver server
      ["completion"] -> completionCases driver server
      ["ledger"] -> ledgerCases driver server
      ["exclusive"] -> exclusiveCases server
      _ -> fail "Unknown integration group"
  case finished of Nothing -> fail "Integration watchdog expired"; Just () -> pure ()

runDriver :: FilePath -> Server -> Text -> String -> String -> ByteString -> Int -> Int -> IO Value
runDriver = runDriverExpected Nothing

runDriverExpected :: Maybe Text -> FilePath -> Server -> Text -> String -> String -> ByteString -> Int -> Int -> IO Value
runDriverExpected expected driver server endpoint operation identity sql micros bound = do
  let file = serverLogDirectory server </> identity ++ ".sql"
  BS.writeFile file sql
  inherited <- getEnvironment
  let configured = case expected of
        Nothing -> inherited
        Just value -> ("CHM_EXPECTED_SERVER_ID", Text.unpack value) : filter ((/= "CHM_EXPECTED_SERVER_ID") . fst) inherited
  (status, output, _) <- readCreateProcessWithExitCode ((proc driver [operation, Text.unpack endpoint, identity, file, show micros, show bound]) {env = Just configured}) ""
  assert "Private driver failed" (status == ExitSuccess)
  report <- either (const (fail "Invalid private driver protocol")) pure (Aeson.eitherDecodeStrict' (Encoding.encodeUtf8 (Text.pack output)))
  scope <- field "scopeError" report :: IO Value
  cleanup <- field "cleanupErrors" report :: IO [Value]
  assert "Unexpected scope failure" (scope == Null)
  unless (operation `elem` ["cleanup-failure", "cleanup-timeout"]) (assert "Unexpected cleanup failure" (null cleanup))
  let rendered = Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode report))
  assert "Credentials or raw diagnostic escaped" (not ("test-password" `Text.isInfixOf` rendered) && not ("SQL_SECRET_MARKER" `Text.isInfixOf` rendered))
  pure report

outcomes :: Value -> IO [Value]
outcomes = field "outcomes"

expectFirst :: Text -> Value -> IO ()
expectFirst expected report =
  outcomes report >>= \case
    first : _ -> field "outcome" first >>= assert "Wrong transport evidence classification" . (== expected)
    _ -> fail "Missing transport evidence"

exists :: Server -> Text -> IO Bool
exists server name = do
  value <- queryServer server ("EXISTS TABLE default." <> name)
  rows <- convert value :: IO [Value]
  case rows of
    [row] -> (== (1 :: Int)) <$> field "result" row
    _ -> fail "Invalid independent effect observation"

transportCases :: FilePath -> Server -> IO ()
transportCases driver server = do
  let cases =
        [ (DropResponse, "lost_response", "submission-uncertain"),
          (TruncateResponse, "truncated_response", "submission-uncertain"),
          (LateError, "late_error", "observed-server-failure"),
          (DelayResponse, "timed_out_response", "submission-uncertain")
        ]
  mapM_
    ( \(mode, name, expected) -> withFaultProxy server $ \proxy -> do
        setFault proxy mode
        let sql = Encoding.encodeUtf8 ("CREATE TABLE default." <> name <> " (id UInt8) ENGINE=Memory")
            micros = if mode == DelayResponse then 150000 else 3000000
        report <- runDriver driver server (proxyEndpoint proxy) "command" (Text.unpack name) sql micros 1048576
        expectFirst expected report
        assert "Committed effect missing" =<< exists server name
        events <- proxyEvents proxy >>= convert :: IO [Object]
        assert "POST was replayed" (length events == 1)
        putStrLn (Text.unpack name ++ ": " ++ Text.unpack expected ++ "; actual effect present; requests=1")
    )
    cases
  withFaultProxy server $ \origin -> withFaultProxy server $ \destination -> do
    redirectTo origin (proxyEndpoint destination)
    setFault origin Redirect
    report <- runDriver driver server (proxyEndpoint origin) "command" "redirect" "CREATE TABLE default.redirect_trap (id UInt8) ENGINE=Memory" 3000000 1048576
    expectFirst "observed-server-failure" report
    destinationEvents <- proxyEvents destination >>= convert :: IO [Object]
    originEvents <- proxyEvents origin >>= convert :: IO [Object]
    assert "Redirect was followed" (length originEvents == 1 && null destinationEvents)
    present <- exists server "redirect_trap"
    assert "Redirect destination executed SQL" (not present)
    putStrLn "redirect: rejected; origin requests=1; destination requests=0"
  withFaultProxy server $ \proxy -> do
    report <- runDriver driver server (proxyEndpoint proxy) "command" "empty_request" "" 3000000 1048576
    expectFirst "not-submitted" report
    events <- proxyEvents proxy >>= convert :: IO [Object]
    assert "Invalid request reached network" (null events)
    putStrLn "empty request: positively not submitted; requests=0"
  withFaultProxy server $ \proxy -> do
    report <- runDriver driver server (proxyEndpoint proxy) "read" "bounded_response" "SELECT repeat('x', 2048) AS value" 3000000 32
    expectFirst "submission-uncertain" report
    events <- proxyEvents proxy >>= convert :: IO [Object]
    assert "Oversized response caused replay" (length events == 1)
    putStrLn "bounded response: no false success; requests=1"

  withFaultProxy server $ \proxy -> do
    setFault proxy CloseReusedConnection
    report <- runDriver driver server (proxyEndpoint proxy) "reuse" "reused_connection" "CREATE TABLE IF NOT EXISTS default.reused_connection (id UInt8) ENGINE=Memory" 3000000 1048576
    results <- outcomes report
    case results of
      [first, second] -> do
        firstKind <- field "outcome" first :: IO Text
        secondKind <- field "outcome" second :: IO Text
        assert "Reused connection evidence wrong" (firstKind == "acknowledged-success" && secondKind == "submission-uncertain")
      _ -> fail "Missing reuse evidence"
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Reused POST replayed" (length events == 2)
    connections <- mapM (field "connection") events :: IO [Int]
    assert "Test did not actually reuse a socket" (case connections of [a, b] -> a == b; _ -> False)
    putStrLn "reused connection: acknowledged then uncertain; one socket; requests=2 for two authorizations"
  withTlsFaultProxy server $ \proxy -> do
    report <- runDriver driver server (proxyEndpoint proxy) "command" "untrusted_tls" "CREATE TABLE default.untrusted_tls (id UInt8) ENGINE=Memory" 3000000 1048576
    expectFirst "not-submitted" report
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Untrusted TLS received HTTP SQL" (null events)
    present <- exists server "untrusted_tls"
    assert "Untrusted TLS executed SQL" (not present)
    putStrLn "untrusted TLS: certificate rejected before HTTP; requests=0"

  fullRead <- runDriver driver server (serverEndpoint server) "read" "complete_machine_read" "SELECT number FROM numbers(3) ORDER BY number" 3000000 1048576
  expectFirst "acknowledged-success" fullRead
  readOutcomes <- outcomes fullRead
  readRows <- case readOutcomes of [row] -> field "rows" row :: IO [Value]; _ -> fail "Missing complete read"
  assert "Profile silently truncated a machine read" (length readRows == 3)
  putStrLn "machine read: profile result_overflow_mode=break/max_result_rows=1 cannot silently truncate history"

  -- A checked transport verifies every fresh connection, not just its first request.
  identityRows <- queryServer server "SELECT toString(serverUUID()) AS server_id" >>= convert :: IO [Value]
  actualId <- case identityRows of [row] -> field "server_id" row; _ -> fail "Missing server identity"
  direct <- runDriverExpected (Just actualId) driver server (serverEndpoint server) "guarded-command" "guarded_direct" "CREATE TABLE default.guarded_direct (id UInt8) ENGINE=Memory" 3000000 1048576
  expectFirst "acknowledged-success" direct
  assert "Direct target effect absent" =<< exists server "guarded_direct"
  putStrLn "direct native admission: explicit identity encoding; acknowledged application effect"
  withFaultProxy server $ \proxy -> do
    report <- runDriverExpected (Just actualId) driver server (proxyEndpoint proxy) "guarded-command" "guarded_success" "CREATE TABLE default.guarded_success (id UInt8) ENGINE=Memory" 3000000 1048576
    expectFirst "acknowledged-success" report
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Unexpected admission/request count" (length events == 3)
    paths <- mapM (field "path") events :: IO [Text]
    assert "Completion policy missing on independent request" (all (\path -> all (`Text.isInfixOf` path) ["async_insert=0", "mutations_sync=1", "alter_sync=1", "wait_end_of_query=1"]) paths)
    putStrLn "guarded target: fresh-connection admission + explicit probe + one SQL; fixed policy on all three"
  withFaultProxy server $ \proxy -> do
    report <- runDriver driver server (proxyEndpoint proxy) "guarded-command" "wrong_identity" "CREATE TABLE default.wrong_identity (id UInt8) ENGINE=Memory" 3000000 1048576
    verification <- field "verificationError" report :: IO Value
    assert "Wrong identity accepted" (verification /= Null)
    present <- exists server "wrong_identity"
    assert "Wrong identity executed application SQL" (not present)
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Wrong identity reached application request" (length events == 1)
    putStrLn "wrong identity: rejected on new connection before application SQL"
  mapM_
    ( \mode -> withFaultProxy server $ \proxy -> do
        setFault proxy mode
        report <- runDriverExpected (Just actualId) driver server (proxyEndpoint proxy) "guarded-command" "unsupported_admission" "CREATE TABLE default.unsupported_admission (id UInt8) ENGINE=Memory" 3000000 1048576
        verification <- field "verificationError" report :: IO Value
        assert "Unsupported server/policy accepted" (verification /= Null)
        present <- exists server "unsupported_admission"
        assert "Unsupported admission executed SQL" (not present)
        events <- proxyEvents proxy >>= convert :: IO [Value]
        assert "Unsupported admission was retried" (length events == 1)
        putStrLn (show mode ++ ": admission rejected; no application SQL")
    )
    [UnsupportedVersion, PrereleaseVersion, WeakenedPolicy]
  withFaultProxy server $ \proxy -> do
    setFaultForQuery proxy "guarded_drop" DropResponse
    report <- runDriverExpected (Just actualId) driver server (proxyEndpoint proxy) "guarded-command" "guarded_drop" "CREATE TABLE default.guarded_drop (id UInt8) ENGINE=Memory" 3000000 1048576
    expectFirst "submission-uncertain" report
    assert "Guarded effect missing" =<< exists server "guarded_drop"
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Guarded application POST replayed" (length events == 3)
    putStrLn "guarded lost response: two admission reads, exactly one application SQL, effect retained"
  withFaultProxy server $ \proxy -> do
    setFaultForQuery proxy "reconnect_identity" SwitchIdentityAfterResponse
    report <- runDriverExpected (Just actualId) driver server (proxyEndpoint proxy) "guarded-reuse" "reconnect_identity" "CREATE TABLE IF NOT EXISTS default.reconnect_identity (id UInt8) ENGINE=Memory" 3000000 1048576
    results <- outcomes report
    kinds <- mapM (field "outcome") results :: IO [Text]
    assert "Fresh connection bypassed identity admission" (kinds == ["acknowledged-success", "not-submitted"])
    events <- proxyEvents proxy >>= convert :: IO [Value]
    paths <- mapM (field "path") events :: IO [Text]
    assert "Second application SQL was sent to changed identity" (length events == 4 && not (any (Text.isInfixOf "query_id=reconnect_identity-second&") paths))
    putStrLn "reconnect: changed identity blocks second application SQL before its bytes are submitted"
  withFaultProxy server $ \proxy -> do
    report <- runDriver driver server (proxyEndpoint proxy) "after-scope" "closed_scope" "CREATE TABLE default.closed_scope (id UInt8) ENGINE=Memory" 3000000 1048576
    expectFirst "not-submitted" report
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Closed capability submitted SQL" (null events)
    putStrLn "closed scope: escaped private handle cannot submit"

  withFaultProxy server $ \proxy -> do
    setFault proxy DropResponse
    report <- runDriver driver server (proxyEndpoint proxy) "cleanup-failure" "cleanup_fault" "CREATE TABLE default.cleanup_fault (id UInt8) ENGINE=Memory" 3000000 1048576
    expectFirst "submission-uncertain" report
    failures <- field "cleanupErrors" report :: IO [Value]
    codes <- mapM (field "code") failures :: IO [Text]
    assert "Cleanup replaced primary failure" (codes == ["CleanupFailed"])
    putStrLn "cleanup failure: primary uncertainty and separate cleanup error retained"
  withFaultProxy server $ \proxy -> do
    report <- runDriver driver server (proxyEndpoint proxy) "cleanup-timeout" "cleanup_timeout" "CREATE TABLE default.cleanup_timeout (id UInt8) ENGINE=Memory" 3000000 1048576
    expectFirst "acknowledged-success" report
    failures <- field "cleanupErrors" report :: IO [Value]
    codes <- mapM (field "code") failures :: IO [Text]
    assert "Cleanup deadline was hidden or treated as SQL failure" (codes == ["CleanupTimedOut"])
    putStrLn "cleanup timeout: bounded and distinct from acknowledged SQL"
  withFaultProxy server $ \proxy -> do
    let file = serverLogDirectory server </> "live_cleanup.sql"
    BS.writeFile file "CREATE TABLE default.live_cleanup (id UInt8) ENGINE=Memory"
    (_, output, _, process) <- createProcess (proc driver ["linger", Text.unpack (proxyEndpoint proxy), "live_cleanup", file, "3000000", "1048576"]) {std_out = CreatePipe}
    case output of
      Nothing -> terminateProcess process >> fail "Missing driver pipe"
      Just handle ->
        ( do
            line <- Char8.hGetLine handle
            report <- either (const (fail "Invalid live driver response")) pure (Aeson.eitherDecodeStrict' line)
            expectFirst "acknowledged-success" report
            threadDelay 100000
            status <- getProcessExitCode process
            assert "Cleanup test waited for process exit" (status == Nothing)
            active <- proxyConnections proxy
            assert "Sockets remained open after HTTP scope exit" (active == 0)
            void (waitForProcess process)
            putStrLn "socket cleanup: zero open connections while driver process is still alive"
        )
          `finally` (hClose handle >> terminateProcess process >> void (waitForProcess process))

completionCases :: FilePath -> Server -> IO ()
completionCases driver server = do
  let send identity sql = do
        report <- runDriver driver server (serverEndpoint server) "command" identity sql 10000000 1048576
        expectFirst "acknowledged-success" report
        pure report
  _ <- send "completion_create" "CREATE TABLE default.completion (id UInt32, value UInt32) ENGINE=MergeTree ORDER BY id"
  _ <- send "synchronous_insert" "INSERT INTO default.completion VALUES (1,10)"
  count <- scalar server "SELECT toUInt32(count()) AS value FROM default.completion"
  assert "INSERT returned before synchronous visibility" (count == 1)
  _ <- send "local_alter" "ALTER TABLE default.completion ADD COLUMN note String DEFAULT 'ok'"
  columns <- scalar server "SELECT toUInt32(count()) AS value FROM system.columns WHERE database='default' AND table='completion' AND name='note'"
  assert "Local ALTER not complete" (columns == 1)
  putStrLn "completion: async_insert=0 overrides async profile; INSERT visible immediately; local ALTER metadata complete"
  void (queryServer server "SYSTEM STOP MERGES default.completion")
  done <- newEmptyMVar
  let mutation = runDriver driver server (serverEndpoint server) "command" "mutation_barrier" "ALTER TABLE default.completion UPDATE value=value+1 WHERE id=1" 10000000 1048576
      waitPending 0 = fail "Mutation never entered the controlled queue"
      waitPending n = do
        pending <- scalar server "SELECT toUInt32(count()) AS value FROM system.mutations WHERE database='default' AND table='completion' AND NOT is_done"
        if pending > 0 then pure () else threadDelay 50000 >> waitPending (n - 1)
  ( bracket (forkFinally mutation (putMVar done)) killThread $ \_ -> do
      waitPending (40 :: Int)
      threadDelay 300000
      early <- tryReadMVar done
      assert "Mutation returned before local completion" (case early of Nothing -> True; _ -> False)
      void (queryServer server "SYSTEM START MERGES default.completion")
      result <- takeMVar done >>= either throwIO pure
      expectFirst "acknowledged-success" result
      value <- scalar server "SELECT toUInt32(value) AS value FROM default.completion WHERE id=1"
      assert "Mutation acknowledged before effects" (value == 11)
    )
    `finally` void (queryServer server "SYSTEM START MERGES default.completion")
  putStrLn "mutation completion: request blocks while merges are stopped, then acknowledges only after the update"
  _ <- send "delayed_create" "CREATE TABLE default.delayed_ledger_event (id UInt8) ENGINE=Memory"
  withFaultProxy server $ \proxy -> do
    report <- runDriver driver server (proxyEndpoint proxy) "command" "delayed_ledger_insert" "INSERT INTO default.delayed_ledger_event SELECT toUInt8(sleep(2))" 150000 1048576
    expectFirst "submission-uncertain" report
    empty <- scalar server "SELECT toUInt32(count()) AS value FROM default.delayed_ledger_event"
    active <- scalar server "SELECT toUInt32(count()) AS value FROM system.processes WHERE query_id='delayed_ledger_insert'"
    assert "Test did not observe empty history with an in-flight write" (empty == 0 && active == 1)
    waitRows server "SELECT toUInt32(count()) AS value FROM default.delayed_ledger_event" 60
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Delayed INSERT replayed" (length events == 1)
    putStrLn "delayed ledger-style INSERT: empty read while request active; row arrives later; requests=1"
  _ <- send "cancel_create" "CREATE TABLE default.cancelled_insert (id UInt8) ENGINE=Memory"
  withFaultProxy server $ \proxy -> do
    let file = serverLogDirectory server </> "cancelled_insert.sql"
    BS.writeFile file "INSERT INTO default.cancelled_insert SELECT toUInt8(sleep(2))"
    (status, output, _) <- readCreateProcessWithExitCode (proc driver ["cancel", Text.unpack (proxyEndpoint proxy), "cancelled_insert", file, "5000000", "1048576"]) ""
    assert "Cancellation became ordinary success" (status /= ExitSuccess)
    assert "Cancellation diagnostics leaked credentials" (not ("test-password" `Text.isInfixOf` Text.pack output))
    active <- scalar server "SELECT toUInt32(count()) AS value FROM system.processes WHERE query_id='cancelled_insert'"
    empty <- scalar server "SELECT toUInt32(count()) AS value FROM default.cancelled_insert"
    assert "Server request did not survive client cancellation" (active == 1 && empty == 0)
    waitRows server "SELECT toUInt32(count()) AS value FROM default.cancelled_insert" 60
    events <- proxyEvents proxy >>= convert :: IO [Value]
    assert "Cancellation replayed INSERT" (length events == 1)
    putStrLn "cancellation: async exception rethrown after client cleanup; server work survives and later commits once"

scalar :: Server -> Text -> IO Int
scalar server sql =
  queryServer server sql >>= convert >>= \case
    [row] -> field "value" row
    _ -> fail "Invalid independent scalar observation"

waitRows :: Server -> Text -> Int -> IO ()
waitRows _ _ 0 = fail "Delayed effect never completed"
waitRows server sql remaining = do
  count <- scalar server sql
  if count == 1 then pure () else threadDelay 50000 >> waitRows server sql (remaining - 1)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

-- Separate child processes exercise the public provider/initialization API.
exclusiveChild :: String -> String -> String -> String -> FilePath -> String -> String -> IO ()
exclusiveChild endpoint identity namespace ledger root micros evidence = do
  key <- right (Target.targetKey ("ledger-tests/" <> Text.pack namespace))
  credentials <- right (Target.basicCredentials "default" "test-password")
  requestMicros <- maybe 10000000 read <$> lookupEnv "CHM_CHILD_HTTP_MICROS"
  config <- Target.targetConfig key <$> right (Target.directEndpoint (Text.pack endpoint)) <*> right (Target.serverId (Text.pack identity)) <*> right (Target.ledgerNamespace (Text.pack namespace)) <*> pure Target.FirstUse <*> pure credentials <*> right (Target.httpLimits requestMicros 1048576)
  uuid <- right (Target.ledgerId (Text.pack ledger))
  audit <- right (Ledger.auditContext "test child administrator" "owned fixture handoff" ["owned process and all server requests independently quiescent"])
  quiet <- right (Ledger.attestQuiescence key audit)
  provider <- hostLocalExclusiveAccess root (read micros) (if evidence == "yes" then Just quiet else Nothing) >>= right
  report <- Ledger.initializeLedger config provider (Ledger.authorizeInitialization key uuid audit) quiet
  let status = case Ledger.result report of
        Right position -> object ["outcome" .= ("initialized" :: Text), "position" .= Ledger.ledgerPositionText position]
        Left (Ledger.AccessRejected problem) -> object ["outcome" .= ("access-rejected" :: Text), "code" .= show problem]
        Left (Ledger.RequestFailed requestEvidence failure receipt) -> object ["outcome" .= ("request-failed" :: Text), "code" .= show (Ledger.code failure), "evidence" .= show requestEvidence, "receipt" .= fmap Ledger.appendReceiptText receipt]
        Left (Ledger.InitializationFailed ledgerIdentity stage query requestEvidence failure) -> object ["outcome" .= ("ddl-failed" :: Text), "code" .= show (Ledger.code failure), "evidence" .= show requestEvidence, "ledgerId" .= ledgerIdentity, "stage" .= stage, "queryId" .= Target.queryIdText query]
        Left problem -> object ["outcome" .= ("rejected" :: Text), "code" .= show problem]
  let value = case status of Object fields -> Object (KM.insert "cleanupErrors" (Aeson.toJSON (map show (Ledger.cleanupErrors report))) fields); other -> other
  Lazy.putStr (Aeson.encode value)

ledgerCases :: FilePath -> Server -> IO ()
ledgerCases driver server = do
  identityRows <- queryServer server "SELECT toString(serverUUID()) AS server_id" >>= convert :: IO [Value]
  actualId <- case identityRows of [row] -> field "server_id" row; _ -> fail "Missing server identity"
  let file = serverLogDirectory server </> "ledger-smoke.sql"
  BS.writeFile file ""
  inherited <- getEnvironment
  let configured = ("CHM_EXPECTED_SERVER_ID", Text.unpack actualId) : filter ((/= "CHM_EXPECTED_SERVER_ID") . fst) inherited
  (exit, output, _) <- readCreateProcessWithExitCode ((proc driver ["ledger-smoke", Text.unpack (serverEndpoint server), "ledger-smoke", file, "10000000", "1048576"]) {env = Just configured}) ""
  assert "Private ledger roundtrip failed" (exit == ExitSuccess)
  value <- either (const (fail "Invalid ledger driver protocol")) pure (Aeson.eitherDecodeStrict' (Encoding.encodeUtf8 (Text.pack output)))
  field "roundtrip" value >>= assert "Ledger byte roundtrip mismatch"
  putStrLn "ledger: direct native initialization + immutable append/read roundtrip; quoted/newline audit text preserved"
  ledgerFaultCases driver server

exclusiveCases :: Server -> IO ()
exclusiveCases server = do
  binary <- getExecutablePath
  identityRows <- queryServer server "SELECT toString(serverUUID()) AS server_id" >>= convert :: IO [Value]
  actualId <- case identityRows of [row] -> field "server_id" row; _ -> fail "Missing server identity"
  let root = serverLogDirectory server </> "locks"
      ledger = "01234567-89ab-4def-8123-456789abcdef"
      child endpoint namespace micros evidence = proc binary ["exclusive-child", Text.unpack endpoint, Text.unpack actualId, namespace, ledger, root, micros, evidence]
      launch command = do
        (status, output, _) <- readCreateProcessWithExitCode command ""
        assert "Public lock child failed" (status == ExitSuccess)
        either (const (fail "Invalid lock child protocol")) pure (Aeson.eitherDecodeStrict' (Encoding.encodeUtf8 (Text.pack output)))
      outcome expected value = field "outcome" value >>= assert "Wrong public lock outcome" . (== (expected :: Text))
      waitForPost proxy = do
        events <- proxyEvents proxy >>= convert :: IO [Value]
        if null events then threadDelay 10000 >> waitForPost proxy else pure ()
  withFaultProxy server $ \proxy -> do
    setFault proxy DelayFirstResponse
    (input, output, _, process) <- createProcess (child (proxyEndpoint proxy) "concurrent_history" "5000000" "yes") {std_out = CreatePipe}
    let close = do
          mapM_ hClose input
          mapM_ hClose output
          terminateProcess process
          void (waitForProcess process)
    ( do
        ready <- timeout 5000000 (waitForPost proxy)
        assert "First administrator never entered" (isJust ready)
        second <- launch (child (serverEndpoint server) "concurrent_history" "100000" "yes")
        outcome "access-rejected" second
        field "code" second >>= assert "Second process entered while first held lock" . (== ("AcquisitionTimedOut" :: Text))
        first <- case output of
          Just handle -> do
            bytes <- BS.hGetContents handle
            either (const (fail "Invalid first child result")) pure (Aeson.eitherDecodeStrict' bytes)
          Nothing -> fail "Missing child stdout"
        void (waitForProcess process)
        outcome "initialized" first
        blocked <- launch (child (serverEndpoint server) "concurrent_history" "1000000" "no")
        outcome "access-rejected" blocked
        field "code" blocked >>= assert "OS unlock was mistaken for quiescence" . (== ("PredecessorQuiescenceRequired" :: Text))
        resumed <- launch (child (serverEndpoint server) "concurrent_history" "1000000" "yes")
        outcome "initialized" resumed
        before <- field "position" first :: IO Text
        after <- field "position" resumed :: IO Text
        assert "Initialized ledger was rewritten" (before == after)
        putStrLn "exclusive: two processes excluded; timeout typed; clean OS unlock still requires quiescence; same UUID/position retained"
      )
      `finally` close
  withFaultProxy server $ \proxy -> do
    setFault proxy DelayFirstResponse
    (_, output, _, process) <- createProcess (child (proxyEndpoint proxy) "crashed_history" "1000000" "yes") {std_out = CreatePipe}
    ready <- timeout 5000000 (waitForPost proxy)
    assert "Crash test owner never acquired" (isJust ready)
    terminateProcess process
    void (waitForProcess process)
    mapM_ hClose output
    blocked <- launch (child (serverEndpoint server) "crashed_history" "1000000" "no")
    outcome "access-rejected" blocked
    field "code" blocked >>= assert "Process death silently authorized successor" . (== ("PredecessorQuiescenceRequired" :: Text))
    putStrLn "exclusive: process death releases OS lock but persistent marker blocks successor without explicit evidence"
  -- Lease loss is checked at the actual socket write, including admission probes.
  key <- right (Target.targetKey "ledger-tests/lease_lost")
  credentials <- right (Target.basicCredentials "default" "test-password")
  uuid <- right (Target.ledgerId (Text.pack ledger))
  audit <- right (Ledger.auditContext "lease test" "forced loss" ["owned fixture, no predecessor requests"])
  quiet <- right (Ledger.attestQuiescence key audit)
  withFaultProxy server $ \proxy -> do
    setFault proxy DelayFirstResponse
    config <- Target.targetConfig key <$> right (Target.directEndpoint (proxyEndpoint proxy)) <*> right (Target.serverId actualId) <*> right (Target.ledgerNamespace "lease_lost") <*> pure Target.FirstUse <*> pure credentials <*> pure Target.defaultHttpLimits
    alive <- newIORef True
    provider <- right (Access.externallySerialized "controlled-test-lease" "complete isolated test target" 1000000 (const (pure ())) (const (pure ())) (const (readIORef alive)))
    finished <- newEmptyMVar
    bracket (forkFinally (Ledger.initializeLedger config provider (Ledger.authorizeInitialization key uuid audit) quiet) (putMVar finished)) killThread $ \_ -> do
      ready <- timeout 5000000 (waitForPost proxy)
      assert "Lease-loss probe was never submitted" (isJust ready)
      writeIORef alive False
      report <- takeMVar finished >>= either throwIO pure
      assert "Lease loss did not stop command" (case Ledger.result report of Left (Ledger.RequestFailed Ledger.PositiveNonSubmission failure _) -> Ledger.code failure == Ledger.AdministrativeAccessLost; _ -> False)
      requests <- proxyEvents proxy >>= convert :: IO [Value]
      assert "A request escaped after lease loss during admission" (length requests == 1)
    rows <- queryServer server "SELECT toUInt8(count()) AS count FROM system.databases WHERE name='lease_lost'" >>= convert :: IO [Value]
    count <- case rows of [row] -> field "count" row :: IO Int; _ -> fail "Missing lease observation"
    assert "Lost lease created a database" (count == 0)
    putStrLn "exclusive: loss DURING connection admission prevents the next HTTP write; no initialization DDL; no server-side fencing claimed"
