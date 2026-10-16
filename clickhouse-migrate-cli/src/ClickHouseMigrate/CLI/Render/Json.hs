-- | Explicit schemaVersion 1 encoding. No domain Generic/Show-based wire format.
module ClickHouseMigrate.CLI.Render.Json (renderJson, resultValue, commandErrorCode, runErrorCode) where

import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.CLI.Types
import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as JSON
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

renderJson :: CommandResult -> ByteString
renderJson = Lazy.toStrict . JSON.encode . resultValue

nullable :: (a -> Value) -> Maybe a -> Value
nullable encode = maybe Null encode

resultValue :: CommandResult -> Value
resultValue (CommandResult command result) =
  object
    [ "schemaVersion" .= (1 :: Int),
      "command" .= command,
      "status" .= (case result of Left _ -> "error" :: Text; Right _ -> "ok"),
      "result" .= either (const Null) reportValue result,
      "error" .= either failureValue (const Null) result
    ]

reportValue :: CommandReport -> Value
reportValue = \case
  PlanReport components -> object ["kind" .= ("plan" :: Text), "checksumFormat" .= Plan.checksumFormatName Plan.ChecksumV1, "completionPolicy" .= Encoding.decodeUtf8 Plan.completionPolicy, "components" .= componentsValue 0 0 components]
  StatusReport report -> object ["kind" .= ("status" :: Text), "report" .= inspectionValue report]
  HistoryReport report -> object ["kind" .= ("history" :: Text), "report" .= historyValue report]
  VerificationReport (R.VerificationReport report current) -> object ["kind" .= ("verification" :: Text), "compatible" .= True, "current" .= current, "report" .= inspectionValue report]
  RunReport report -> object ["kind" .= ("run" :: Text), "report" .= runValue report]
  AdoptionPlanReport observation summary entries -> object ["kind" .= ("adoption-plan" :: Text), "observation" .= historyValue observation, "batch" .= adoptionValue summary, "entries" .= [object ["definition" .= definitionValue definition, "evidence" .= evidenceValue evidence] | (definition, evidence) <- entries]]

componentsValue :: Int -> Int -> [PlanComponent] -> [Value]
componentsValue _ _ [] = []
componentsValue componentIndex ordinal (PlanComponent name dependencies migrations : rest) =
  object ["index" .= componentIndex, "name" .= name, "dependencies" .= dependencies, "migrations" .= [object ["ordinal" .= (ordinal + index), "name" .= migration, "description" .= description, "checksum" .= checksum, "steps" .= [object ["index" .= stepIndex, "name" .= step, "checksum" .= digest] | (stepIndex, PlanStep step digest) <- zip [0 :: Int ..] steps]] | (index, PlanMigration migration description checksum steps) <- zip [0 ..] migrations]] : componentsValue (componentIndex + 1) (ordinal + length migrations) rest

definitionValue :: R.DefinitionSummary -> Value
definitionValue (R.DefinitionSummary ordinal componentIndex component dependencies migration checksum steps) = object ["ordinal" .= ordinal, "componentIndex" .= componentIndex, "component" .= component, "dependencies" .= dependencies, "migration" .= migration, "checksum" .= checksum, "steps" .= [object ["name" .= name, "checksum" .= digest] | (name, digest) <- steps]]

stepReferenceValue :: R.StepReference -> Value
stepReferenceValue (R.StepReference component migration step migrationChecksum stepChecksum) = object ["component" .= component, "migration" .= migration, "step" .= step, "migrationChecksum" .= migrationChecksum, "stepChecksum" .= stepChecksum]

evidenceValue :: R.EvidenceSummary -> Value
evidenceValue (R.EvidenceSummary level references) = object ["level" .= (case level of L.OperatorAttestation -> "operator-attestation" :: Text; L.PredecessorChecksum -> "predecessor-checksum"), "references" .= references]

stepAttemptValue :: R.StepAttempt -> Value
stepAttemptValue (R.StepAttempt owner name query) = object ["ownerAttempt" .= L.attemptIdText owner, "step" .= name, "queryId" .= T.queryIdText query]

migrationState :: R.MigrationStatus -> Text
migrationState = \case R.Pending -> "pending"; R.InProgress -> "in-progress"; R.Failed -> "failed"; R.Applied -> "applied"; R.Adopted -> "adopted"; R.Invalid -> "invalid"

stepState :: R.StepStatus -> Text
stepState = \case R.StepPending -> "pending"; R.StepUncertain -> "uncertain"; R.StepObservedSuccess -> "observed-success"; R.StepObservedFailure -> "observed-failure"; R.StepAccepted -> "accepted"

