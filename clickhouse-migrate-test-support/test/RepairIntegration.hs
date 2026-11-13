module RepairIntegration (repairEarlyCases) where

import ClickHouseMigrate
import ClickHouseMigrate.CLI qualified as CLI
import ClickHouseMigrate.Event qualified as Event
import ClickHouseMigrate.Inspection qualified as Inspect
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Exception (AsyncException (ThreadKilled), SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, void, when)
import Data.Aeson (Value)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import RunnerIntegration (assert, field, fixture, fromJson, planFor, provider, right, scalar)

planWithTail :: Text.Text -> IO MigrationPlan
planWithTail label = do
  create <- right (sqlStep "create" (Encoding.encodeUtf8 ("CREATE TABLE default." <> label <> " (id UInt8, secret String) ENGINE=MergeTree ORDER BY id")))
  insert <- right (sqlStep "insert" (Encoding.encodeUtf8 ("INSERT INTO default." <> label <> " VALUES (7,'SQL_SECRET_MARKER')")))
  later <- right (sqlStep "later" (Encoding.encodeUtf8 ("ALTER TABLE default." <> label <> " ADD COLUMN later UInt8")))
  one <- right (sqlMigration "one" (create :| [insert, later]))
  next <- right (sqlStep "next" (Encoding.encodeUtf8 ("INSERT INTO default." <> label <> " VALUES (9,'next',0)")))
  two <- right (sqlMigration "two" (next :| []))
  component <- right (migrationComponent "app" Set.empty (one :| [two]))
  right (migrationPlan (component :| []))

checkpoint :: R.RunReport -> IO (Ledger.LedgerPosition, Ledger.AttemptId, [R.StepSummary])
checkpoint (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just position) _ _ _ _) (R.MigrationSummary _ _ (Just attempt) steps : _) _ _) = pure (position, attempt, steps)
checkpoint _ = fail "Missing repair checkpoint/attempt"

selected :: [R.StepSummary] -> IO R.StepAttempt
selected (_ : R.StepSummary "insert" _ _ (Just attempt) _ : _) = pure attempt
selected _ = fail "Missing exact second step attempt"

evidenceFor :: Text.Text -> IO Repair.RecoveryEvidence
evidenceFor label = do
  key <- right (targetKey ("runner-tests/" <> label))
  audit <- right (Ledger.auditContext "recovery operator" "independently established safety/effects for this controlled operation" ["owned fixture: client ended and every controlled server request completed"])
  quiet <- right (Ledger.attestQuiescence key audit)
  right (Repair.recoveryEvidence audit quiet [])

-- Public consumer: construct all four variants before expanding crash cases.
compileRequests :: Ledger.LedgerPosition -> Ledger.AttemptId -> R.StepAttempt -> Repair.RecoveryEvidence -> IO ()
compileRequests position attempt step evidence = do
  _ <- right (Repair.resumeRequest position attempt evidence)
  _ <- right (Repair.retryStepRequest position attempt step evidence)
  _ <- right (Repair.acceptStepRequest position attempt step evidence)
  _ <- right (Repair.finalizeRequest position attempt evidence)
  assert "Attempt token cannot roundtrip" (Ledger.parseAttemptId (Ledger.attemptIdText attempt) == Right attempt)

applicationCount :: FaultProxy -> IO Int
applicationCount proxy = do
  rows <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") rows :: IO [Maybe Text.Text]
  pure (length (filter (== Just "application-sql") stages))

