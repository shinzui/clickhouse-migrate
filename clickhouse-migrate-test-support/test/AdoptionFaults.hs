module AdoptionFaults (adoptionFaultCases) where

import ClickHouseMigrate
import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.ExclusiveAccess (hostLocalExclusiveAccess)
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Concurrent (threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeAsyncException, finally, throwIO, try)
import Control.Monad (forM_, void, when)
import Crypto.Hash.SHA256 qualified as SHA
import Data.Aeson (Value)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Text.IO qualified as TextIO
import Numeric (showHex)
import RunnerIntegration (assert, field, fixture, fixtureWithLimits, fromJson, planFor, provider, right, scalar)
import System.FilePath ((</>))
import System.Timeout (timeout)

historyOf :: R.InspectionReport -> R.HistoryReport
historyOf (R.InspectionReport snapshot _ _) = snapshot

positionOf :: R.InspectionReport -> IO L.LedgerPosition
positionOf (R.InspectionReport (R.HistoryReport _ _ _ (Just position) _ _ _ _) _ _) = pure position
positionOf _ = fail "Missing adoption ledger position"

requestFor :: MigrationPlan -> TargetKey -> LedgerId -> L.AuditContext -> L.QuiescenceEvidence -> L.ExpectedLedgerState -> T.Text -> IO A.AdoptionRequest
requestFor plan key ledger audit quiet expected source = do
  row <- right (A.legacyRow "001.sql" "2020-01-01T00:00:00Z" Nothing)
  let first = NE.head (componentMigrations (NE.head (inspectPlan plan)))
  mapped <- right (A.attestedMapping "001.sql" "app" "one" (migrationChecksumHex (migrationChecksum first)) ["fixture:reviewed-complete-two-statement-mapping"])
  right (A.adoptionRequest key expected (Just (L.authorizeInitialization key ledger audit)) quiet audit source "fixture:immutable-legacy-snapshot" (row :| []) (mapped :| []))

prepare :: Server -> T.Text -> IO ()
prepare server label = do
  void (queryServer server ("CREATE TABLE default." <> label <> " (id UInt8, secret String) ENGINE=MergeTree ORDER BY id"))
  void (queryServer server ("INSERT INTO default." <> label <> " VALUES (7,'SQL_SECRET_MARKER')"))

counts :: FaultProxy -> IO (Int, Int)
counts proxy = do
  rows <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") rows :: IO [Maybe T.Text]
  pure (length (filter (== Just "application-sql") stages), length (filter (== Just "adoption-entry") stages))

save :: Server -> T.Text -> FaultProxy -> R.InspectionReport -> IO ()
save server label proxy snapshot = do
  requests <- proxyEvents proxy
  TextIO.writeFile (serverLogDirectory server </> T.unpack label ++ ".trace") (T.pack (show requests) <> "\n" <> T.pack (show snapshot))