migrationValue :: R.MigrationSummary -> Value
migrationValue (R.MigrationSummary definition state attempt steps) = object ["definition" .= definitionValue definition, "state" .= migrationState state, "attempt" .= fmap L.attemptIdText attempt, "steps" .= map stepValue steps]
  where
    stepValue (R.StepSummary name checksum status selected evidence) = object ["name" .= name, "checksum" .= checksum, "state" .= stepState status, "attempt" .= nullable stepAttemptValue selected, "evidence" .= nullable evidenceValue evidence]

accessValue :: Access.AccessDescription -> Value
accessValue access = object ["strategy" .= Access.accessStrategy access, "scope" .= Access.accessScope access]

observationAccess :: R.InspectionAccess -> Value
observationAccess = \case
  R.UnguardedObservation -> object ["mode" .= ("unguarded-observation" :: Text)]
  R.GuardedObservation access -> object ["mode" .= ("guarded-observation" :: Text), "provider" .= accessValue access]

presenceValue :: R.LedgerPresence -> Value
presenceValue = \case
  R.LedgerUnknown -> object ["kind" .= ("unknown" :: Text)]
  R.LedgerMissing -> object ["kind" .= ("missing" :: Text)]
  R.LedgerUninitialized -> object ["kind" .= ("uninitialized" :: Text)]
  R.LedgerInitializedAt ledger -> object ["kind" .= ("initialized" :: Text), "ledgerId" .= T.ledgerIdText ledger]

serverValue :: T.ServerIdentity -> Value
serverValue identity = object ["serverId" .= T.serverIdText (T.identityServerId identity), "version" .= T.identityVersion identity, "hostName" .= T.identityHostName identity]

historyValue :: R.HistoryReport -> Value
historyValue (R.HistoryReport target server presence position access events migrations unresolved) = object ["target" .= T.targetKeyText target, "server" .= nullable serverValue server, "ledger" .= presenceValue presence, "position" .= fmap L.ledgerPositionText position, "access" .= observationAccess access, "events" .= map eventValue events, "migrations" .= map migrationValue migrations, "unresolved" .= unresolved]

inspectionValue :: R.InspectionReport -> Value
inspectionValue (R.InspectionReport history migrations issues) = object ["observation" .= historyValue history, "migrations" .= map migrationValue migrations, "issues" .= map issueValue issues]

issueValue :: R.CompatibilityIssue -> Value
issueValue = \case
  R.DefinitionChanged index expected actual -> object ["code" .= ("definition-changed" :: Text), "index" .= index, "expected" .= nullable definitionValue expected, "actual" .= nullable definitionValue actual]
  R.UnresolvedAttempt attempt -> object ["code" .= ("unresolved-attempt" :: Text), "attempt" .= L.attemptIdText attempt]
  R.IncompleteAdoption batch -> object ["code" .= ("incomplete-adoption" :: Text), "batch" .= adoptionValue batch]

runValue :: R.RunReport -> Value
runValue (R.RunReport identity target access acquired history migrations observations initialized) = object ["runId" .= identity, "target" .= T.targetKeyText target, "access" .= accessValue access, "acquired" .= acquired, "history" .= historyValue history, "migrations" .= map migrationValue migrations, "observations" .= map sqlValue observations, "initializedLedgerId" .= fmap T.ledgerIdText initialized]

sqlValue :: R.SqlObservation -> Value
sqlValue (R.SqlObservation reference query evidence) = object ["step" .= stepReferenceValue reference, "queryId" .= T.queryIdText query, "evidence" .= case evidence of R.QueryAcknowledged -> object ["outcome" .= ("acknowledged-success" :: Text)]; R.QueryRejected outcome problem -> object ["outcome" .= requestEvidence outcome, "transport" .= transportValue problem]]

auditValue :: L.AuditContext -> Value
auditValue audit = object ["actor" .= L.auditActor audit, "reason" .= L.auditReason audit, "references" .= L.auditReferences audit]

adoptionValue :: R.AdoptionSummary -> Value
adoptionValue (R.AdoptionSummary source snapshot mapping definitions count) = object ["source" .= source, "snapshotDigest" .= snapshot, "mappingDigest" .= mapping, "definitionsDigest" .= definitions, "count" .= count]

