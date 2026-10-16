module CLIIntegration (cliCases, exampleCases) where

import ClickHouseMigrate
import ClickHouseMigrate.CLI
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Concurrent (threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeAsyncException, throwIO, try)
import Control.Monad (forM_, void, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as JSON
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Encoding
import RunnerIntegration (assert, field, fixture, fixtureWithLimits, fromJson, planFor, provider, right, scalar)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, readCreateProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

auditArgs :: TargetKey -> [String]
auditArgs key = ["--expect-target", T.unpack (targetKeyText key), "--actor", "CLI fixture", "--reason", "owned predecessor drained", "--evidence", "fixture/controlled-drain", "--quiescent"]

dispatch :: CommandEnvironment -> MigrationPlan -> [String] -> IO CommandResult
dispatch environment plan args = case parseInvocation args of Right (Invocation _ command) -> handleCommand environment plan command; Left _ -> fail "CLI integration argument error"

successful :: CommandResult -> IO CommandReport
successful (CommandResult _ (Right report)) = pure report
successful failure = fail (T.unpack (Encoding.decodeUtf8 (renderJson failure)))

checkpoint :: CommandResult -> IO (L.LedgerPosition, L.AttemptId, Maybe R.StepAttempt)
checkpoint result = case result of
  CommandResult _ (Right (StatusReport (R.InspectionReport (R.HistoryReport _ _ _ (Just position) _ _ _ _) (R.MigrationSummary _ _ (Just attempt) steps : _) _))) -> pure (position, attempt, case [selected | R.StepSummary _ _ R.StepUncertain (Just selected) _ <- steps] of selected : _ -> Just selected; _ -> Nothing)
  _ -> fail "CLI checkpoint missing"

repairArgs :: TargetKey -> String -> (L.LedgerPosition, L.AttemptId, Maybe R.StepAttempt) -> [String]
repairArgs key operation (position, attempt, selected) = ["repair", operation] ++ auditArgs key ++ ["--expect-position", T.unpack (L.ledgerPositionText position), "--attempt", T.unpack (L.attemptIdText attempt)] ++ if operation `elem` ["accept-step", "retry-step"] then case selected of Just (R.StepAttempt owner name query) -> ["--step-attempt", T.unpack (L.attemptIdText owner), "--step", T.unpack name, "--query-id", T.unpack (queryIdText query)]; _ -> [] else []

applicationCount :: FaultProxy -> IO Int
applicationCount proxy = do
  rows <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") rows :: IO [Maybe T.Text]
  pure (length (filter (== Just "application-sql") stages))

cliCases :: Server -> IO ()
cliCases server = do
  access <- provider
  forM_ ["accept-step", "retry-step", "resume"] $ \operation -> withFaultProxy server $ \proxy -> do
    let label = "cli_" <> T.replace "-" "_" (T.pack operation)
    ledger <- newLedgerId
    first <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    plan <- planFor label 7
    let key = configuredTargetKey first
        environment config sink = commandEnvironment (Just config) (Just access) sink E.redactedDiagnostics AdministrativeCommands
        clean = environment bound E.quietEvents
    forM_ [["status"], ["history"], ["verify"]] $ \args -> void (dispatch (environment first E.quietEvents) plan args >>= successful)
    pending <- dispatch (environment first E.quietEvents) plan ["verify", "--require-current"]
    assert "CLI require-current allowed pending" (case pending of CommandResult _ (Left (InspectionFailed (R.InspectionFailure R.VerificationNotCurrent _ _))) -> True; _ -> False)
    noInit <- dispatch clean plan (["up"] ++ auditArgs key)
    assert "CLI implicitly initialized" (case noInit of CommandResult _ (Left (RunFailed (R.RunFailure R.LedgerRequired _ _))) -> True; _ -> False)
    let stop (E.RunEvent phase _ _ _ step query _) =
          when (step == Just "insert") $
            if operation == "resume"
              then when (phase == E.BeforeStepStart) (fail "stop before pending step SQL_SECRET_MARKER")
              else when (phase == E.BeforeSql) $ case query of Just identity -> setFaultForQuery proxy (queryIdText identity) DropResponse; _ -> fail "Missing CLI query"
    partial <- dispatch (environment first stop) plan (["up"] ++ auditArgs key ++ ["--initialize-ledger", T.unpack (ledgerIdText ledger)])
    let bytes = renderJson partial
    assert "CLI failed to preserve partial failure" (case partial of CommandResult _ (Left (RunFailed (R.RunFailure _ (R.RunReport _ _ _ _ _ [R.MigrationSummary _ R.InProgress _ (R.StepSummary _ _ R.StepObservedSuccess _ _ : _)] _ _) _))) -> True; _ -> False)
    assert "CLI result leaked SQL" (not (BS.isInfixOf "SQL_SECRET_MARKER" bytes) && not (BS.isInfixOf "test-password" bytes))
    _ <- right (JSON.eitherDecodeStrict' bytes :: Either String Value)
    setFault proxy Pass
    before <- dispatch clean plan ["status", "--guarded"] >>= checkpoint
    recovered <- dispatch clean plan (repairArgs key operation before) >>= successful
    stale <- dispatch clean plan (repairArgs key operation before)
    assert "CLI stale repair accepted" (case stale of CommandResult _ (Left (RunFailed (R.RunFailure (R.StalePosition _ _) _ _))) -> True; _ -> False)
    when (operation /= "resume") $ do
      after <- dispatch clean plan ["status", "--guarded"] >>= checkpoint
      void (dispatch clean plan (repairArgs key "finalize" after) >>= successful)
    when (operation == "accept-step") $ assert "CLI accepted result lost weaker evidence" ("operator-attestation" `BS.isInfixOf` renderJson (CommandResult "repair.accept-step" (Right recovered)))
    void (dispatch clean plan ["verify", "--require-current"] >>= successful)
    void (dispatch clean plan (["up"] ++ auditArgs key) >>= successful)
    count <- scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
    assert "CLI replay/repair effects incorrect" (count == if operation == "retry-step" then 2 else 1)
    assert "CLI request count incorrect" . (== if operation == "retry-step" then 3 else 2) =<< applicationCount proxy
  withFaultProxy server $ \proxy -> do
    ledger <- newLedgerId
    first <- fixture server "cli_adoption" (proxyEndpoint proxy) FirstUse
    bound <- fixture server "cli_adoption" (proxyEndpoint proxy) (ExistingLedger ledger)
    plan <- planFor "cli_adoption" 7
    -- Independent synthetic predecessor effect; this is not library execution.
    void (queryServer server "CREATE TABLE default.cli_adoption (id UInt8, secret String) ENGINE=MergeTree ORDER BY id")
    void (queryServer server "INSERT INTO default.cli_adoption VALUES (7,'SQL_SECRET_MARKER')")
    let key = configuredTargetKey first
        file = serverLogDirectory server </> "cli-adoption.json"
        digest = case planReport plan of [PlanComponent _ _ [PlanMigration _ _ checksum _]] -> checksum; _ -> error "Unexpected adoption fixture plan"
        input = object ["schemaVersion" .= (1 :: Int), "source" .= ("synthetic-cli-predecessor" :: T.Text), "snapshotReference" .= ("fixture/retained-snapshot" :: T.Text), "rows" .= [object ["id" .= ("001.sql" :: T.Text), "appliedAt" .= ("2020-01-01" :: T.Text)]], "mappings" .= [object ["row" .= ("001.sql" :: T.Text), "component" .= ("app" :: T.Text), "migration" .= ("one" :: T.Text), "checksum" .= digest, "evidence" .= object ["level" .= ("operator-attestation" :: T.Text), "references" .= (["fixture/reviewed-entire-prefix"] :: [T.Text])]]]]
        environment config = commandEnvironment (Just config) (Just access) E.quietEvents E.redactedDiagnostics AdministrativeCommands
        args operation expected = ["adopt", operation] ++ auditArgs key ++ expected ++ ["--initialize-ledger", T.unpack (ledgerIdText ledger), "--request", file]
    BS.writeFile file (Lazy.toStrict (JSON.encode input))
    void (dispatch (environment first) plan (args "plan" ["--expect-absent"]) >>= successful)
    missing <- dispatch (environment first) plan (args "resume" ["--expect-absent"])
    assert "CLI resumed absent adoption batch" (case missing of CommandResult _ (Left (RunFailed _)) -> True; _ -> False)
    setLedgerFault proxy AdoptionEntry DropResponse
    partial <- dispatch (environment first) plan (args "apply" ["--expect-absent"])
    assert "CLI adoption lost append uncertainty" (case partial of CommandResult _ (Left (RunFailed (R.RunFailure (R.LedgerRequestFailed L.UncertainSubmission _ (Just _)) _ _))) -> True; _ -> False)
    setFault proxy Pass
    stale <- dispatch (environment bound) plan (args "resume" ["--expect-absent"])
    assert "CLI stale adoption plan accepted" (case stale of CommandResult _ (Left (AdoptionRejected _ _)) -> True; _ -> False)
    snapshot <- dispatch (environment bound) plan ["status", "--guarded"] >>= successful
    position <- case snapshot of StatusReport (R.InspectionReport (R.HistoryReport _ _ _ (Just value) _ _ _ _) _ _) -> pure value; _ -> fail "Missing adoption checkpoint"
    void (dispatch (environment bound) plan (args "resume" ["--expect-position", T.unpack (L.ledgerPositionText position)]) >>= successful)
    void (dispatch (environment bound) plan (args "apply" ["--expect-absent"]) >>= successful)
    assert "CLI adoption executed SQL" . (== 0) =<< applicationCount proxy
  withFaultProxy server $ \proxy -> do
    -- A delayed ledger acknowledgement has a separate receipt and no automatic
    -- retry. Release the controlled gate and establish complete drain ourselves.
    limits <- right (httpLimits 1000000 1048576)
    first <- fixtureWithLimits limits server "cli_delayed" (proxyEndpoint proxy) FirstUse
    ledger <- newLedgerId
    plan <- planFor "cli_delayed" 7
    let key = configuredTargetKey first
        environment sink = commandEnvironment (Just first) (Just access) sink E.redactedDiagnostics AdministrativeCommands
    setLedgerStepFault proxy StepSuccess "create" HoldBeforeForward
    delayed <- dispatch (environment E.quietEvents) plan (["up"] ++ auditArgs key ++ ["--initialize-ledger", T.unpack (ledgerIdText ledger)])
    assert "CLI delayed append receipt missing" (case delayed of CommandResult _ (Left (RunFailed (R.RunFailure (R.LedgerRequestFailed L.UncertainSubmission _ (Just _)) _ _))) -> True; _ -> False)
    assert "CLI delayed JSON lost receipt" ("chm-receipt1:" `BS.isInfixOf` renderJson delayed)
    releaseFault proxy
    drained <- timeout 5000000 (let wait = proxyConnections proxy >>= \n -> if n == 0 then pure () else threadDelay 10000 >> wait in wait)
    assert "CLI delayed request did not drain" (isJust drained)
  withFaultProxy server $ \proxy -> do
    first <- fixture server "cli_cancel" (proxyEndpoint proxy) FirstUse
    ledger <- newLedgerId
    plan <- planFor "cli_cancel" 7
    let cancel (E.RunEvent phase _ _ _ _ _ _) = when (phase == E.MigrationStarted) (throwIO ThreadKilled)
        environment = commandEnvironment (Just first) (Just access) cancel E.redactedDiagnostics AdministrativeCommands
    result <- try @SomeAsyncException (dispatch environment plan (["up"] ++ auditArgs (configuredTargetKey first) ++ ["--initialize-ledger", T.unpack (ledgerIdText ledger)]))
    assert "CLI converted cancellation into result" (case result of Left _ -> True; _ -> False)
  putStrLn "CLI: native inspection/current distinction, explicit init, all four repair handlers, stale refusal, partial JSON, delayed receipt and async propagation"

-- This invokes the application executable, capturing stdout and stderr separately.
-- It never talks to a pre-existing server or changes an external repository.
exampleCases :: Server -> IO ()
exampleCases server = do
  executable <- getEnv "CLICKHOUSE_MIGRATE_EXAMPLE"
  inherited <- filter (not . ("CHM_" `T.isPrefixOf`) . T.pack . fst) <$> getEnvironment
  let offline = (proc executable ["plan", "--json"]) {env = Just inherited}
  (offlineExit, offlineOut, offlineErr) <- readCreateProcessWithExitCode offline ""
  assert "Offline example failed without config" (offlineExit == ExitSuccess && null offlineErr)
  offlineValue <- right (JSON.eitherDecodeStrict' (Encoding.encodeUtf8 (T.pack offlineOut)) :: Either String Value)
  result <- field "result" offlineValue
  components <- field "components" result :: IO [Value]
  names <- mapM (field "name") components :: IO [T.Text]
  assert "Independent components/order missing" (names == ["catalog", "analytics"])
  withFaultProxy server $ \proxy -> do
    ledger <- newLedgerId
    first <- fixture server "example" (proxyEndpoint proxy) FirstUse
    let key = configuredTargetKey first
    identityRows <- queryServer server "SELECT toString(serverUUID()) AS identity" >>= fromJson :: IO [Value]
    identity <- case identityRows of [row] -> field "identity" row; _ -> fail "Missing example server identity"
    let configuration = [("CHM_TARGET", T.unpack (targetKeyText key)), ("CHM_ENDPOINT", T.unpack (proxyEndpoint proxy)), ("CHM_SERVER_ID", identity), ("CHM_LEDGER_DATABASE", "example_history"), ("CHM_PASSWORD", "test-password"), ("CHM_LOCK_ROOT", serverLogDirectory server </> "example-locks")]
        runWith configured binding args = do
          (exit, out, err) <- readCreateProcessWithExitCode ((proc executable args) {env = Just (configured ++ binding ++ inherited)}) ""
          value <- right (JSON.eitherDecodeStrict' (Encoding.encodeUtf8 (T.pack out)) :: Either String Value)
          assert "Example stdout/stderr leaked sensitive values" (not ("test-password" `T.isInfixOf` T.pack (out ++ err)) && not ("CREATE TABLE" `T.isInfixOf` T.pack (out ++ err)))
          pure (exit, value, err)
        run = runWith configuration
        bound = [("CHM_LEDGER_ID", T.unpack (ledgerIdText ledger))]
        upArgs = ["up", "--json"] ++ auditArgs key
    (initialExit, _, progress) <- run [] (["--progress"] ++ upArgs ++ ["--initialize-ledger", T.unpack (ledgerIdText ledger)])
    assert "Fresh example up/stream separation failed" (initialExit == ExitSuccess && "progress:" `T.isInfixOf` T.pack progress)
    before <- applicationCount proxy
    (secondExit, _, _) <- run bound upArgs
    assert "Second example up failed" (secondExit == ExitSuccess)
    assert "Second example up replayed SQL" . (== before) =<< applicationCount proxy
    forM_ [["status", "--json"], ["history", "--json"], ["verify", "--require-current", "--json"]] $ \args -> do (exit, _, err) <- run bound args; assert "Example inspection failed" (exit == ExitSuccess && null err)
    -- The same executable recovers an interrupted durable completion and then
    -- adopts the retained complete two-component prefix into a separate ledger.
    void (queryServer server "DROP TABLE default.chm_example_events SYNC")
    void (queryServer server "DROP TABLE default.chm_example_catalog SYNC")
    repairLedger <- newLedgerId
    let repairKey = rightKey "example/repair"
        configured label = map (\(name, value) -> if name == "CHM_LEDGER_DATABASE" then (name, "example_" ++ label ++ "_history") else if name == "CHM_TARGET" then (name, "example/" ++ label) else (name, value)) configuration
        repairBound = [("CHM_LEDGER_ID", T.unpack (ledgerIdText repairLedger))]
    setLedgerStepFault proxy StepSuccess "seed" DropResponse
    (partialExit, partial, _) <- runWith (configured "repair") [] (["up", "--json"] ++ auditArgs repairKey ++ ["--initialize-ledger", T.unpack (ledgerIdText repairLedger)])
    assert "Example failed completion looked successful" (partialExit == ExitFailure 1)
    failure <- field "error" partial
    primary <- field "primary" failure
    receipt <- field "pendingAppend" primary :: IO (Maybe T.Text)
    assert "Example lost exact completion receipt" (isJust receipt)
    setFault proxy Pass
    (_, observed, _) <- runWith (configured "repair") repairBound ["status", "--json"]
    observedResult <- field "result" observed >>= field "report"
    observation <- field "observation" observedResult
    position <- field "position" observation :: IO T.Text
    summaries <- field "migrations" observedResult :: IO [Value]
    active <- case summaries of firstSummary : _ -> field "attempt" firstSummary; _ -> fail "Missing example repair attempt"
    let finalArgs = ["repair", "finalize", "--json"] ++ auditArgs repairKey ++ ["--expect-position", T.unpack position, "--attempt", active] ++ maybe [] (\token -> ["--pending-append", T.unpack token]) receipt
    beforeFinal <- applicationCount proxy
    (finalExit, _, _) <- runWith (configured "repair") repairBound finalArgs
    assert "Example finalize failed" (finalExit == ExitSuccess)
    assert "Example finalize executed SQL" . (== beforeFinal) =<< applicationCount proxy
    (staleExit, _, _) <- runWith (configured "repair") repairBound finalArgs
    assert "Example stale finalize accepted" (staleExit == ExitFailure 1)
    (tailExit, _, _) <- runWith (configured "repair") repairBound (["up", "--json"] ++ auditArgs repairKey)
    assert "Example failed to complete appended component" (tailExit == ExitSuccess)
    adoptLedger <- newLedgerId
    entries <-
      mapM
        ( \component -> do
            name <- field "name" component :: IO T.Text
            migrations <- field "migrations" component :: IO [Value]
            digest <- case migrations of
              [migration] -> field "checksum" migration
              _ -> fail "Example migration count"
            pure (name, digest :: T.Text)
        )
        components
    let adoptKey = rightKey "example/adopt"
        file = serverLogDirectory server </> "example-adoption.json"
        input = object ["schemaVersion" .= (1 :: Int), "source" .= ("owned-example-predecessor" :: T.Text), "snapshotReference" .= ("fixture/example-completed-prefix" :: T.Text), "rows" .= [object ["id" .= name, "appliedAt" .= ("2020-01-01" :: T.Text)] | (name, _) <- entries], "mappings" .= [object ["row" .= name, "component" .= name, "migration" .= ("0001" :: T.Text), "checksum" .= digest, "evidence" .= object ["level" .= ("operator-attestation" :: T.Text), "references" .= (["fixture/complete-prefix-review"] :: [T.Text])]] | (name, digest) <- entries]]
        adoptArgs operation = ["adopt", operation, "--json"] ++ auditArgs adoptKey ++ ["--expect-absent", "--initialize-ledger", T.unpack (ledgerIdText adoptLedger), "--request", file]
    BS.writeFile file (Lazy.toStrict (JSON.encode input))
    beforeAdopt <- applicationCount proxy
    forM_ ["plan", "apply", "resume"] $ \operation -> do
      (adoptExit, _, _) <- runWith (configured "adopt") (if operation == "resume" then [("CHM_LEDGER_ID", T.unpack (ledgerIdText adoptLedger))] else []) (adoptArgs operation)
      assert "Example adoption command failed" (adoptExit == ExitSuccess)
    assert "Example adoption executed SQL" . (== beforeAdopt) =<< applicationCount proxy
    -- Deliberate process cancellation while a ledger INSERT is held. Client
    -- cleanup cannot itself establish server drain; the fixture releases it.
    let cancelConfig = map (\(name, value) -> if name == "CHM_LEDGER_DATABASE" then (name, "example_cancel_history") else if name == "CHM_TARGET" then (name, "example/cancel") else (name, value)) configuration
    canceledLedger <- newLedgerId
    baselineRows <- proxyEvents proxy >>= fromJson :: IO [Value]
    baselineStages <- mapM (field "stage") baselineRows :: IO [Maybe T.Text]
    let baseline = length (filter (== Just "migration-started") baselineStages)
    setLedgerFault proxy MigrationStart HoldBeforeForward
    (Nothing, Just output, Just errors, process) <- createProcess ((proc executable (["up", "--json"] ++ auditArgs (rightKey "example/cancel") ++ ["--initialize-ledger", T.unpack (ledgerIdText canceledLedger)])) {env = Just (cancelConfig ++ inherited), std_out = CreatePipe, std_err = CreatePipe})
    started <- timeout 10000000 (let wait = do rows <- proxyEvents proxy >>= fromJson :: IO [Value]; stages <- mapM (field "stage") rows :: IO [Maybe T.Text]; if length (filter (== Just "migration-started") stages) > baseline then pure () else threadDelay 10000 >> wait in wait)
    assert "Canceled subprocess never reached controlled request" (isJust started)
    terminateProcess process
    ended <- timeout 5000000 (waitForProcess process)
    hClose output
    hClose errors
    assert "Canceled subprocess did not exit" (isJust ended)
    releaseFault proxy
    drained <- timeout 5000000 (let wait = proxyConnections proxy >>= \n -> if n == 0 then pure () else threadDelay 10000 >> wait in wait)
    assert "Canceled subprocess left client/proxy request open" (isJust drained)
  putStrLn "example: offline composed plan; application-owned config; fresh/no-op up; inspection; separate stdout/progress; killed subprocess and controlled drain"
  where
    rightKey = either (error . show) id . targetKey
