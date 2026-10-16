module FailureBoundaries (failureBoundaryCases) where

import ClickHouseMigrate
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Exception (finally)
import Control.Monad (forM_, when)
import Data.Aeson (Value)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import RunnerIntegration (assert, field, fixture, fromJson, planFor, provider, right)
import System.FilePath ((</>))

-- Every public observer boundary, separately for both statements. Numbers are
-- independently specified durable-event and application-request expectations.
callbacks :: [(E.EventPhase, Maybe T.Text, Int, Int)]
callbacks =
  [ (E.RunBeginning, Nothing, 0, 0),
    (E.BeforeMigrationStart, Nothing, 1, 0),
    (E.MigrationStarted, Nothing, 2, 0),
    (E.BeforeStepStart, Just "create", 2, 0),
    (E.StepStarted, Just "create", 3, 0),
    (E.BeforeSql, Just "create", 3, 0),
    (E.SqlObserved, Just "create", 3, 1),
    (E.BeforeStepSuccess, Just "create", 3, 1),
    (E.StepSucceeded, Just "create", 4, 1),
    (E.BeforeStepStart, Just "insert", 4, 1),
    (E.StepStarted, Just "insert", 5, 1),
    (E.BeforeSql, Just "insert", 5, 1),
    (E.SqlObserved, Just "insert", 5, 2),
    (E.BeforeStepSuccess, Just "insert", 5, 2),
    (E.StepSucceeded, Just "insert", 6, 2),
    (E.BeforeMigrationComplete, Nothing, 6, 2),
    (E.MigrationCompleted, Nothing, 7, 2),
    (E.RunCompleted, Nothing, 7, 2)
  ]

-- Every ordinary dependent append, including bootstrap and both step positions.
acknowledgements :: [(LedgerStage, Maybe T.Text, Int, Int)]
acknowledgements =
  [ (Initialization, Nothing, 0, 0),
    (MigrationStart, Nothing, 1, 0),
    (StepStart, Just "create", 2, 0),
    (StepSuccess, Just "create", 3, 1),
    (StepStart, Just "insert", 4, 1),
    (StepSuccess, Just "insert", 5, 2),
    (MigrationCompletion, Nothing, 6, 2)
  ]

historyEvents :: R.RunReport -> [R.HistoryEvent]
historyEvents (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ _ _ events _ _) _ _ _) = events

applicationCount :: FaultProxy -> IO Int
applicationCount proxy = do
  rows <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") rows :: IO [Maybe T.Text]
  pure (length (filter (== Just "application-sql") stages))

