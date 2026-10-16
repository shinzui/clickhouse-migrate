-- | Explicit audited recovery. No operation rewrites history or embedded SQL.
module ClickHouseMigrate.Repair
  ( RepairRequest,
    RecoveryEvidence,
    RepairRequestError (..),
    recoveryEvidence,
    resumeRequest,
    retryStepRequest,
    acceptStepRequest,
    finalizeRequest,
    repair,
  )
where

import ClickHouseMigrate.Definition qualified as Def
import ClickHouseMigrate.Event qualified as Event
import ClickHouseMigrate.Internal.Checksum qualified as Checksum
import ClickHouseMigrate.Internal.Execution
import ClickHouseMigrate.Internal.Identity (freshUuid)
import ClickHouseMigrate.Internal.LedgerCodec (encodeEvent)
import ClickHouseMigrate.Internal.LedgerStore qualified as Store
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Preflight (validateRecoveryCapacity, validateRecoveryEvent)
import ClickHouseMigrate.Internal.Projection (resolvedStep)
import ClickHouseMigrate.Internal.RepairTypes
import ClickHouseMigrate.Internal.Reporting qualified as Reporting
import ClickHouseMigrate.Internal.RuntimeTypes (MutationContext (..))
import ClickHouseMigrate.Internal.TargetTypes qualified as T
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as Target
import Data.List (findIndex)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

-- | External evidence is required even if no recorded query appears active.
-- Absence from system.processes is only a diagnostic; it cannot rule out a queued
-- or delayed request. Pending receipts, when available, are checked read-only.
recoveryEvidence :: Ledger.AuditContext -> Ledger.QuiescenceEvidence -> [Ledger.AppendReceipt] -> Either RepairRequestError RecoveryEvidence
recoveryEvidence audit quiet receipts
  | null (Ledger.auditReferences audit) = Left MissingRecoveryEvidence
  | length receipts > 32 = Left TooManyPendingReceipts
  | any (\(L.AppendReceipt target _ _ _ _ _) -> target /= Ledger.quiescenceTarget quiet) receipts = Left InvalidRecoveryTarget
  | otherwise = Right (RecoveryEvidence audit quiet receipts)

resumeRequest :: Ledger.LedgerPosition -> Ledger.AttemptId -> RecoveryEvidence -> Either RepairRequestError RepairRequest
resumeRequest position attempt evidence = validateReceipts position evidence >> Right (ResumeRequest position attempt evidence)

finalizeRequest :: Ledger.LedgerPosition -> Ledger.AttemptId -> RecoveryEvidence -> Either RepairRequestError RepairRequest
finalizeRequest position attempt evidence = validateReceipts position evidence >> Right (FinalizeRequest position attempt evidence)

retryStepRequest :: Ledger.LedgerPosition -> Ledger.AttemptId -> R.StepAttempt -> RecoveryEvidence -> Either RepairRequestError RepairRequest
retryStepRequest position attempt step evidence = validateReceipts position evidence >> validateStep step >> Right (RetryStepRequest position attempt step evidence)

acceptStepRequest :: Ledger.LedgerPosition -> Ledger.AttemptId -> R.StepAttempt -> RecoveryEvidence -> Either RepairRequestError RepairRequest
acceptStepRequest position attempt step evidence = validateReceipts position evidence >> validateStep step >> Right (AcceptStepRequest position attempt step evidence)

validateReceipts :: Ledger.LedgerPosition -> RecoveryEvidence -> Either RepairRequestError ()
validateReceipts (L.LedgerPosition ledger _ _) (RecoveryEvidence _ _ receipts)
  | any (\(L.AppendReceipt _ actual _ _ _ _) -> actual /= ledger) receipts = Left ForeignLedgerReceipt
  | otherwise = Right ()

validateStep :: R.StepAttempt -> Either RepairRequestError ()
validateStep (R.StepAttempt _ name _) = either (const (Left InvalidStepAttempt)) (const (Right ())) (Def.stepName name)

requestParts :: RepairRequest -> (Ledger.LedgerPosition, Ledger.AttemptId, RecoveryEvidence)
requestParts = \case
  ResumeRequest position attempt evidence -> (position, attempt, evidence)
  RetryStepRequest position attempt _ evidence -> (position, attempt, evidence)
  AcceptStepRequest position attempt _ evidence -> (position, attempt, evidence)
  FinalizeRequest position attempt evidence -> (position, attempt, evidence)