eventValue :: R.HistoryEvent -> Value
eventValue (R.HistoryEvent eventSequence identity ledger run attempt time audit runner context body) = object ["sequence" .= Text.pack (show eventSequence), "eventId" .= identity, "ledgerId" .= T.ledgerIdText ledger, "runId" .= run, "attempt" .= fmap L.attemptIdText attempt, "occurredAt" .= time, "audit" .= auditValue audit, "runnerVersion" .= runner, "context" .= nullable contextValue context, "kind" .= R.historyKind body, "body" .= bodyValue body]
  where
    contextValue (component, migration, checksum, step) = object ["component" .= component, "migration" .= migration, "checksum" .= checksum, "step" .= nullable (\(name, digest) -> object ["name" .= name, "checksum" .= digest]) step]

bodyValue :: R.HistoryBody -> Value
bodyValue = \case
  R.LedgerInitialized target -> object ["target" .= T.targetKeyText target]
  R.MigrationDefinition definition -> object ["definition" .= definitionValue definition]
  R.StepIntent index query -> object ["step" .= index, "queryId" .= T.queryIdText query]
  R.StepCompletion index query -> object ["step" .= index, "queryId" .= T.queryIdText query]
  R.ExecutionFailure index query (R.FailureSummary code status server) -> object ["step" .= index, "queryId" .= T.queryIdText query, "code" .= code, "httpStatus" .= status, "serverCode" .= server]
  R.MigrationCompletion -> object []
  R.RecoveryAuthorization action expected previous next target quietAudit -> object ["action" .= recoveryValue action, "expected" .= L.ledgerPositionText expected, "previousAttempt" .= L.attemptIdText previous, "nextAttempt" .= L.attemptIdText next, "target" .= T.targetKeyText target, "quiescence" .= auditValue quietAudit]
  R.AcceptedCompletion index evidence -> object ["step" .= index, "evidence" .= evidenceValue evidence]
  R.AdoptionBeginning batch -> adoptionValue batch
  R.AdoptedDefinition definition evidence -> object ["definition" .= definitionValue definition, "evidence" .= evidenceValue evidence]
  R.AdoptionCompletion digest -> object ["mappingDigest" .= digest]

recoveryValue :: R.RecoveryAction -> Value
recoveryValue = \case R.Resume -> object ["kind" .= ("resume" :: Text)]; R.RetryStep index -> object ["kind" .= ("retry-step" :: Text), "step" .= index]; R.AcceptStep index -> object ["kind" .= ("accept-step" :: Text), "step" .= index]; R.Finalize -> object ["kind" .= ("finalize" :: Text)]

failureValue :: CommandFailure -> Value
failureValue = \case
  CommandRejected failure -> envelope "command" (object ["code" .= commandErrorCode failure]) [] Null
  AdoptionRejected failure observation -> envelope "adoption" (object ["code" .= adoptionErrorCode failure]) [] (historyValue observation)
  RunFailed (R.RunFailure primary report secondary) -> envelope "run" (runErrorValue primary) (map secondaryValue secondary) (runValue report)
  InspectionFailed (R.InspectionFailure primary observation secondary) -> envelope "inspection" (runErrorValue primary) (map secondaryValue secondary) (nullable historyValue observation)
  where
    envelope :: Text -> Value -> [Value] -> Value -> Value
    envelope category primary secondary report = object ["category" .= (category :: Text), "primary" .= primary, "secondary" .= secondary, "report" .= report]

secondaryValue :: R.SecondaryError -> Value
secondaryValue = \case
  R.RecordingError problem -> object ["kind" .= ("recording" :: Text), "error" .= runErrorValue problem]
  R.ObserverError phase -> object ["kind" .= ("observer" :: Text), "callback" .= callbackValue phase]
  R.TransportCleanup problem -> object ["kind" .= ("transport-cleanup" :: Text), "error" .= transportValue problem]
  R.AccessCleanup problem -> object ["kind" .= ("access-cleanup" :: Text), "code" .= accessErrorCode problem]

callbackValue :: R.CallbackPhase -> Value
callbackValue = \case R.EventCallback phase -> object ["kind" .= ("event" :: Text), "phase" .= phase]; R.SqlDiagnosticCallback -> object ["kind" .= ("sql-diagnostic" :: Text)]

requestEvidence :: L.RequestEvidence -> Text
requestEvidence = \case L.PositiveNonSubmission -> "positive-non-submission"; L.ObservedFailure -> "observed-server-failure"; L.UncertainSubmission -> "submission-uncertain"

transportValue :: L.TransportError -> Value
transportValue (L.TransportError code status server) = object ["code" .= transportErrorCode code, "httpStatus" .= status, "serverCode" .= server]