adoptionFaultCases :: Server -> IO ()
adoptionFaultCases server = do
  access <- provider
  audit <- right (L.auditContext "adoption fault reviewer" "controlled complete effects and drained predecessor requests" ["owned fixture; parent excludes every outside administrator"])
  forM_ (zip [0 :: Int ..] [(stage, mode) | stage <- [Initialization, AdoptionStart, AdoptionEntry, AdoptionCompletion], mode <- [DropResponse, LateError]]) $ \(index, (stage, mode)) -> withFaultProxy server $ \proxy -> do
    let label = "adoption_append_" <> T.pack (show index)
    prepare server label
    plan <- planFor label 7
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    quiet <- right (L.attestQuiescence key audit)
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    observed <- I.status I.Observe config plan >>= right
    request <- requestFor plan key ledger audit quiet (L.ExpectAbsent key) "synthetic-legacy"
    adoption <- right (A.planAdoption plan observed request)
    setLedgerFault proxy stage mode
    failed <- A.applyAdoption (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) plan adoption
    receipt <- case failed of
      Left (R.RunFailure (R.LedgerRequestFailed evidence _ (Just receipt)) _ []) | evidence == (if mode == LateError then L.ObservedFailure else L.UncertainSubmission) -> pure receipt
      other -> fail ("Wrong adoption append failure " ++ show other)
    assert "Adoption append error leaked SQL" (not ("SQL_SECRET_MARKER" `T.isInfixOf` T.pack (show failed)))
    setFault proxy Pass
    fresh <- I.status (I.Guarded access) bound plan >>= right
    save server label proxy fresh
    let expectedEvents = case stage of Initialization -> 1; AdoptionStart -> 2; AdoptionEntry -> 3; _ -> 4
    assert "Failed adoption append did not commit exactly once" (case historyOf fresh of R.HistoryReport _ _ _ _ _ events _ _ -> length events == expectedEvents)
    _ <- L.reconcileAppend bound access receipt >>= \result -> case L.result result of Right (L.PresentIdentical, _) -> pure (); _ -> fail "Exact failed adoption append not reconcilable"
    if stage == AdoptionCompletion
      then do
        _ <- A.applyAdoption (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan adoption >>= right
        pure ()
      else do
        stale <- A.resumeAdoption (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan adoption
        assert "Original absence request resumed after state moved" (case stale of Left (R.RunFailure (R.AdoptionRejected A.AdoptionExpectedStateMismatch) _ _) -> True; _ -> False)
        when (stage /= Initialization) $ do
          blocked <- Run.up (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit Nothing) plan
          assert "Ordinary up consumed incomplete adoption" (case blocked of Left (R.RunFailure (R.LedgerFailed L.UnresolvedHistory) _ _) -> True; _ -> False)
        current <- positionOf fresh
        changed <- requestFor plan key ledger audit quiet (L.ExpectPosition current) "changed-source"
        when (stage /= Initialization) $ do
          assert "Changed interrupted batch planned" (case A.planAdoption plan fresh changed of Left A.AdoptionBatchConflict -> True; _ -> False)
        next <- requestFor plan key ledger audit quiet (L.ExpectPosition current) "synthetic-legacy" >>= right . A.planAdoption plan fresh
        _ <- (if stage == Initialization then A.applyAdoption else A.resumeAdoption) (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan next >>= right
        pure ()
    _ <- I.verify I.Observe bound (I.verifyOptions True) plan >>= right
    assert "Adoption recovery submitted SQL or duplicated an entry" . (== (0, 1)) =<< counts proxy
    assert "Adoption recovery replayed predecessor INSERT" . (== 1) =<< scalar server ("SELECT toUInt32(count()) AS value FROM default." <> label)
    putStrLn ("adoption append " ++ show stage ++ "/" ++ show mode ++ ": exact reconciliation; fresh explicit continuation; no SQL or duplicate entry")
  forM_ (zip [0 :: Int ..] [E.BeforeAdoptionStart, E.AdoptionStarted, E.BeforeAdoptionEntry, E.AdoptionEntryRecorded, E.BeforeAdoptionComplete, E.AdoptionCompleted]) $ \(index, phase) -> withFaultProxy server $ \proxy -> do
    let label = "adoption_callback_" <> T.pack (show index)
    prepare server label
    plan <- planFor label 7
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    quiet <- right (L.attestQuiescence key audit)
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    observed <- I.status I.Observe config plan >>= right
    request <- requestFor plan key ledger audit quiet (L.ExpectAbsent key) "synthetic-legacy"
    adoption <- right (A.planAdoption plan observed request)
    let sink (E.RunEvent actual _ _ _ _ _ _) = when (actual == phase) (fail "adoption observer SQL_SECRET_MARKER")
    failed <- A.applyAdoption (Run.mutationContext config access sink E.redactedDiagnostics) plan adoption
    assert "Adoption observer failure hidden" (case failed of Left (R.RunFailure (R.CallbackFailed _) _ []) -> True; _ -> False)
    fresh <- I.status (I.Guarded access) bound plan >>= right
    save server label proxy fresh
    let expectedEvents = case phase of E.BeforeAdoptionStart -> 1; E.AdoptionStarted -> 2; E.BeforeAdoptionEntry -> 2; E.AdoptionEntryRecorded -> 3; E.BeforeAdoptionComplete -> 3; _ -> 4
    assert "Adoption callback lost acknowledged state" (case failed of Left (R.RunFailure _ (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ _ _ events _ _) _ _ _) _) -> length events == expectedEvents; _ -> False)
    if phase == E.AdoptionCompleted
      then do _ <- A.applyAdoption (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan adoption >>= right; pure ()
      else do
        current <- positionOf fresh
        next <- requestFor plan key ledger audit quiet (L.ExpectPosition current) "synthetic-legacy" >>= right . A.planAdoption plan fresh
        _ <- (if phase == E.BeforeAdoptionStart then A.applyAdoption else A.resumeAdoption) (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan next >>= right
        pure ()
    assert "Adoption callback recovery submitted SQL/duplicate entry" . (== (0, 1)) =<< counts proxy
    putStrLn ("adoption observer " ++ show phase ++ ": last acknowledgement retained; explicit continuation; zero SQL")
  -- Resume must refuse a nonexistent batch before even bootstrap DDL.
  withFaultProxy server $ \proxy -> do
    let label = "adoption_absent_resume"
    plan <- planFor label 7
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    quiet <- right (L.attestQuiescence key audit)
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    observed <- I.status I.Observe config plan >>= right
    request <- requestFor plan key ledger audit quiet (L.ExpectAbsent key) "synthetic-legacy"
    adoption <- right (A.planAdoption plan observed request)
    refused <- A.resumeAdoption (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) plan adoption
    assert "Resume initialized a missing batch" (case refused of Left (R.RunFailure (R.AdoptionRejected A.AdoptionBatchConflict) _ _) -> True; _ -> False)
    present <- scalar server "SELECT toUInt32(count()) AS value FROM system.databases WHERE name='adoption_absent_resume_history'"
    assert "Invalid adoption resume created objects" (present == 0)
    putStrLn "adoption absent resume: complete fresh validation rejects before bootstrap mutation"
  -- Real predecessor checksum fixture: read its retained algorithm/digest, rather
  -- than relabeling a current-file hash as historical evidence.
  withFaultProxy server $ \proxy -> do
    let label = "adoption_verified"
    prepare server label
    plan <- planFor label 7
    let migration = NE.head (componentMigrations (NE.head (inspectPlan plan)))
        historical = mconcat [stepSql step <> ";\n" | step <- NE.toList (migrationSteps migration)]
        storedHash = T.pack (concatMap (\byte -> let value = showHex byte "" in replicate (2 - length value) '0' ++ value) (BS.unpack (SHA.hash historical)))
    void (queryServer server "CREATE TABLE default.predecessor_checksums (algorithm String, checksum String) ENGINE=Memory")
    void (queryServer server ("INSERT INTO default.predecessor_checksums VALUES ('sha256','" <> storedHash <> "')"))
    rows <- queryServer server "SELECT algorithm,checksum FROM default.predecessor_checksums" >>= fromJson :: IO [Value]
    (algorithm, retained) <- case rows of [row] -> (,) <$> field "algorithm" row <*> field "checksum" row; _ -> fail "Missing actual predecessor checksum row"
    checksum <- right (A.sourceChecksum algorithm retained)
    row <- right (A.legacyRow "001.sql" "2020-01-01T00:00:00Z" (Just checksum))
    mapping <- right (A.verifiedMapping "001.sql" "app" "one" (migrationChecksumHex (migrationChecksum migration)) historical ["fixture:retained-predecessor-checksum-row"])
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    quiet <- right (L.attestQuiescence key audit)
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    observed <- I.status I.Observe config plan >>= right
    request <- right (A.adoptionRequest key (L.ExpectAbsent key) (Just (L.authorizeInitialization key ledger audit)) quiet audit "predecessor-with-sha256" "fixture:immutable-historical-source-and-checksum-row" (row :| []) (mapping :| []))
    adoption <- right (A.planAdoption plan observed request)
    result <- A.applyAdoption (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) plan adoption >>= right
    assert "Stored checksum evidence downgraded/conflated" (case result of R.RunReport _ _ _ _ _ [R.MigrationSummary _ R.Adopted _ steps] [] _ -> all (\case R.StepSummary _ _ R.StepAccepted _ (Just (R.EvidenceSummary L.PredecessorChecksum _)) -> True; _ -> False) steps; _ -> False)
    assert "Checksum adoption submitted application SQL" . (== (0, 1)) =<< counts proxy
    putStrLn "adoption historical checksum: actual predecessor algorithm/digest row and matching historical bytes; evidence retained separately from observed execution"
  -- Async observer cancellation escapes after cleanup; the durable entry remains.
  withFaultProxy server $ \proxy -> do
    let label = "adoption_async"
    prepare server label
    plan <- planFor label 7
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    quiet <- right (L.attestQuiescence key audit)
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    observed <- I.status I.Observe config plan >>= right
    request <- requestFor plan key ledger audit quiet (L.ExpectAbsent key) "synthetic-legacy"
    adoption <- right (A.planAdoption plan observed request)
    let sink (E.RunEvent phase _ _ _ _ _ _) = when (phase == E.AdoptionEntryRecorded) (throwIO ThreadKilled)
    cancelled <- try @SomeAsyncException (A.applyAdoption (Run.mutationContext config access sink E.redactedDiagnostics) plan adoption)
    assert "Adoption cancellation became synchronous result" (case cancelled of Left _ -> True; _ -> False)
    fresh <- I.status I.Observe bound plan >>= right
    assert "Cancelled adoption lost its entry" (case historyOf fresh of R.HistoryReport _ _ _ _ _ events _ True -> length events == 3; _ -> False)
    current <- positionOf fresh
    next <- requestFor plan key ledger audit quiet (L.ExpectPosition current) "synthetic-legacy" >>= right . A.planAdoption plan fresh
    _ <- A.resumeAdoption (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan next >>= right
    cleanup <- right (Access.externallySerialized "owned-parent-release-fault" "all requests drained before next job" 1000000 (const (pure ())) (const (fail "release private message")) (const (pure True)))
    final <- A.applyAdoption (Run.mutationContext bound cleanup E.quietEvents E.redactedDiagnostics) plan adoption
    assert "Read-only committed adoption hid cleanup failure/progress" (case final of Left (R.RunFailure R.CleanupFailed (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ _ _ events _ False) _ _ _) secondary) -> length events == 4 && not (null secondary); _ -> False)
    assert "Cancelled/read-only adoption submitted SQL or duplicate entry" . (== (0, 1)) =<< counts proxy
    putStrLn "adoption async observer: rethrown after cleanup, committed entry preserved; fresh resume; read-only reapply retains cleanup-only failure"
  delayedEntry server access audit

-- An empty observation while a proxy-held ledger request is not yet forwarded
-- must not admit a mutating successor. Only the fixture parent can release and
-- prove the complete controlled request drain.
delayedEntry :: Server -> Access.ExclusiveAccess -> L.AuditContext -> IO ()
delayedEntry server parentJob audit = withFaultProxy server $ \proxy -> do
  let label = "adoption_late_entry"
      root = serverLogDirectory server </> "adoption-late-locks"
  prepare server label
  plan <- planFor label 7
  ledger <- newLedgerId
  key <- right (targetKey ("runner-tests/" <> label))
  quiet <- right (L.attestQuiescence key audit)
  short <- right (httpLimits 1000000 1048576)
  config <- fixtureWithLimits short server label (proxyEndpoint proxy) FirstUse
  bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
  local <- hostLocalExclusiveAccess root 1000000 Nothing >>= right
  observed <- I.status I.Observe config plan >>= right
  request <- requestFor plan key ledger audit quiet (L.ExpectAbsent key) "synthetic-legacy"
  adoption <- right (A.planAdoption plan observed request)
  setLedgerFault proxy AdoptionEntry HoldBeforeForward
  ( do
      stopped <- A.applyAdoption (Run.mutationContext config local E.quietEvents E.redactedDiagnostics) plan adoption
      receipt <- case stopped of Left (R.RunFailure (R.LedgerRequestFailed L.UncertainSubmission _ (Just receipt)) _ []) -> pure receipt; _ -> fail "Held adoption entry did not become uncertain"
      empty <- I.status I.Observe bound plan >>= right
      assert "Held entry arrived before explicit release" (case historyOf empty of R.HistoryReport _ _ _ _ _ events _ True -> length events == 2; _ -> False)
      reconciled <- L.reconcileAppend bound parentJob receipt
      assert "Held entry not observed as absent" (case L.result reconciled of Right (L.NotObserved, _) -> True; _ -> False)
      active <- scalar server ("SELECT toUInt32(count()) AS value FROM system.processes WHERE query_id='" <> queryIdText (L.appendQueryId receipt) <> "'")
      assert "Unforwarded request unexpectedly active on server" (active == 0)
      current <- positionOf empty
      premature <- requestFor plan key ledger audit quiet (L.ExpectPosition current) "synthetic-legacy" >>= right . A.planAdoption plan empty
      -- Negative attempt: neither the old assertion nor absent rows establish new
      -- quiescence. The real host-local marker must refuse entry after OS unlock.
      blocked <- hostLocalExclusiveAccess root 1000000 Nothing >>= right
      refused <- A.resumeAdoption (Run.mutationContext bound blocked E.quietEvents E.redactedDiagnostics) plan premature
      assert "NotObserved admitted premature adoption resume" (case refused of Left (R.RunFailure (R.AccessFailed Access.PredecessorQuiescenceRequired) _ _) -> True; _ -> False)
      assert "Premature successor submitted a duplicate entry" . (== (0, 1)) =<< counts proxy
      releaseFault proxy
      let wait message action = do
            done <- timeout 8000000 (let loop = action >>= \ready -> if ready then pure () else threadDelay 20000 >> loop in loop)
            assert message (done == Just ())
      wait "Late entry did not arrive" $ do
        snapshot <- I.status I.Observe bound plan >>= right
        pure (case historyOf snapshot of R.HistoryReport _ _ _ _ _ events _ True -> length events == 3; _ -> False)
      wait "Controlled original proxy request failed to drain" ((== 0) <$> proxyConnections proxy)
      setFault proxy Pass
      evidence <- right (L.auditContext "post-drain operator" "original client ended; parent released and drained every controlled request" ["owned proxy has zero open connections; exact late event present after synchronous response"])
      established <- right (L.attestQuiescence key evidence)
      access <- hostLocalExclusiveAccess root 1000000 (Just established) >>= right
      fresh <- I.status I.Observe bound plan >>= right
      save server label proxy fresh
      position <- positionOf fresh
      next <- requestFor plan key ledger evidence established (L.ExpectPosition position) "synthetic-legacy" >>= right . A.planAdoption plan fresh
      _ <- A.resumeAdoption (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan next >>= right
      _ <- I.verify I.Observe bound (I.verifyOptions True) plan >>= right
      assert "Late entry recovery replayed SQL or entry" . (== (0, 1)) =<< counts proxy
      putStrLn "adoption late entry: absent history/process row and NotObserved precede one commit; host marker blocks successor; explicit complete drain permits resume without duplicate or premature completion"
    )
    `finally` releaseFault proxy
