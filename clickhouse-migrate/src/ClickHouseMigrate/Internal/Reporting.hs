-- | Convert validated storage into safe immutable observations, without SQL.
module ClickHouseMigrate.Internal.Reporting where

import ClickHouseMigrate.Internal.ExclusiveTypes (AccessDescription)
import ClickHouseMigrate.Internal.LedgerCodec (definitions)
import ClickHouseMigrate.Internal.LedgerStore qualified as Store
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.TargetTypes qualified as T
import ClickHouseMigrate.Internal.Transport qualified as Transport
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target (ServerIdentity, TargetKey)

summaryDefinition :: L.Definition -> R.DefinitionSummary
summaryDefinition (L.Definition ordinal componentIndex component dependencies migration checksum steps) =
  R.DefinitionSummary ordinal componentIndex component dependencies migration checksum [(name, digest) | L.StepDefinition name digest <- steps]

emptyHistory :: TargetKey -> R.InspectionAccess -> R.HistoryReport
emptyHistory target access = R.HistoryReport target Nothing R.LedgerUnknown Nothing access [] [] False

observationReport :: TargetKey -> Maybe ServerIdentity -> R.InspectionAccess -> Store.Observation -> R.HistoryReport
observationReport target server access = \case
  Store.Missing -> R.HistoryReport target server R.LedgerMissing Nothing access [] [] False
  Store.EmptyNamespace -> R.HistoryReport target server R.LedgerUninitialized Nothing access [] [] False
  Store.History projection -> fromProjection server access projection

fromProjection :: Maybe ServerIdentity -> R.InspectionAccess -> L.Projection -> R.HistoryReport
fromProjection server access projection =
  let L.Projection position@(L.LedgerPosition ledger _ _) target completed active adoption events = projection
      complete (L.RecordedMigration definition state checkpoints) =
        migrationSummary
          events
          definition
          (case state of L.Applied -> R.Applied; L.Adopted -> R.Adopted)
          (latestAttempt definition events)
          checkpoints
      running = case active of
        Nothing -> []
        Just (L.ActiveMigration definition attempt checkpoints _) ->
          [migrationSummary events definition (if any failed checkpoints then R.Failed else R.InProgress) (Just (L.AttemptId attempt)) checkpoints]
      adopting = case adoption of
        Nothing -> []
        Just (L.ActiveAdoption _ entries) -> [migrationSummary events definition R.InProgress Nothing checkpoints | L.RecordedMigration definition _ checkpoints <- entries]
   in R.HistoryReport
        target
        server
        (R.LedgerInitializedAt ledger)
        (Just position)
        access
        (map eventReport events)
        (map complete completed ++ running ++ adopting)
        (isJust active || isJust adoption)
  where
    failed (L.Failed _ _) = True; failed _ = False

latestAttempt :: L.Definition -> [L.LedgerEvent] -> Maybe L.AttemptId
latestAttempt definition events = case [L.AttemptId attempt | event <- events, sameMigration definition event, Just attempt <- [L.attemptId event]] of
  [] -> Nothing
  values -> Just (last values)

sameMigration :: L.Definition -> L.LedgerEvent -> Bool
sameMigration (L.Definition _ _ component _ migration _ _) event = case L.context event of
  Just (L.EventContext c m _ _) -> c == component && m == migration
  _ -> False

stepAttempt :: L.Definition -> Int -> Maybe Text -> [L.LedgerEvent] -> Maybe R.StepAttempt
stepAttempt definition index expected events = do
  event <- case [event | event <- reverse events, sameMigration definition event, L.StartStep i query <- [L.body event], i == index, maybe True (== query) expected] of
    value : _ -> Just value
    _ -> Nothing
  attempt <- L.AttemptId <$> L.attemptId event
  case L.body event of
    L.StartStep _ query -> case drop index (L.steps definition) of L.StepDefinition name _ : _ -> Just (R.StepAttempt attempt name (T.QueryId query)); _ -> Nothing
    _ -> Nothing