repair :: MutationContext -> Plan.MigrationPlan -> RepairRequest -> IO (Either R.RunFailure R.RunReport)
repair context@(MutationContext (T.TargetConfig target _ _ _ binding _ _) _ _ _) plan request =
  let (expected@(L.LedgerPosition ledger _ _), requested, RecoveryEvidence audit quiet receipts) = requestParts request
      prerequisite = case binding of
        T.FirstUse -> Left R.ExistingBindingRequired
        T.ExistingLedger actual | actual /= ledger -> Left (R.LedgerFailed L.LedgerIdentityMismatch)
        _ | Ledger.quiescenceTarget quiet /= target -> Left (R.RepairNotAllowed R.WrongQuiescenceTarget)
        _ -> Right ()
   in withRuntimeCheck prerequisite context audit Nothing (Just quiet) plan $ \runtime -> do
        projection <- runtimeProjection runtime
        unless (L.position projection == expected) (abort (R.StalePosition expected (Just (L.position projection))))
        (definition, current, checkpoints) <- case L.active projection of
          Just (L.ActiveMigration definition current checkpoints _) -> pure (definition, current, checkpoints)
          Nothing | isJust (L.adoption projection) -> abort (R.RepairNotAllowed R.AdoptionInProgress)
          _ -> abort (R.RepairNotAllowed R.NoActiveMigration)
        unless (Ledger.attemptIdText requested == current) (abort (R.AttemptMismatch requested (Just (L.AttemptId current))))
        mapM_ (checkReceipt projection) receipts
        let queries = Set.toAscList (Set.fromList ([T.QueryId query | event <- L.events projection, L.StartStep _ query <- [L.body event]] ++ [query | L.AppendReceipt _ _ _ _ _ query <- receipts]))
        active <- activeQueries runtime queries
        unless (null active) (abort (R.PriorQueriesActive active))
        migration <- case drop (L.ordinal definition) (orderedMigrations plan) of
          (actual, migration) : _ | actual == definition -> pure migration
          _ -> abort (R.LedgerFailed L.DefinitionMismatch)
        (action, selection, query) <- case request of
          ResumeRequest {} -> do
            unless (all (\step -> resolvedStep step || step == L.NeverStarted) checkpoints) (abort (R.RepairNotAllowed R.UncertainStepRemains))
            unless (any (== L.NeverStarted) checkpoints) (abort (R.RepairNotAllowed R.NoPendingSteps))
            pure (L.Resume, Nothing, Nothing)
          FinalizeRequest {} -> do
            unless (all resolvedStep checkpoints) (abort (R.RepairNotAllowed R.StepsNotResolved))
            pure (L.Finalize, Nothing, Nothing)
          RetryStepRequest _ _ step _ -> do
            (index, query) <- selectedStep projection definition checkpoints step
            pure (L.RetryStep index, Just index, Just query)
          AcceptStepRequest _ _ step _ -> do
            (index, query) <- selectedStep projection definition checkpoints step
            pure (L.AcceptStep index, Just index, Just query)
        next <- freshUuid
        bound <- contextAt definition selection
        let L.LedgerPosition _ number _ = L.position projection
            pending = [index | (index, checkpoint) <- zip [0 ..] checkpoints, checkpoint == L.NeverStarted]
            needed = case action of L.Resume -> 2 * toInteger (length pending) + 2; L.RetryStep _ -> 3; _ -> 2
        either abort pure (validateRecoveryCapacity number needed)
        authorization <- prepareEvent runtime projection (Just next) (L.AuthorizeRecovery (L.Recovery action expected current next quiet)) bound
        authorized <- preparedProjection R.RecoveryAuthorizationEvent projection authorization
        following <- case action of
          L.AcceptStep index -> do
            event <- prepareEvent runtime authorized (Just next) (L.AcceptCompletion index (L.Evidence L.OperatorAttestation (Ledger.auditReferences audit))) bound
            _ <- preparedProjection R.RecoveryAcceptanceEvent authorized event
            pure (Just event)
          L.Finalize -> do
            completion <- contextAt definition Nothing
            event <- prepareEvent runtime authorized (Just next) L.CompleteMigration completion
            _ <- preparedProjection R.RecoveryCompletionEvent authorized event
            pure (Just event)
          L.Resume -> checkExecutionMetadata runtime definition next pending True >> pure Nothing
          L.RetryStep index -> checkExecutionMetadata runtime definition next [index] False >> pure Nothing
        appendPreparedEvent runtime authorization
        emit runtime Event.RecoveryAuthorized (Just definition) selection query
        case (action, following) of
          (L.Resume, _) -> do
            mapM_ (\(index, (checkpoint, step)) -> when (checkpoint == L.NeverStarted) (executeStep runtime definition next index step)) (zip [0 ..] (zip checkpoints (NE.toList (Plan.migrationSteps migration))))
            finishMigration runtime definition next
          (L.RetryStep index, _) -> case drop index (NE.toList (Plan.migrationSteps migration)) of
            step : _ -> executeStep runtime definition next index step
            _ -> abort R.UnexpectedRuntimeFailure
          (L.AcceptStep index, Just event) -> do
            appendPreparedEvent runtime event
            emit runtime Event.StepAccepted (Just definition) (Just index) query
          (L.Finalize, Just event) -> do
            emit runtime Event.BeforeMigrationComplete (Just definition) Nothing Nothing
            appendPreparedEvent runtime event
            emit runtime Event.MigrationCompleted (Just definition) Nothing Nothing
          _ -> abort R.UnexpectedRuntimeFailure
  where
    checkReceipt projection (L.AppendReceipt receiptTarget ledger number identity digest _) = do
      let L.LedgerPosition actual _ _ = L.position projection
          matching = [event | event <- L.events projection, L.eventId event == identity || eventNumber event == number]
      unless (receiptTarget == target && ledger == actual) (abort (R.LedgerFailed L.LedgerIdentityMismatch))
      case matching of
        [] -> pure () -- Caller-established quiescence + fresh full guarded read.
        [event] | L.eventId event == identity && eventNumber event == number && Checksum.digestHex (Checksum.digest (encodeEvent event)) == digest -> pure ()
        _ -> abort (R.RepairNotAllowed R.ConflictingAppend)
    eventNumber (L.LedgerEvent number _ _ _ _ _ _ _ _ _) = number