transportErrorCode :: L.TransportErrorCode -> Text
transportErrorCode = \case L.AdministrativeAccessLost -> "administrative-access-lost"; L.InvalidRequest -> "invalid-request"; L.ClientScopeFailed -> "client-scope-failed"; L.ConnectionFailed -> "connection-failed"; L.DeadlineExpired -> "deadline-expired"; L.ResponseInterrupted -> "response-interrupted"; L.ResponseTooLarge -> "response-too-large"; L.UnexpectedResponse -> "unexpected-response"; L.ServerRejected -> "server-rejected"; L.RedirectRejected -> "redirect-rejected"; L.ServerIdentityMismatch -> "server-identity-mismatch"; L.UnsupportedServer -> "unsupported-server"; L.CompletionPolicyMismatch -> "completion-policy-mismatch"; L.CleanupFailed -> "cleanup-failed"; L.CleanupTimedOut -> "cleanup-timed-out"

accessErrorCode :: Access.AccessError -> Text
accessErrorCode = \case Access.InvalidAccessStrategy -> "invalid-access-strategy"; Access.AcquisitionTimedOut -> "acquisition-timed-out"; Access.AcquisitionFailed -> "acquisition-failed"; Access.AccessLost -> "access-lost"; Access.AccessScopeClosed -> "access-scope-closed"; Access.AccessActionFailed -> "access-action-failed"; Access.PredecessorQuiescenceRequired -> "predecessor-quiescence-required"; Access.AccessReleaseFailed -> "access-release-failed"; Access.AccessReleaseTimedOut -> "access-release-timed-out"

ledgerErrorCode :: L.LedgerError -> Text
ledgerErrorCode = \case L.InvalidPosition -> "invalid-position"; L.InvalidAudit -> "invalid-audit"; L.InvalidEvidence -> "invalid-evidence"; L.InvalidEvent -> "invalid-event"; L.UnsupportedLedgerVersion -> "unsupported-ledger-version"; L.SequenceGap -> "sequence-gap"; L.SequenceConflict -> "sequence-conflict"; L.EventIdentityConflict -> "event-identity-conflict"; L.LedgerIdentityMismatch -> "ledger-identity-mismatch"; L.MissingInitialization -> "missing-initialization"; L.ImpossibleTransition -> "impossible-transition"; L.DefinitionMismatch -> "definition-mismatch"; L.InvalidLedgerSchema -> "invalid-ledger-schema"; L.UnsupportedLedgerStorage -> "unsupported-ledger-storage"; L.LedgerAbsent -> "ledger-absent"; L.LedgerUninitialized -> "ledger-uninitialized"; L.InitializationNotAuthorized -> "initialization-not-authorized"; L.StaleLedgerState -> "stale-ledger-state"; L.UnresolvedHistory -> "unresolved-history"; L.OutstandingRequests -> "outstanding-requests"; L.LedgerLimitExceeded -> "ledger-limit-exceeded"

adoptionErrorCode :: A.AdoptionError -> Text
adoptionErrorCode = \case A.InvalidSourceEvidence -> "invalid-source-evidence"; A.UnsupportedSourceChecksum -> "unsupported-source-checksum"; A.InvalidSourceChecksum -> "invalid-source-checksum"; A.DuplicateSourceRow -> "duplicate-source-row"; A.DuplicateMapping -> "duplicate-mapping"; A.IncompleteMapping -> "incomplete-mapping"; A.UnknownSourceRow -> "unknown-source-row"; A.MappingOrderMismatch -> "mapping-order-mismatch"; A.MappingDefinitionMismatch -> "mapping-definition-mismatch"; A.HistoricalChecksumMismatch -> "historical-checksum-mismatch"; A.HistoricalChecksumRequired -> "historical-checksum-required"; A.AdoptionTargetMismatch -> "adoption-target-mismatch"; A.AdoptionInitializationRequired -> "adoption-initialization-required"; A.AdoptionExpectedStateMismatch -> "adoption-expected-state-mismatch"; A.AdoptionNativeConflict -> "adoption-native-conflict"; A.AdoptionBatchConflict -> "adoption-batch-conflict"; A.AdoptionResumeRequired -> "adoption-resume-required"; A.AdoptionBatchTooLarge -> "adoption-batch-too-large"

repairReason :: R.RepairReason -> Text
repairReason = \case R.NoActiveMigration -> "no-active-migration"; R.AdoptionInProgress -> "adoption-in-progress"; R.UncertainStepRemains -> "uncertain-step-remains"; R.NoPendingSteps -> "no-pending-steps"; R.SelectedStepIsResolved -> "selected-step-is-resolved"; R.StepsNotResolved -> "steps-not-resolved"; R.ConflictingAppend -> "conflicting-append"; R.WrongQuiescenceTarget -> "wrong-quiescence-target"

