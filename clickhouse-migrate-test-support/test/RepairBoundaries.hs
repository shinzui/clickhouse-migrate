module RepairBoundaries (repairBoundaryCases) where

import ClickHouseMigrate
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Monad (forM_, when)
import Data.Aeson (Value)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import RunnerIntegration (assert, field, fixture, fromJson, planFor, provider, right)
import System.FilePath ((</>))

checkpoint :: R.RunReport -> IO (L.LedgerPosition, L.AttemptId, [R.StepSummary])
checkpoint (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just position) _ _ _ _) [R.MigrationSummary _ _ (Just attempt) steps] _ _) = pure (position, attempt, steps)
checkpoint report = fail ("Missing active checkpoint " ++ show report)

selected :: [R.StepSummary] -> IO R.StepAttempt
selected [_, R.StepSummary "insert" _ _ (Just attempt) _] = pure attempt
selected _ = fail "Missing selected attempt"

count :: FaultProxy -> IO Int
count proxy = do
  rows <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") rows :: IO [Maybe T.Text]
  pure (length (filter (== Just "application-sql") stages))

repairBoundaryCases :: Server -> IO ()
repairBoundaryCases server = do
  access <- provider
  audit <- right (L.auditContext "repair boundary fixture" "independently controlled effects and request drain" ["parent owns fixture, clients ended, all predecessor requests drained"])
  -- All four authorizations, lost response and interrupted immediately after ack.
  forM_ [(action, lost) | action <- ["resume", "retry", "accept", "finalize"], lost <- [False, True]] $ \(action, lost) -> withFaultProxy server $ \proxy -> do
    let label = "repair_boundary_" <> action <> if lost then "_lost" else "_callback"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    let stop (E.RunEvent phase _ _ _ step _ _) =
          when ((action == "resume" && phase == E.BeforeStepStart && step == Just "insert") || (action == "retry" && phase == E.BeforeSql && step == Just "insert") || (action == "accept" && phase == E.BeforeStepSuccess && step == Just "insert") || (action == "finalize" && phase == E.BeforeMigrationComplete)) (fail "owned interruption")
    initial <-
      Run.up (Run.mutationContext config access stop E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan >>= \case
        Left (R.RunFailure (R.CallbackFailed _) report []) -> pure report
        other -> fail ("Did not establish repair state " ++ show other)
    (position, attempt, steps) <- checkpoint initial
    quiet <- right (L.attestQuiescence key audit)
    evidence <- right (Repair.recoveryEvidence audit quiet [])
    request <-
      right =<< case action of
        "resume" -> pure (Repair.resumeRequest position attempt evidence)
        "retry" -> do step <- selected steps; pure (Repair.retryStepRequest position attempt step evidence)
        "accept" -> do step <- selected steps; pure (Repair.acceptStepRequest position attempt step evidence)
        _ -> pure (Repair.finalizeRequest position attempt evidence)
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    let interrupted (E.RunEvent phase _ _ _ _ _ _) = when (phase == E.RecoveryAuthorized && not lost) (fail "authorization observer stopped")
        context = Run.mutationContext bound access interrupted E.redactedDiagnostics
        quietContext = Run.mutationContext bound access E.quietEvents E.redactedDiagnostics
    before <- count proxy
    when lost (setLedgerFault proxy RecoveryAuthorization DropResponse)
    stopped <- Repair.repair context plan request
    receipt <- case stopped of
      Left (R.RunFailure (R.LedgerRequestFailed L.UncertainSubmission _ (Just receipt)) _ []) | lost -> pure [receipt]
      Left (R.RunFailure (R.CallbackFailed _) _ []) | not lost -> pure []
      _ -> fail ("Wrong authorization interruption " ++ show stopped)
    assert "Unacknowledged/interrupted authorization executed SQL" . (== before) =<< count proxy
    setFault proxy Pass
    observed <- I.status (I.Guarded access) bound plan >>= right
    let R.InspectionReport snapshot current _ = observed
        R.HistoryReport _ _ _ currentPosition _ events _ _ = snapshot
    requests <- proxyEvents proxy
    TIO.writeFile (serverLogDirectory server </> T.unpack label ++ ".trace") (T.pack (show stopped) <> "\n" <> T.pack (show requests) <> "\n" <> T.pack (show observed))
    assert "Authorization absent from actual history" (case reverse events of R.HistoryEvent _ _ _ _ _ _ _ _ _ (R.RecoveryAuthorization {}) : _ -> True; _ -> False)
    ordinary <- Run.up quietContext (Run.upOptions audit Nothing) plan
    assert "Ordinary up consumed standing authorization" (case ordinary of Left (R.RunFailure (R.LedgerFailed L.UnresolvedHistory) _ _) -> True; _ -> False)
    stale <- Repair.repair quietContext plan request
    assert "Interrupted request was reusable without fresh state" (case stale of Left (R.RunFailure (R.StalePosition _ _) _ _) -> True; _ -> False)
    newPosition <- maybe (fail "Missing new position") pure currentPosition
    (newAttempt, newSteps) <- case current of [R.MigrationSummary _ _ (Just value) values] -> pure (value, values); _ -> fail "Missing new active attempt"
    assert "Authorization did not change attempt" (newAttempt /= attempt)
    freshEvidence <- right (Repair.recoveryEvidence audit quiet receipt)
    fresh <- case action of
      "accept" -> do
        step <- selected newSteps
        -- Even though active attempt changed, the selected query's original
        -- owner remains the original attempt; substituting the new one fails.
        let R.StepAttempt _ name query = step
        wrong <- right (Repair.acceptStepRequest newPosition newAttempt (R.StepAttempt newAttempt name query) freshEvidence)
        rejected <- Repair.repair quietContext plan wrong
        assert "Selected old query accepted with fabricated attempt owner" (case rejected of Left (R.RunFailure (R.StepAttemptMismatch _) _ _) -> True; _ -> False)
        right (Repair.acceptStepRequest newPosition newAttempt step freshEvidence)
      "finalize" -> right (Repair.finalizeRequest newPosition newAttempt freshEvidence)
      _ -> right (Repair.resumeRequest newPosition newAttempt freshEvidence)
    recovered <- Repair.repair quietContext plan fresh >>= right
    if action == "accept"
      then do
        (finalPosition, finalAttempt, _) <- checkpoint recovered
        finalize <- right (Repair.finalizeRequest finalPosition finalAttempt freshEvidence)
        _ <- Repair.repair quietContext plan finalize >>= right
        pure ()
      else pure ()
    _ <- I.verify I.Observe bound (I.verifyOptions True) plan >>= right
    assert "Recovery replayed completed steps or executed acceptance SQL" . (== 2) =<< count proxy
    putStrLn ("repair authorization " ++ T.unpack action ++ ": lost response=" ++ show lost ++ "; ordinary restart blocked; fresh request succeeds without replay")
  -- Acceptance and finalization have their own dependent append acknowledgements.
  forM_ [(StepAcceptance, True), (StepAcceptance, False), (MigrationCompletion, True)] $ \(stage, lost) -> withFaultProxy server $ \proxy -> do
    let label = if stage == StepAcceptance then (if lost then "accept_append_lost" else "accepted_callback") else "finalize_append_lost"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    let stop (E.RunEvent phase _ _ _ step _ _) = when ((stage == StepAcceptance && phase == E.BeforeStepSuccess && step == Just "insert") || (stage == MigrationCompletion && phase == E.BeforeMigrationComplete)) (fail "owned interruption")
    initial <- Run.up (Run.mutationContext config access stop E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan >>= \case Left (R.RunFailure _ report _) -> pure report; _ -> fail "Missing initial interruption"
    (position, attempt, steps) <- checkpoint initial
    quiet <- right (L.attestQuiescence key audit)
    evidence <- right (Repair.recoveryEvidence audit quiet [])
    request <- if stage == StepAcceptance then selected steps >>= \step -> right (Repair.acceptStepRequest position attempt step evidence) else right (Repair.finalizeRequest position attempt evidence)
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    when lost (setLedgerFault proxy stage DropResponse)
    let acceptedSink (E.RunEvent phase _ _ _ _ _ _) = when (not lost && phase == E.StepAccepted) (fail "accepted callback")
    result <- Repair.repair (Run.mutationContext bound access acceptedSink E.redactedDiagnostics) plan request
    assert
      "Dependent repair append/observer failure was hidden"
      ( case result of
          Left (R.RunFailure (R.LedgerRequestFailed L.UncertainSubmission _ (Just _)) _ []) -> lost
          Left (R.RunFailure (R.CallbackFailed _) report []) -> not lost && case report of R.RunReport _ _ _ _ _ [R.MigrationSummary _ R.InProgress _ [_, R.StepSummary _ _ R.StepAccepted _ _]] _ _ -> True; _ -> False
          _ -> False
      )
    assert "Acceptance/finalize sent application SQL" . (== 2) =<< count proxy
    setFault proxy Pass
    observed <- I.history I.Observe bound >>= right
    assert "Repair append did not commit once" (case observed of R.HistoryReport _ _ _ _ _ events _ _ -> case reverse events of R.HistoryEvent _ _ _ _ _ _ _ _ _ body : _ -> R.historyKind body == if stage == StepAcceptance then "step-accepted" else "migration-completed"; _ -> False)
    putStrLn ("repair dependent append loss: " ++ show stage ++ "; lost response=" ++ show lost ++ "; no SQL submitted")