repairEarlyCases :: Server -> IO ()
repairEarlyCases server = do
  externalDrainCase server
  externalOperationCases server
  oversizedRecovery server
  access <- provider
  audit <- right (Ledger.auditContext "runner fixture" "explicit first use" ["owned server; parent serializes whole job"])
  withFaultProxy server $ \proxy -> do
    let label = "repair_retry"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planWithTail label
    let stop (Event.RunEvent phase _ _ _ step _ _) = when (phase == Event.BeforeSql && step == Just "insert") (fail "synthetic callback failure SQL_SECRET_MARKER")
    stopped <- Run.up (Run.mutationContext config access stop Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) plan
    initial <- case stopped of Left failure@(R.RunFailure (R.CallbackFailed _) report _) -> assert "Callback exception leaked SQL" (not ("SQL_SECRET_MARKER" `Text.isInfixOf` Text.pack (show failure))) >> pure report; _ -> fail "Before-SQL callback did not stop"
    (position, attempt, steps) <- checkpoint initial
    step <- selected steps
    evidence <- evidenceFor label
    compileRequests position attempt step evidence
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    let context = Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics
    unsafeResume <- right (Repair.resumeRequest position attempt evidence) >>= Repair.repair context plan
    assert "Resume replayed uncertain step" (case unsafeResume of Left (R.RunFailure (R.RepairNotAllowed R.UncertainStepRemains) _ _) -> True; _ -> False)
    retry <- right (Repair.retryStepRequest position attempt step evidence)
    retried <- Repair.repair context plan retry >>= right
    (after, active, checkpoints) <- checkpoint retried
    assert "Retry did not create a fresh attempt" (active /= attempt && after /= position)
    assert "Retry continued later steps" (case checkpoints of [R.StepSummary "create" _ R.StepObservedSuccess _ _, R.StepSummary "insert" _ R.StepObservedSuccess (Just fresh) _, R.StepSummary "later" _ R.StepPending _ _] -> fresh /= step; _ -> False)
    count <- scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
    assert "Retry SQL not submitted exactly once" (count == 1)
    assert "Retry submitted other SQL" . (== 2) =<< applicationCount proxy
    stale <- Repair.repair context plan retry
    assert "Old retry request accepted after checkpoint moved" (case stale of Left (R.RunFailure (R.StalePosition _ _) _ _) -> True; _ -> False)
    oversized <- right (Ledger.auditContext "operator" "combined recovery audits" (replicate 16 (Text.replicate 2048 "x")))
    oversizedQuiet <- right (Ledger.attestQuiescence key oversized)
    oversizedEvidence <- right (Repair.recoveryEvidence oversized oversizedQuiet [])
    refusedResume <- right (Repair.resumeRequest after active oversizedEvidence) >>= Repair.repair context plan
    assert "resume authorized oversized metadata" (case refusedResume of Left (R.RunFailure (R.RecoveryEventTooLarge R.RecoveryAuthorizationEvent) _ _) -> True; _ -> False)
    resumed <- right (Repair.resumeRequest after active evidence) >>= Repair.repair context plan >>= right
    let R.RunReport _ _ _ _ _ migrations _ _ = resumed
    assert "Resume continued another migration" (case migrations of [R.MigrationSummary _ R.Applied _ _, R.MigrationSummary _ R.Pending _ _] -> True; _ -> False)
    assert "Resume replayed completed checkpoints" . (== 3) =<< applicationCount proxy
    columns <- scalar server ("SELECT toUInt32(count()) AS value FROM system.columns WHERE database='default' AND table='" <> label <> "' AND name='later'")
    assert "Resume failed to execute pending suffix" (columns == 1)
    compatible <- Inspect.verify Inspect.Observe bound (Inspect.verifyOptions False) plan >>= right
    assert "Pending tail is not compatible" (case compatible of R.VerificationReport _ False -> True; _ -> False)
    current <- Inspect.verify Inspect.Observe bound (Inspect.verifyOptions True) plan
    assert "Require-current accepted pending tail" (case current of Left (R.InspectionFailure R.VerificationNotCurrent _ _) -> True; _ -> False)
    _ <- Run.up context (Run.upOptions audit Nothing) plan >>= right
    assert "Following ordinary up did not execute only the next migration" . (== 4) =<< applicationCount proxy
    putStrLn "repair: retry only selected step; fresh query/attempt; stale request refused; resume preserves checkpoints and stops at selected migration"
  withFaultProxy server $ \proxy -> do
    let label = "repair_accept"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    plan <- planFor label 7
    let stop (Event.RunEvent phase _ _ _ step _ _) = when (phase == Event.BeforeStepSuccess && step == Just "insert") (fail "stop after SQL acknowledgement")
    stopped <- Run.up (Run.mutationContext config access stop Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) plan
    initial <- case stopped of Left (R.RunFailure (R.CallbackFailed _) report _) -> pure report; _ -> fail "After-SQL callback did not stop"
    (position, attempt, steps) <- checkpoint initial
    step <- selected steps
    assert "Expected effect not independently present" . (== 1) =<< scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label <> " WHERE id=7")
    evidence <- evidenceFor label
    compileRequests position attempt step evidence
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    let context = Run.mutationContext bound access Event.quietEvents Event.redactedDiagnostics
    accept <- right (Repair.acceptStepRequest position attempt step evidence)
    accepted <- Repair.repair context plan accept >>= right
    (after, active, checkpoints) <- checkpoint accepted
    assert "Accepted completion conflated with observed success" (case checkpoints of [R.StepSummary _ _ R.StepObservedSuccess _ _, R.StepSummary _ _ R.StepAccepted _ (Just (R.EvidenceSummary Ledger.OperatorAttestation _))] -> True; _ -> False)
    assert "Accept executed SQL or silently finalized" . (== 2) =<< applicationCount proxy
    let R.RunReport _ _ _ _ _ migrations _ _ = accepted
    assert "Accept implicitly completed migration" (case migrations of [R.MigrationSummary _ R.InProgress _ _] -> True; _ -> False)
    stale <- Repair.repair context plan accept
    assert "Repeated accept was not stale" (case stale of Left (R.RunFailure (R.StalePosition _ _) _ _) -> True; _ -> False)
    final <- right (Repair.finalizeRequest after active evidence) >>= Repair.repair context plan >>= right
    assert "Finalize submitted application SQL" . (== 2) =<< applicationCount proxy
    _ <- Inspect.verify (Inspect.Guarded access) bound (Inspect.verifyOptions True) plan >>= right
    let R.RunReport _ _ _ _ _ finalMigrations _ _ = final
    assert "Finalization erased acceptance evidence" (case finalMigrations of [R.MigrationSummary _ R.Applied _ [_, R.StepSummary _ _ R.StepAccepted _ _]] -> True; _ -> False)
    putStrLn "repair: accept records attestation without SQL/continuation; explicit finalize submits no SQL and preserves accepted-vs-observed evidence"

