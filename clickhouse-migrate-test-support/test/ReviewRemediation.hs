-- Native review regressions through public commands on one disposable server.
module ReviewRemediation (remediationCases) where

import ClickHouseMigrate
import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (SomeAsyncException, fromException)
import Control.Monad (forM_, void, when)
import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import RunnerIntegration (assert, field, fixture, fixtureWithLimits, fromJson, provider, right, scalar)
import System.Timeout (timeout)

remediationCases :: Server -> IO ()
remediationCases server = do
  access <- provider
  audit <- right (L.auditContext "review fixture" "ordinary control evidence" ["owned server"])
  big <- right (L.auditContext "review fixture" "capacity reproduction" (replicate 24 (T.replicate 2000 "x")))
  let makeMigration name count sql = do
        steps <- mapM (\n -> right (sqlStep ("s" <> T.pack (show n)) sql)) [1 .. count :: Int]
        right (sqlMigrationFromList name steps)
      context config = Run.mutationContext config access E.quietEvents E.redactedDiagnostics
      run config evidence auth plan = Run.up (context config) (Run.upOptions evidence auth) plan >>= right
  -- The exact original 12-step / ~1.3 MiB reproduction with default limits.
  smallLedger <- newLedgerId
  small <- fixture server "stream_original" (serverEndpoint server) FirstUse
  smallBound <- fixture server "stream_original" (serverEndpoint server) (ExistingLedger smallLedger)
  original <- makeMigration "large" 12 "CREATE TABLE IF NOT EXISTS default.stream_original (id UInt8) ENGINE=Memory"
  originalComponent <- right (migrationComponent "capacity" Set.empty (original :| []))
  originalPlan <- right (migrationPlan (originalComponent :| []))
  _ <- run small big (Just (L.authorizeInitialization (configuredTargetKey small) smallLedger audit)) originalPlan
  originalHistory <- I.history I.Observe smallBound >>= right
  assert "original complete history" (case originalHistory of R.HistoryReport _ _ _ _ _ events _ False -> length events == 27; _ -> False)
  largeAdoption server
  putStrLn "stream: original 12-step large-audit history returns all 27 events with default limits"
  withFaultProxy server $ \proxy -> do
    ledger <- newLedgerId
    let label = "review_combined"
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    a1 <- makeMigration "one" 1 "CREATE TABLE default.review_combined (id UInt8) ENGINE=Memory"
    b1 <- makeMigration "one" 1 "CREATE TABLE default.review_combined_b (id UInt8) ENGINE=Memory"
    upgrades <- mapM (\n -> makeMigration ("upgrade-" <> T.pack (show n)) 18 "INSERT INTO default.review_combined VALUES (1)") [1 .. 10 :: Int]
    a <- right (migrationComponent "a" Set.empty (a1 :| []))
    aAll <- right (migrationComponent "a" Set.empty (a1 :| upgrades))
    b <- right (migrationComponent "b" (Set.singleton "a") (b1 :| []))
    initial <- right (migrationPlan (a :| [b]))
    let ident c m = migrationIdFromNames <$> componentName c <*> migrationName m
    order <- mapM (right . uncurry ident) ([("a", "one"), ("b", "one")] ++ [("a", "upgrade-" <> T.pack (show n)) | n <- [1 .. 10 :: Int]])
    full <- right (scheduledMigrationPlanFromList [aAll, b] order)
    _ <- run config audit (Just (L.authorizeInitialization (configuredTargetKey config) ledger audit)) initial
    _ <- run bound big Nothing full
    _ <- I.verify I.Observe bound (I.verifyOptions True) full >>= right
    observed <- I.history I.Observe bound >>= right
    let R.HistoryReport _ _ _ position _ events _ unresolved = observed
    assert "large complete event count" (length events == 389 && not unresolved)
    records <- proxyEvents proxy >>= fromJson :: IO [Value]
    historyRecords <- filterMHistory records
    sizes <- mapM (field "responseBytes") historyRecords :: IO [Int]
    rows <- mapM (field "maxRowBytes") historyRecords :: IO [Int]
    assert "fixture did not exceed old maximum" (maximum sizes > 16777216)
    assert "individual row exceeded default bound" (maximum rows <= 1048576)
    largeSnapshot <- I.status I.Observe bound full >>= right
    largePosition <- maybe (fail "Missing large history position") pure position
    quietForAdoption <- right (L.attestQuiescence (configuredTargetKey bound) audit)
    source <- right (A.legacyRow "a.sql" "2020-01-01T00:00:00Z" Nothing)
    let firstView = NE.head (inspectSchedule full)
    mapped <- right (A.attestedMapping "a.sql" "a" "one" (migrationChecksumHex (migrationChecksum firstView)) ["reviewed native prefix"])
    nonfresh <- right (A.adoptionRequest (configuredTargetKey bound) (L.ExpectPosition largePosition) Nothing quietForAdoption audit "new-source" "immutable-source" (source :| []) (mapped :| []))
    assert "adoption accepted large native history" (case A.planAdoption full largeSnapshot nonfresh of Left A.AdoptionNativeConflict -> True; _ -> False)
    _ <- run bound audit Nothing full
    assert "large schedule effects" . (== 180) =<< scalar server "SELECT toUInt32(count()) AS value FROM default.review_combined"
    putStrLn ("stream: wire bytes=" ++ show (maximum sizes) ++ "; max row=" ++ show (maximum rows) ++ "; events=" ++ show (length events) ++ "; status/history/currentness/no-op up pass")
    -- Exact physical duplicates remain transport-visible and project identically.
    void (queryServer server "INSERT INTO review_combined_history.events SELECT * FROM review_combined_history.events ORDER BY sequence LIMIT 1")
    duplicate <- I.history I.Observe bound >>= right
    assert "exact duplicates changed logical position" (case duplicate of R.HistoryReport _ _ _ after _ allEvents _ _ -> after == position && length allEvents == length events)
    -- Pending up and explicit recovery consume the same >16 MiB observation.
    pending <- makeMigration "pending" 1 "INSERT INTO default.review_combined VALUES (2)"
    tailMigration <- makeMigration "tail" 1 "INSERT INTO default.review_combined VALUES (3)"
    pendingComponent <- right (migrationComponent "a" Set.empty (a1 :| (upgrades ++ [pending])))
    completeComponent <- right (migrationComponent "a" Set.empty (a1 :| (upgrades ++ [pending, tailMigration])))
    pendingId <- right (ident "a" "pending")
    tailId <- right (ident "a" "tail")
    pendingPlan <- right (scheduledMigrationPlanFromList [pendingComponent, b] (order ++ [pendingId]))
    completePlan <- right (scheduledMigrationPlanFromList [completeComponent, b] (order ++ [pendingId, tailId]))
    _ <- run bound audit Nothing pendingPlan
    assert "large history pending up" . (== 181) =<< scalar server "SELECT toUInt32(count()) AS value FROM default.review_combined"
    let stop (E.RunEvent phase _ _ migration _ _ _) = when (phase == E.BeforeSql && migration == Just "tail") (fail "combined gate interruption")
    stopped <- Run.up (Run.mutationContext bound access stop E.redactedDiagnostics) (Run.upOptions audit Nothing) completePlan
    (originalPosition, attempt, selected) <- case stopped of
      Left (R.RunFailure (R.CallbackFailed _) (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just current) _ _ _ _) migrations _ _) _) ->
        case last migrations of R.MigrationSummary _ _ (Just attempt) [R.StepSummary _ _ _ (Just selected) _] -> pure (current, attempt, selected); _ -> fail "Missing combined selected step"
      _ -> fail "Combined tail did not stop"
    quiet <- right (L.attestQuiescence (configuredTargetKey bound) audit)
    oversized <- right (Repair.recoveryEvidence big quiet []) >>= right . Repair.acceptStepRequest originalPosition attempt selected
    beforeRecovery <- mutationCount proxy
    rejected <- Repair.repair (context bound) completePlan oversized
    assert "combined size error" (case rejected of Left (R.RunFailure (R.RecoveryEventTooLarge R.RecoveryAcceptanceEvent) _ _) -> True; _ -> False)
    afterRecovery <- mutationCount proxy
    assert "combined size rejection mutated" (beforeRecovery == afterRecovery)
    unchanged <- I.history I.Observe bound >>= right
    assert "combined size rejection changed position" (case unchanged of R.HistoryReport _ _ _ current _ _ _ _ -> current == Just originalPosition)
    evidence <- right (Repair.recoveryEvidence audit quiet [])
    request <- right (Repair.acceptStepRequest originalPosition attempt selected evidence)
    accepted <- Repair.repair (context bound) completePlan request >>= right
    (acceptedPosition, acceptedAttempt) <- case accepted of
      R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just current) _ _ _ _) migrations _ _ ->
        case last migrations of R.MigrationSummary _ _ (Just currentAttempt) _ -> pure (current, currentAttempt); _ -> fail "Missing accepted attempt"
      _ -> fail "Missing accepted position"
    finalize <- right (Repair.finalizeRequest acceptedPosition acceptedAttempt evidence)
    _ <- Repair.repair (context bound) completePlan finalize >>= right
    _ <- I.verify I.Observe bound (I.verifyOptions True) completePlan >>= right
    putStrLn "combined: large-history pending up executes once; interrupted tail rejects oversized acceptance without position change, accepts replacement and explicitly finalizes"
    forM_ [TruncateResponse, AppendLateError, OversizedHistoryRow, HistoryGap, HistoryIdentityConflict, HistoryDuplicateConflict] $ \mode -> do
      before <- mutationCount proxy
      setLedgerFault proxy HistoryRead mode
      result <- Run.up (context bound) (Run.upOptions audit Nothing) completePlan
      let expected = case result of
            Left (R.RunFailure (R.LedgerFailed problem) _ _) -> case mode of
              HistoryGap -> problem == L.SequenceGap
              HistoryIdentityConflict -> problem == L.EventIdentityConflict
              HistoryDuplicateConflict -> problem == L.EventIdentityConflict
              _ -> False
            Left (R.RunFailure (R.LedgerRequestFailed requestEvidence (L.TransportError code _ _) Nothing) _ _) -> case mode of
              TruncateResponse -> requestEvidence == L.UncertainSubmission && code == L.ResponseInterrupted
              AppendLateError -> requestEvidence == L.ObservedFailure && code == L.ServerRejected
              OversizedHistoryRow -> requestEvidence == L.UncertainSubmission && code == L.ResponseTooLarge
              _ -> False
            _ -> False
      let observedError = case result of Left (R.RunFailure problem _ _) -> show problem; Right _ -> "success"
      assert ("wrong stream failure: " ++ show mode ++ ": " ++ observedError) expected
      after <- mutationCount proxy
      assert "failed stream allowed mutation" (before == after)
      setFault proxy Pass
    setLedgerFault proxy HistoryRead DelayResponse
    limits <- right (httpLimits 500000 1048576)
    short <- fixtureWithLimits limits server label (proxyEndpoint proxy) (ExistingLedger ledger)
    expired <- I.history I.Observe short
    assert "stream deadline did not stop read" (case expired of Left (R.InspectionFailure (R.LedgerRequestFailed _ (L.TransportError L.DeadlineExpired _ _) _) _ _) -> True; _ -> False)
    beforeChild <- historyReadCount proxy
    done <- newEmptyMVar
    child <- forkFinally (I.history I.Observe bound) (putMVar done)
    -- The delay applies only to the complete ledger SELECT, not admission.
    let waitForRead remaining = do
          count <- historyReadCount proxy
          if count > beforeChild then pure () else if remaining == (0 :: Int) then fail "Child never entered streamed SELECT" else threadDelay 10000 >> waitForRead (remaining - 1)
    waitForRead 100
    killThread child
    cancelled <- timeout 3000000 (takeMVar done)
    assert "stream cancellation converted to normal result" (case cancelled of Just (Left exception) -> isJust (fromException exception :: Maybe SomeAsyncException); _ -> False)
    setFault proxy Pass
    _ <- I.verify I.Observe bound (I.verifyOptions True) completePlan >>= right
    putStrLn "stream: framed truncation, trailing error, oversized row and late gap/identity/duplicate conflicts discard prefix and allow no writes"
  where
    filterMHistory records = do
      stages <- mapM (field "stage") records :: IO [Maybe T.Text]
      pure [record | (record, Just "history-read") <- zip records stages]