migrationSummary :: [L.LedgerEvent] -> L.Definition -> R.MigrationStatus -> Maybe L.AttemptId -> [L.StepState] -> R.MigrationSummary
migrationSummary events definition state attempt checkpoints =
  R.MigrationSummary
    (summaryDefinition definition)
    state
    attempt
    [ let (status, query, evidence) = case checkpoint of
            L.NeverStarted -> (R.StepPending, Nothing, Nothing)
            L.Started value -> (R.StepUncertain, Just value, Nothing)
            L.Succeeded value -> (R.StepObservedSuccess, Just value, Nothing)
            L.Failed value _ -> (R.StepObservedFailure, Just value, Nothing)
            L.Accepted (L.Evidence level references) -> (R.StepAccepted, Nothing, Just (R.EvidenceSummary level references))
       in R.StepSummary name checksum status (if status == R.StepPending then Nothing else stepAttempt definition index query events) evidence
    | (index, (L.StepDefinition name checksum, checkpoint)) <- zip [0 ..] (zip (L.steps definition) checkpoints)
    ]

pendingSummary :: L.Definition -> R.MigrationSummary
pendingSummary definition =
  R.MigrationSummary
    (summaryDefinition definition)
    R.Pending
    Nothing
    [R.StepSummary name checksum R.StepPending Nothing Nothing | L.StepDefinition name checksum <- L.steps definition]

inspectHistory :: Plan.MigrationPlan -> R.HistoryReport -> R.InspectionReport
inspectHistory plan history@(R.HistoryReport _ _ _ _ _ events recorded unresolved) =
  let supplied = definitions plan
      actual = [definition | R.MigrationSummary definition _ _ _ <- recorded]
      expected = map summaryDefinition supplied
      changes = [R.DefinitionChanged index (at index expected) (Just definition) | (index, definition) <- zip [0 ..] actual, at index expected /= Just definition]
      attempts = [R.UnresolvedAttempt attempt | R.MigrationSummary _ state (Just attempt) _ <- recorded, state `elem` [R.InProgress, R.Failed]]
      batches = if unresolved && null attempts then case reverse [batch | R.HistoryEvent _ _ _ _ _ _ _ _ _ (R.AdoptionBeginning batch) <- events] of batch : _ -> [R.IncompleteAdoption batch]; _ -> [] else []
      current =
        [ case at index recorded of
            Just value@(R.MigrationSummary observed _ _ _) | observed == definition -> value
            Just (R.MigrationSummary _ _ attempt steps) -> R.MigrationSummary definition R.Invalid attempt steps
            Nothing -> pendingSummary source
        | (index, (definition, source)) <- zip [0 ..] (zip expected supplied)
        ]
   in R.InspectionReport history current (changes ++ attempts ++ batches)

compatibilityError :: R.InspectionReport -> Maybe R.RunError
compatibilityError (R.InspectionReport _ _ issues)
  | any changed issues = Just (R.IncompatibleHistory issues)
  | not (null issues) = Just (R.LedgerFailed L.UnresolvedHistory)
  | otherwise = Nothing
  where
    changed (R.DefinitionChanged _ _ _) = True; changed _ = False

isCurrent :: R.InspectionReport -> Bool
isCurrent (R.InspectionReport _ migrations issues) = null issues && all (\(R.MigrationSummary _ state _ _) -> state `elem` [R.Applied, R.Adopted]) migrations

runHistory :: R.RunReport -> R.HistoryReport
runHistory (R.RunReport _ _ _ _ history _ _ _) = history

runPosition :: R.RunReport -> Maybe L.LedgerPosition
runPosition report = case runHistory report of R.HistoryReport _ _ _ position _ _ _ _ -> position

updateRun :: Plan.MigrationPlan -> R.HistoryReport -> R.RunReport -> R.RunReport
updateRun plan history (R.RunReport identity target access acquired _ _ observations initialized) = let R.InspectionReport _ migrations _ = inspectHistory plan history in R.RunReport identity target access acquired history migrations observations initialized

recordSql :: R.SqlObservation -> R.RunReport -> R.RunReport
recordSql value report@(R.RunReport _ _ _ _ _ _ observations _) = report {R.observations = observations ++ [value]}