-- REV-1/F3: authorization must not precede acceptance envelope validation.
oversizedRecovery :: Server -> IO ()
oversizedRecovery server = withFaultProxy server $ \proxy -> do
  access <- provider
  audit <- right (Ledger.auditContext "review fixture" "before SQL interruption" ["owned server"])
  ledger <- newLedgerId
  let label = "repair_oversized"
  config <- fixture server label (proxyEndpoint proxy) FirstUse
  bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
  key <- right (targetKey ("runner-tests/" <> label))
  create <- right (sqlStep "create" "CREATE TABLE default.repair_oversized (id UInt8) ENGINE=Memory")
  one <- right (sqlMigration "one" (create :| []))
  component <- right (migrationComponent "app" Set.empty (one :| []))
  plan <- right (migrationPlan (component :| []))
  let stop (Event.RunEvent phase _ _ _ _ _ _) = when (phase == Event.BeforeSql) (fail "review interruption")
  stopped <- Run.up (Run.mutationContext config access stop Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) plan
  initial <- case stopped of Left (R.RunFailure (R.CallbackFailed _) report _) -> pure report; _ -> fail "Expected interrupted single step"
  (position, attempt, steps) <- checkpoint initial
  step <- case steps of [R.StepSummary _ _ _ (Just exactStep) _] -> pure exactStep; _ -> fail "Missing selected step"
  quiet <- right (Ledger.attestQuiescence key audit)
  trace <- newIORef []
  let sink (Event.RunEvent phase _ _ _ _ _ _) = modifyIORef' trace (++ [phase])
      context = Run.mutationContext bound access sink Event.redactedDiagnostics
  -- Authorization fits; duplicated accepted references do not.
  big <- right (Ledger.auditContext "review" "oversized accepted evidence" (replicate 24 (Text.replicate 2000 "x")))
  evidence <- right (Repair.recoveryEvidence big quiet [])
  request <- right (Repair.acceptStepRequest position attempt step evidence)
  before <- Inspect.history Inspect.Observe bound >>= right
  rejected <- Repair.repair context plan request
  assert "wrong size rejection" (case rejected of Left (R.RunFailure (R.RecoveryEventTooLarge R.RecoveryAcceptanceEvent) _ _) -> True; _ -> False)
  after <- Inspect.history Inspect.Observe bound >>= right
  assert "size rejection advanced original position/attempt" (before == after)
  assert "rejected request submitted SQL" . (== 0) =<< applicationCount proxy
  phases <- readIORef trace
  assert "preparation failure emitted recovery acknowledgement" (Event.RecoveryAuthorized `notElem` phases && Event.StepAccepted `notElem` phases)
  -- Combined outer/quiescence evidence must reject all action variants.
  medium <- right (Ledger.auditContext "review" "two valid audits exceeding combined envelope" (replicate 16 (Text.replicate 2048 "x")))
  largeQuiet <- right (Ledger.attestQuiescence key medium)
  combined <- right (Repair.recoveryEvidence medium largeQuiet [])
  forM_ [Repair.retryStepRequest position attempt step combined, Repair.acceptStepRequest position attempt step combined] $ \input -> do
    result <- right input >>= Repair.repair context plan
    assert "oversized authorization not typed" (case result of Left (R.RunFailure (R.RecoveryEventTooLarge R.RecoveryAuthorizationEvent) _ _) -> True; _ -> False)
  hugeQuietAudit <- right (Ledger.auditContext "operator" "oversized quiescence only" (replicate 32 (Text.replicate 2048 "x")))
  hugeQuiet <- right (Ledger.attestQuiescence key hugeQuietAudit)
  hugeEvidence <- right (Repair.recoveryEvidence audit hugeQuiet [])
  refusedQuiet <- right (Repair.acceptStepRequest position attempt step hugeEvidence) >>= Repair.repair context plan
  assert "oversized quiescence not rejected" (case refusedQuiet of Left (R.RunFailure (R.RecoveryEventTooLarge R.RecoveryAuthorizationEvent) _ _) -> True; _ -> False)
  replacement <- right (Repair.recoveryEvidence audit quiet []) >>= right . Repair.acceptStepRequest position attempt step
  accepted <- Repair.repair context plan replacement >>= right
  (nextPosition, nextAttempt, _) <- checkpoint accepted
  final <- right (Repair.finalizeRequest nextPosition nextAttempt combined) >>= Repair.repair context plan
  assert "finalize authorized oversized metadata" (case final of Left (R.RunFailure (R.RecoveryEventTooLarge R.RecoveryAuthorizationEvent) _ _) -> True; _ -> False)
  _ <- right (Repair.finalizeRequest nextPosition nextAttempt =<< Repair.recoveryEvidence audit quiet []) >>= Repair.repair context plan >>= right
  _ <- Inspect.verify Inspect.Observe bound (Inspect.verifyOptions True) plan >>= right
  assert "accept/finalize submitted application SQL" . (== 0) =<< applicationCount proxy
  putStrLn "recovery size: oversized acceptance preserves (3,3) events, position and attempt; combined audits reject authorization; replacement against original position accepts and finalizes without SQL"