commandErrorCode :: CommandError -> Text
commandErrorCode = \case InvalidArguments -> "invalid-arguments"; MissingTargetConfiguration -> "missing-target-configuration"; MissingExclusiveAccess -> "missing-exclusive-access"; CommandNotAllowed -> "command-not-allowed"; ExpectedTargetMismatch -> "expected-target-mismatch"; InvalidAuditInput -> "invalid-audit-input"; QuiescenceRequired -> "quiescence-required"; RecoveryEvidenceRequired -> "recovery-evidence-required"; InvalidRepairInput -> "invalid-repair-input"; InitializationRequired -> "initialization-required"; InvalidAdoptionInput -> "invalid-adoption-input"; InputUnavailable -> "input-unavailable"; InputTooLarge -> "input-too-large"; InvalidJsonInput -> "invalid-json-input"; DuplicateJsonKey -> "duplicate-json-key"; UnsupportedInputVersion -> "unsupported-input-version"

runErrorCode :: R.RunError -> Text
runErrorCode = \case
  R.InvalidRuntimePlan _ -> "invalid-runtime-plan"
  R.LedgerNamespaceInSql _ -> "ledger-namespace-in-sql"
  R.DefinitionTooLarge _ -> "definition-too-large"
  R.AccessFailed problem -> accessErrorCode problem
  R.TargetFailed _ -> "target-failed"
  R.LedgerFailed problem -> ledgerErrorCode problem
  R.LedgerRequestFailed {} -> "ledger-request-failed"
  R.InitializationFailed {} -> "initialization-failed"
  R.SqlFailed {} -> "sql-failed"
  R.CallbackFailed _ -> "callback-failed"
  R.IncompatibleHistory _ -> "incompatible-history"
  R.VerificationNotCurrent -> "verification-not-current"
  R.AuditTooLarge -> "audit-too-large"
  R.LedgerRequired -> "ledger-required"
  R.AdoptionRejected problem -> adoptionErrorCode problem
  R.ExistingBindingRequired -> "existing-ledger-binding-required"
  R.StalePosition {} -> "stale-position"
  R.AttemptMismatch {} -> "attempt-mismatch"
  R.StepAttemptMismatch _ -> "step-attempt-mismatch"
  R.RepairNotAllowed _ -> "repair-not-allowed"
  R.PriorQueriesActive _ -> "prior-queries-active"
  R.CleanupFailed -> "cleanup-failed"
  R.UnexpectedRuntimeFailure -> "unexpected-runtime-failure"

runErrorValue :: R.RunError -> Value
runErrorValue failure = object (("code" .= runErrorCode failure) : fields failure)
  where
    fields = \case
      R.InvalidRuntimePlan step -> ["step" .= stepReferenceValue step]
      R.LedgerNamespaceInSql step -> ["step" .= stepReferenceValue step]
      R.DefinitionTooLarge definition -> ["definition" .= definitionValue definition]
      R.AccessFailed _ -> []
      R.TargetFailed problem -> ["transport" .= transportValue problem]
      R.LedgerFailed _ -> []
      R.LedgerRequestFailed evidence problem receipt -> ["evidence" .= requestEvidence evidence, "transport" .= transportValue problem, "pendingAppend" .= fmap L.appendReceiptText receipt]
      R.InitializationFailed ledger stage query evidence problem -> ["ledgerId" .= ledger, "stage" .= stage, "queryId" .= T.queryIdText query, "evidence" .= requestEvidence evidence, "transport" .= transportValue problem]
      R.SqlFailed step query evidence problem -> ["step" .= stepReferenceValue step, "queryId" .= T.queryIdText query, "evidence" .= requestEvidence evidence, "transport" .= transportValue problem]
      R.CallbackFailed phase -> ["callback" .= callbackValue phase]
      R.IncompatibleHistory issues -> ["issues" .= map issueValue issues]
      R.VerificationNotCurrent -> []
      R.AuditTooLarge -> []
      R.LedgerRequired -> []
      R.AdoptionRejected _ -> []
      R.ExistingBindingRequired -> []
      R.StalePosition expected actual -> ["expected" .= L.ledgerPositionText expected, "actual" .= fmap L.ledgerPositionText actual]
      R.AttemptMismatch expected actual -> ["expected" .= L.attemptIdText expected, "actual" .= fmap L.attemptIdText actual]
      R.StepAttemptMismatch step -> ["stepAttempt" .= stepAttemptValue step]
      R.RepairNotAllowed reason -> ["reason" .= repairReason reason]
      R.PriorQueriesActive queries -> ["queryIds" .= map T.queryIdText queries]
      R.CleanupFailed -> []
      R.UnexpectedRuntimeFailure -> []