initialRun :: Text -> TargetKey -> AccessDescription -> Plan.MigrationPlan -> R.RunReport
initialRun run target access plan =
  let history = emptyHistory target (R.GuardedObservation access)
      R.InspectionReport _ migrations _ = inspectHistory plan history
   in R.RunReport run target access False history migrations [] Nothing

historyPosition :: R.HistoryReport -> Maybe L.LedgerPosition
historyPosition (R.HistoryReport _ _ _ position _ _ _ _) = position

stepReference :: L.Definition -> Int -> Maybe R.StepReference
stepReference (L.Definition _ _ component _ migration checksum steps) index = case drop index steps of
  L.StepDefinition step digest : _ | index >= 0 -> Just (R.StepReference component migration step checksum digest)
  _ -> Nothing

eventReport :: L.LedgerEvent -> R.HistoryEvent
eventReport (L.LedgerEvent number event ledger run attempt time audit runner context body) =
  R.HistoryEvent
    number
    event
    ledger
    run
    (L.AttemptId <$> attempt)
    time
    audit
    runner
    (fmap (\(L.EventContext component migration checksum step) -> (component, migration, checksum, step)) context)
    (bodyReport body)

bodyReport :: L.EventBody -> R.HistoryBody
bodyReport = \case
  L.Initialize target -> R.LedgerInitialized target
  L.StartMigration definition -> R.MigrationDefinition (summaryDefinition definition)
  L.StartStep index query -> R.StepIntent index (T.QueryId query)
  L.SucceedStep index query -> R.StepCompletion index (T.QueryId query)
  L.FailStep index query (L.FailureEvidence code status server) -> R.ExecutionFailure index (T.QueryId query) (R.FailureSummary code status server)
  L.CompleteMigration -> R.MigrationCompletion
  L.AuthorizeRecovery (L.Recovery action position previous next (L.QuiescenceEvidence target audit)) -> R.RecoveryAuthorization (recoveryAction action) position (L.AttemptId previous) (L.AttemptId next) target audit
  L.AcceptCompletion index (L.Evidence level references) -> R.AcceptedCompletion index (R.EvidenceSummary level references)
  L.StartAdoption (L.AdoptionBatch source snapshot mapping definitionHash count) -> R.AdoptionBeginning (R.AdoptionSummary source snapshot mapping definitionHash count)
  L.AdoptEntry definition (L.Evidence level references) -> R.AdoptedDefinition (summaryDefinition definition) (R.EvidenceSummary level references)
  L.CompleteAdoption digest -> R.AdoptionCompletion digest

recoveryAction :: L.RecoveryAction -> R.RecoveryAction
recoveryAction = \case L.Resume -> R.Resume; L.RetryStep index -> R.RetryStep index; L.AcceptStep index -> R.AcceptStep index; L.Finalize -> R.Finalize

outcomeError :: Transport.TransportOutcome -> Maybe L.AppendReceipt -> R.RunError
outcomeError outcome receipt = case outcome of
  Transport.NotSubmitted failure -> R.LedgerRequestFailed Ledger.PositiveNonSubmission failure receipt
  Transport.ObservedServerFailure failure -> R.LedgerRequestFailed Ledger.ObservedFailure failure receipt
  Transport.SubmissionUncertain failure -> R.LedgerRequestFailed Ledger.UncertainSubmission failure receipt
  _ -> R.UnexpectedRuntimeFailure

storeError :: Store.StoreError -> R.RunError
storeError = \case
  Store.LedgerProblem failure -> R.LedgerFailed failure
  Store.AccessProblem failure -> R.AccessFailed failure
  Store.RequestProblem outcome receipt -> outcomeError outcome receipt
  Store.InitializationProblem ledger stage query outcome -> case outcomeError outcome Nothing of
    R.LedgerRequestFailed evidence failure _ -> R.InitializationFailed (ledgerIdText ledger) stage query evidence failure
    _ -> R.UnexpectedRuntimeFailure
  where
    ledgerIdText (T.LedgerId value) = value

at :: Int -> [a] -> Maybe a
at index values
  | index < 0 = Nothing
  | otherwise = case drop index values of value : _ -> Just value; _ -> Nothing