-- First real embedding producer/consumer: separate app-scoped credentials may
-- not inspect processes, while the parent owns every earlier completed request.
externalDrainCase :: Server -> IO ()
externalDrainCase server = do
  let label = "repair_external_drain"
      username = "repair_external_user"
  ledger <- newLedgerId
  key <- right (targetKey ("runner-tests/" <> label))
  access <- provider
  audit <- right (Ledger.auditContext "owned external-drain fixture" "all predecessor calls joined under parent exclusion" ["owned fixture: no runtime, schedule or predecessor remains"])
  quiet <- right (Ledger.attestQuiescence key audit)
  plan <- planWithTail label
  owner <- fixture server label (serverEndpoint server) FirstUse
  let stop (Event.RunEvent phase _ _ _ step _ _) = when (phase == Event.BeforeSql && step == Just "insert") (fail "controlled before-SQL stop")
  initial <- Run.up (Run.mutationContext owner access stop Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) plan
  report <- case initial of Left (R.RunFailure (R.CallbackFailed _) acknowledged _) -> pure acknowledged; _ -> fail "External fixture did not retain an uncertain intent"
  (position, attempt, steps) <- checkpoint report
  step <- selected steps
  config <- scopedRepairFixture server label username ledger False
  let context = Run.mutationContext config access Event.quietEvents Event.redactedDiagnostics
  strict <- right (Repair.recoveryEvidence audit quiet []) >>= right . Repair.retryStepRequest position attempt step
  rejected <- Repair.repair context plan strict
  assert "Strict repair did not refuse denied process metadata" (case rejected of Left (R.RunFailure (R.LedgerRequestFailed _ _ _) _ _) -> True; _ -> False)
  -- The observer is part of pre-authorization policy and cannot fail open.
  throwing <- right (Repair.externalDrainRecoveryEvidence audit quiet [] (const (fail "SQL_SECRET_MARKER"))) >>= right . Repair.retryStepRequest position attempt step
  failed <- Repair.repair context plan throwing
  assert "External observer failure did not stop authorization" (case failed of Left (R.RunFailure (R.CallbackFailed (R.EventCallback "RepairProcessObservation")) _ _) -> not ("SQL_SECRET_MARKER" `Text.isInfixOf` Text.pack (show failed)); _ -> False)
  cancelling <- right (Repair.externalDrainRecoveryEvidence audit quiet [] (const (throwIO ThreadKilled))) >>= right . Repair.retryStepRequest position attempt step
  cancelled <- try @SomeException (Repair.repair context plan cancelling)
  assert
    "Observer cancellation became an ordinary repair result"
    ( case cancelled of
        Left exception -> case fromException exception :: Maybe SomeAsyncException of
          Just _ -> True
          _ -> False
        Right _ -> False
    )
  observations <- newIORef []
  let sink observation = modifyIORef' observations (<> [observation])
      environment = CLI.commandEnvironment (Just config) (Just access) Event.quietEvents Event.redactedDiagnostics CLI.AdministrativeCommands
      input = CLI.AuditInput "owned embedding" "independent predecessor drain retained" ["owned fixture: all calls joined; no other submitter exists"]
      command = CLI.RepairCommand CLI.RetryStep (CLI.RepairInput key position attempt (Just step) input True [])
  result <- CLI.handleCommandWithExternalDrain sink environment plan command
  retried <- case result of CLI.CommandResult _ (Right (CLI.RunReport value)) -> pure value; _ -> fail (Text.unpack (Encoding.decodeUtf8 (CLI.renderJson result)))
  assert "Denied observation was erased into an empty result" . (== [Repair.ProcessObservationUnavailable]) =<< readIORef observations
  assert "External retry did not execute the exact selected step" . (== 1) =<< scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
  staleEvidence <- right (Repair.externalDrainRecoveryEvidence audit quiet [] sink)
  staleRequest <- right (Repair.retryStepRequest position attempt step staleEvidence)
  stale <- Repair.repair context plan staleRequest
  assert "External authority bypassed a stale position" (case stale of Left (R.RunFailure (R.StalePosition _ _) _ _) -> True; _ -> False)
  assert "Stale repair reached optional diagnostics" . (== 1) . length =<< readIORef observations
  (after, nextAttempt, _) <- checkpoint retried
  resumed <- right (Repair.resumeRequest after nextAttempt staleEvidence) >>= Repair.repair context plan >>= right
  assert "External resume failed the exact pending suffix" (case resumed of R.RunReport _ _ _ _ _ [R.MigrationSummary _ R.Applied _ _, R.MigrationSummary _ R.Pending _ _] _ _ -> True; _ -> False)
  assert "External resume replayed the selected insert" . (== 1) =<< scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
  putStrLn "external repair: actual denied metadata; strict refusal; callback failure/cancellation; CLI retry and SDK resume; stale-position refusal"