failureBoundaryCases :: Server -> IO ()
failureBoundaryCases server = do
  access <- provider
  audit <- right (L.auditContext "boundary fixture" "explicit isolated bootstrap" ["parent owns fixture and drains all requests before successor mutation"])
  forM_ (zip [0 :: Int ..] callbacks) $ \(number, (phase, selected, expectedEvents, expectedSql)) -> withFaultProxy server $ \proxy -> do
    let label = "callback_" <> T.pack (show number)
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    trace <- newIORef []
    saved <- newIORef "No result"
    let sink event@(E.RunEvent actual _ _ _ step _ _) = do
          modifyIORef' trace (++ [event])
          when (actual == phase && step == selected) (fail "callback SQL_SECRET_MARKER")
        save = do
          events <- readIORef trace
          requests <- proxyEvents proxy
          report <- readIORef saved
          TIO.writeFile (serverLogDirectory server </> T.unpack label ++ ".trace") (T.pack (show events) <> "\n" <> T.pack (show requests) <> "\n" <> report)
    ( do
        result <- Run.up (Run.mutationContext config access sink E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan
        writeIORef saved (T.pack (show result))
        report <- case result of Left (R.RunFailure (R.CallbackFailed _) report []) -> pure report; _ -> fail ("Wrong callback result: " ++ show result)
        assert "Callback failure lost acknowledged state" (length (historyEvents report) == expectedEvents)
        assert "Observer exception text leaked" (not ("SQL_SECRET_MARKER" `T.isInfixOf` T.pack (show result)))
        assert "Callback allowed later application SQL" . (== expectedSql) =<< applicationCount proxy
        bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
        observed <- I.history (I.Guarded access) bound
        when (expectedEvents > 0) $ do
          snapshot <- right observed
          writeIORef saved (T.pack (show result) <> "\n" <> T.pack (show snapshot))
          assert "Durable history diverged from acknowledged callback checkpoint" (case snapshot of R.HistoryReport _ _ _ _ _ actual _ _ -> length actual == expectedEvents)
        again <- Run.up (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit Nothing) plan
        if expectedEvents >= 2 && expectedEvents < 7
          then assert "Ordinary up used callback interruption as resume permission" (case again of Left (R.RunFailure (R.LedgerFailed L.UnresolvedHistory) _ _) -> True; _ -> False)
          else
            if expectedEvents == 0
              then assert "Missing ledger was implicitly initialized" (case again of Left _ -> True; _ -> False)
              else do
                _ <- right again
                pure ()
        let after = if expectedEvents == 1 then 2 else expectedSql
        assert "Restart replayed interrupted/completed SQL" . (== after) =<< applicationCount proxy
        putStrLn ("callback boundary " ++ show phase ++ "/" ++ show selected ++ ": ack=" ++ show expectedEvents ++ ", sql=" ++ show expectedSql)
      )
      `finally` save
  forM_ (zip [0 :: Int ..] acknowledgements) $ \(number, (stage, step, expectedEvents, expectedSql)) -> withFaultProxy server $ \proxy -> do
    let label = "append_loss_" <> T.pack (show number)
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    maybe (setLedgerFault proxy stage DropResponse) (\name -> setLedgerStepFault proxy stage name DropResponse) step
    result <- Run.up (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan
    requests <- proxyEvents proxy
    TIO.writeFile (serverLogDirectory server </> T.unpack label ++ ".trace") (T.pack (show result) <> "\n" <> T.pack (show requests))
    report <- case result of Left (R.RunFailure (R.LedgerRequestFailed L.UncertainSubmission _ (Just _)) report []) -> pure report; _ -> fail ("Missing uncertain append receipt " ++ show result)
    assert "Unknown ledger append advanced acknowledged report" (length (historyEvents report) == expectedEvents)
    assert "SQL submitted before dependent acknowledgement" . (== expectedSql) =<< applicationCount proxy
    setFault proxy Pass
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    observed <- I.history (I.Guarded access) bound >>= right
    assert "Dropped ledger response did not persist exactly one event" (case observed of R.HistoryReport _ _ _ _ _ actual _ _ -> length actual == expectedEvents + 1)
    again <- Run.up (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit Nothing) plan
    if stage == Initialization
      then do _ <- right again; pure ()
      else
        if stage == MigrationCompletion
          then do _ <- right again; pure ()
          else assert "Restart replayed after ledger acknowledgement loss" (case again of Left (R.RunFailure (R.LedgerFailed L.UnresolvedHistory) _ _) -> True; _ -> False)
    assert "Acknowledgement loss caused application replay" . (== if stage == Initialization then 2 else expectedSql) =<< applicationCount proxy
    putStrLn ("ledger ack loss " ++ show stage ++ "/" ++ show step ++ ": ack=" ++ show expectedEvents ++ ", sql=" ++ show expectedSql)
  -- An observed error may follow an effect. An uncertain failure-record INSERT
  -- must remain secondary, and no observer exception can replace the SQL error.
  forM_ [False, True] $ \loseRecording -> withFaultProxy server $ \proxy -> do
    let label = if loseRecording then "failure_record_loss" else "failure_observer"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    let sink (E.RunEvent phase _ _ _ step query _) = do
          when (phase == E.BeforeSql && step == Just "insert") $ do
            maybe (fail "Missing query") (\q -> setFaultForQuery proxy (queryIdText q) LateError) query
            when loseRecording (addLedgerFault proxy FailureRecording DropResponse)
          when (phase == E.SqlObserved && step == Just "insert") (fail "observer SQL_SECRET_MARKER")
    result <- Run.up (Run.mutationContext config access sink E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan
    case result of
      Left (R.RunFailure (R.SqlFailed _ _ L.ObservedFailure _) report secondary) -> do
        assert "Primary SQL error replaced or checkpoint lost" (length (historyEvents report) == if loseRecording then 5 else 6)
        assert "Secondary observer error lost" (any (\case R.ObserverError _ -> True; _ -> False) secondary)
        assert "Secondary recording uncertainty lost" (any (\case R.RecordingError (R.LedgerRequestFailed L.UncertainSubmission _ (Just _)) -> True; _ -> False) secondary == loseRecording)
      _ -> fail ("Wrong composite failure " ++ show result)
    assert "Failure recording caused SQL replay" . (== 2) =<< applicationCount proxy
    putStrLn ("SQL observed failure + observer failure + uncertain recording=" ++ show loseRecording ++ ": primary and checkpoint preserved")
  -- Loss after observed SQL prevents a checkpoint write; release faults preserve
  -- successful work as a cleanup-only failure. Neither is replay permission.
  forM_ [False, True] $ \loseLease -> withFaultProxy server $ \proxy -> do
    let label = if loseLease then "lease_after_sql" else "release_after_complete"
    alive <- newIORef True
    custom <- right (Access.externallySerialized "owned-parent-with-injected-fault" "all controlled requests drained before next job" 1000000 (const (pure ())) (const (when (not loseLease) (fail "release secret"))) (const (readIORef alive)))
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    let sink (E.RunEvent phase _ _ _ step _ _) = when (loseLease && phase == E.SqlObserved && step == Just "insert") (writeIORef alive False)
    result <- Run.up (Run.mutationContext config custom sink E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan
    case result of
      Left (R.RunFailure primary report secondary) ->
        if loseLease
          then do
            assert "Lease loss allowed success append" (length (historyEvents report) == 5)
            assert "Wrong lease failure" (case primary of R.AccessFailed Access.AccessLost -> True; _ -> False)
          else do
            assert "Cleanup fault erased completed work" (length (historyEvents report) == 7)
            assert "Release failure did not remain separate" (primary == R.CleanupFailed && not (null secondary))
      _ -> fail ("Injected access fault disappeared " ++ show result)
    assert "Access fault replayed SQL" . (== 2) =<< applicationCount proxy
    putStrLn ("access boundary: lease loss=" ++ show loseLease ++ "; checkpoint and cleanup evidence preserved")
  forM_ [False, True] $ \failDiagnostic -> withFaultProxy server $ \proxy -> do
    let label = if failDiagnostic then "diagnostic_failure" else "diagnostic_optin"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    delivered <- newIORef []
    let diagnostic (E.SqlDiagnostic reference query sql) = do
          modifyIORef' delivered (++ [(reference, query, sql)])
          when failDiagnostic (fail "diagnostic SQL_SECRET_MARKER")
    result <- Run.up (Run.mutationContext config access E.quietEvents (E.sqlDiagnostics diagnostic)) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan
    if failDiagnostic
      then assert "Diagnostic exception failed to stop before SQL" (case result of Left (R.RunFailure (R.CallbackFailed R.SqlDiagnosticCallback) report []) -> length (historyEvents report) == 3; _ -> False)
      else do _ <- right result; pure ()
    assert "Opt-in diagnostic exception leaked into report" (not ("SQL_SECRET_MARKER" `T.isInfixOf` T.pack (show result)))
    observed <- readIORef delivered
    assert "Explicit diagnostic sink did not receive exact SQL" (length observed == if failDiagnostic then 1 else 2)
    assert "Diagnostic failure allowed SQL submission" . (== if failDiagnostic then 0 else 2) =<< applicationCount proxy
    putStrLn ("explicit SQL diagnostics: throwing sink=" ++ show failDiagnostic ++ "; safe default report and exact opt-in delivery")