mutationCount :: FaultProxy -> IO Int
mutationCount proxy = do
  records <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") records :: IO [Maybe T.Text]
  pure (length [() | Just stage <- stages, stage /= "history-read", stage /= "read-only"])

-- The adoption consumer must also read a large interrupted/committed batch.
largeAdoption :: Server -> IO ()
largeAdoption server = withFaultProxy server $ \proxy -> do
  access <- provider
  ledger <- newLedgerId
  let label = "stream_adoption"
  config <- fixture server label (proxyEndpoint proxy) FirstUse
  bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
  audit <- right (L.auditContext "adoption reviewer" "large reviewed batch" (replicate 24 (T.replicate 2000 "x")))
  quiet <- right (L.attestQuiescence (configuredTargetKey config) audit)
  step <- right (sqlStep "create" "CREATE TABLE IF NOT EXISTS default.stream_adoption (id UInt8) ENGINE=Memory")
  migrations <- mapM (\n -> right (sqlMigration ("m-" <> T.pack (show n)) (step :| []))) [1 .. 360 :: Int]
  component <- right (migrationComponentFromList "app" Set.empty migrations)
  plan <- right (migrationPlan (component :| []))
  let views = NE.toList (inspectSchedule plan)
      names = ["source-" <> T.pack (show n) | n <- [1 .. 360 :: Int]]
  rows <- mapM (\name -> right (A.legacyRow name "2020-01-01T00:00:00Z" Nothing)) names
  mappings <- mapM (\(name, view) -> right (A.attestedMapping name "app" (migrationNameText (migrationIdName (migrationId view))) (migrationChecksumHex (migrationChecksum view)) ["reviewed immutable fixture"])) (zip names views)
  let build expected = case (rows, mappings) of
        (r : rs, m : ms) -> right (A.adoptionRequest (configuredTargetKey config) expected (Just (L.authorizeInitialization (configuredTargetKey config) ledger audit)) quiet audit "large-fixture" "immutable-source" (r :| rs) (m :| ms))
        _ -> fail "Missing large adoption fixture"
      context = Run.mutationContext bound access E.quietEvents E.redactedDiagnostics
      stop (E.RunEvent phase _ _ _ _ _ _) = when (phase == E.BeforeAdoptionComplete) (fail "interrupt before commit")
  observation <- I.status I.Observe config plan >>= right
  request <- build (L.ExpectAbsent (configuredTargetKey config))
  adoption <- right (A.planAdoption plan observation request)
  stopped <- A.applyAdoption (Run.mutationContext config access stop E.redactedDiagnostics) plan adoption
  assert "large adoption interruption lost" (case stopped of Left (R.RunFailure (R.CallbackFailed _) _ _) -> True; _ -> False)
  current <- I.status I.Observe bound plan >>= right
  position <- case current of R.InspectionReport (R.HistoryReport _ _ _ (Just value) _ events _ True) _ _ | length events == 362 -> pure value; _ -> fail "Large interrupted adoption incomplete"
  resumedRequest <- build (L.ExpectPosition position)
  resumed <- right (A.planAdoption plan current resumedRequest)
  _ <- A.resumeAdoption context plan resumed >>= right
  _ <- A.applyAdoption context plan adoption >>= right
  _ <- I.verify I.Observe bound (I.verifyOptions True) plan >>= right
  records <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") records :: IO [Maybe T.Text]
  sizes <- mapM (field "responseBytes") [record | (record, Just "history-read") <- zip records stages] :: IO [Int]
  assert "adoption fixture below old maximum" (maximum sizes > 16777216)
  assert "large adoption executed SQL/duplicated entries" (length (filter (== Just "adoption-entry") stages) == 360 && Just "application-sql" `notElem` stages)
  putStrLn ("stream: adoption wire bytes=" ++ show (maximum sizes) ++ "; 360 entries; interrupted resume and committed identical read are complete and submit no SQL")

historyReadCount :: FaultProxy -> IO Int
historyReadCount proxy = do
  records <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") records :: IO [Maybe T.Text]
  pure (length (filter (== Just "history-read") stages))