scopedRepairFixture :: Server -> Text.Text -> Text.Text -> LedgerId -> Bool -> IO TargetConfig
scopedRepairFixture server label username ledger ownProcesses = do
  key <- right (targetKey ("runner-tests/" <> label))
  void (queryServer server ("CREATE USER " <> username <> " IDENTIFIED WITH no_password"))
  void (queryServer server ("GRANT SELECT,INSERT,ALTER ON default." <> label <> " TO " <> username))
  void (queryServer server ("GRANT SELECT,INSERT ON " <> label <> "_history.* TO " <> username))
  forM_ ["databases", "tables", "columns", "storage_policies", "disks"] $ \table ->
    void (queryServer server ("GRANT SELECT ON system." <> table <> " TO " <> username))
  rows <- queryServer server "SELECT toString(serverUUID()) AS id" >>= fromJson :: IO [Value]
  identity <- case rows of [row] -> field "id" row; _ -> fail "Owned server identity missing"
  config <- targetConfig key <$> right (directEndpoint (serverEndpoint server)) <*> right (serverId identity) <*> right (ledgerNamespace (label <> "_history")) <*> pure (ExistingLedger ledger) <*> right (basicCredentials username "") <*> pure defaultHttpLimits
  when ownProcesses (void (queryServer server ("GRANT SELECT ON system.processes TO " <> username)))
  pure config