-- SQL outcomes are not known yet. Bound every possible generated envelope using
-- maximal sequence digits, timestamp precision and safe numeric failure fields.
checkExecutionMetadata :: Runtime -> L.Definition -> Text -> [Int] -> Bool -> IO ()
checkExecutionMetadata runtime definition attempt indices completion = do
  projection <- runtimeProjection runtime
  let L.LedgerPosition ledger _ _ = L.position projection
      uuid = "00000000-0000-4000-8000-000000000000"
      query = "chm-" <> uuid
      check kind body context = either abort pure (validateRecoveryEvent kind (L.LedgerEvent maxBound uuid ledger (runtimeRunId runtime) (Just attempt) "2026-10-16T00:00:00.999999999999Z" (runtimeAudit runtime) "0.1.0.0" context body))
  mapM_
    ( \index -> do
        context <- contextAt definition (Just index)
        check R.RecoveryStepStartEvent (L.StartStep index query) context
        check R.RecoveryStepSuccessEvent (L.SucceedStep index query) context
        check R.RecoveryStepFailureEvent (L.FailStep index query (L.FailureEvidence "UnexpectedResponse" (Just 599) (Just maxBound))) context
    )
    indices
  when completion $ contextAt definition Nothing >>= check R.RecoveryCompletionEvent L.CompleteMigration

selectedStep :: L.Projection -> L.Definition -> [L.StepState] -> R.StepAttempt -> IO (Int, T.QueryId)
selectedStep projection definition checkpoints requested@(R.StepAttempt _ name query) = do
  index <- maybe (abort (R.StepAttemptMismatch requested)) pure (findIndex (\(L.StepDefinition actual _) -> actual == name) (L.steps definition))
  recorded <- case Reporting.at index checkpoints of
    Just (L.Started identity) -> pure identity
    Just (L.Failed identity _) -> pure identity
    _ -> abort (R.RepairNotAllowed R.SelectedStepIsResolved)
  unless (findIndex (not . resolvedStep) checkpoints == Just index && Target.queryIdText query == recorded && Reporting.stepAttempt definition index (Just recorded) (L.events projection) == Just requested) (abort (R.StepAttemptMismatch requested))
  pure (index, query)

activeQueries :: Runtime -> [T.QueryId] -> IO [T.QueryId]
activeQueries _ [] = pure []
activeQueries runtime queries = callStore $ do
  let sql = "SELECT query_id FROM system.processes WHERE query_id IN (" <> Text.intercalate "," ["'" <> Target.queryIdText query <> "'" | query <- queries] <> ")"
  rows <- Store.readRows (Just (runtimeGuard runtime)) (runtimeTransport runtime) (Encoding.encodeUtf8 sql)
  mapM
    ( \row -> do
        Store.keys ["query_id"] row
        value <- Store.member "query_id" row
        either (const (Store.abort (Store.LedgerProblem L.InvalidEvent))) pure (Target.queryId value)
    )
    rows