externalOperationCases :: Server -> IO ()
externalOperationCases server = forM_ [(visible, action) | visible <- [False, True], action <- ["retry", "accept", "finalize"], visible || action /= "retry"] $ \(visible, action) -> do
  let suffix = if visible then "own" else "denied"
      label = "repair_external_" <> action <> "_" <> suffix
      username = label <> "_user"
  ledger <- newLedgerId
  key <- right (targetKey ("runner-tests/" <> label))
  access <- provider
  audit <- right (Ledger.auditContext "scoped recovery fixture" "all previous native requests joined; parent retains target exclusion" ["owned serialized fixture: no unjoined client or schedule"])
  quiet <- right (Ledger.attestQuiescence key audit)
  plan <- planWithTail label
  owner <- fixture server label (serverEndpoint server) FirstUse
  let stop (Event.RunEvent phase _ _ _ step _ _) = when ((action == "finalize" && phase == Event.BeforeMigrationComplete) || (action /= "finalize" && phase == Event.BeforeSql && step == Just "insert")) (fail "controlled recovery boundary")
  initial <- Run.up (Run.mutationContext owner access stop Event.redactedDiagnostics) (Run.upOptions audit (Just (Ledger.authorizeInitialization key ledger audit))) plan
  report <- case initial of Left (R.RunFailure (R.CallbackFailed _) value _) -> pure value; _ -> fail "Scoped recovery interruption missing"
  (position, attempt, steps) <- checkpoint report
  when (action == "accept") (void (queryServer server ("INSERT INTO default." <> label <> " VALUES(7,'SQL_SECRET_MARKER')")))
  config <- scopedRepairFixture server label username ledger visible
  observations <- newIORef []
  evidence <- right (Repair.externalDrainRecoveryEvidence audit quiet [] (\observation -> modifyIORef' observations (<> [observation])))
  request <-
    if action == "finalize"
      then right (Repair.finalizeRequest position attempt evidence)
      else do
        step <- selected steps
        right (if action == "accept" then Repair.acceptStepRequest position attempt step evidence else Repair.retryStepRequest position attempt step evidence)
  let context = Run.mutationContext config access Event.quietEvents Event.redactedDiagnostics
      expectedObservation = if visible then Repair.NoVisibleRecordedQueries else Repair.ProcessObservationUnavailable
  repaired <- Repair.repair context plan request >>= right
  assert "Scoped observation lost its visibility distinction" . (== [expectedObservation]) =<< readIORef observations
  assert "Acceptance/finalization replayed or omitted actual effects" . (== 1) =<< scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
  when (action /= "finalize") $ do
    assert "Selected recovery ran the remaining suffix" . (== 0) =<< scalar server ("SELECT toUInt32(count()) AS value FROM system.columns WHERE database='default' AND table='" <> label <> "' AND name='later'")
    (after, next, _) <- checkpoint repaired
    _ <- right (Repair.resumeRequest after next evidence) >>= Repair.repair context plan >>= right
    assert "Scoped resume did not execute the pending suffix" . (== 1) =<< scalar server ("SELECT toUInt32(count()) AS value FROM system.columns WHERE database='default' AND table='" <> label <> "' AND name='later'")
  assert "Scoped recovery started another migration" . (== 1) =<< scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
  putStrLn ("external repair: " ++ Text.unpack action ++ "; process visibility=" ++ Text.unpack suffix ++ "; exact step and pending suffix preserved")
