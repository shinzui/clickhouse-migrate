-- | Safe domain observations. Reports contain identities/checksums and audit
-- evidence, never SQL bodies, credentials, or raw server exception messages.
module ClickHouseMigrate.Report where

import ClickHouseMigrate.ExclusiveAccess (AccessDescription, AccessError)
import ClickHouseMigrate.Internal.AdoptionTypes (AdoptionError)
import ClickHouseMigrate.Ledger (AppendReceipt, AttemptId, AuditContext, EvidenceLevel, LedgerError, LedgerPosition, RequestEvidence, TransportError)
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (LedgerId, QueryId, ServerIdentity, TargetKey)
import Data.Word (Word64)

data StepReference = StepReference
  { component :: !Text,
    migration :: !Text,
    step :: !Text,
    migrationChecksum :: !Text,
    stepChecksum :: !Text
  }
  deriving stock (Eq, Show)

data DefinitionSummary = DefinitionSummary
  { ordinal :: !Int,
    componentIndex :: !Int,
    component :: !Text,
    dependencies :: ![Text],
    migration :: !Text,
    checksum :: !Text,
    stepDefinitions :: ![(Text, Text)]
  }
  deriving stock (Eq, Show)

data EvidenceSummary = EvidenceSummary !EvidenceLevel ![Text] deriving stock (Eq, Show)

data MigrationStatus = Pending | InProgress | Failed | Applied | Adopted | Invalid deriving stock (Eq, Show)

data StepStatus = StepPending | StepUncertain | StepObservedSuccess | StepObservedFailure | StepAccepted deriving stock (Eq, Show)

-- A step attempt is identified by its original migration attempt and query ID.
-- Recovery authorization may change the active migration attempt without sending
-- another query; reports preserve that distinction.
data StepAttempt = StepAttempt !AttemptId !Text !QueryId deriving stock (Eq, Show)

data StepSummary = StepSummary
  { name :: !Text,
    checksum :: !Text,
    state :: !StepStatus,
    attempt :: !(Maybe StepAttempt),
    evidence :: !(Maybe EvidenceSummary)
  }
  deriving stock (Eq, Show)

data MigrationSummary = MigrationSummary
  { definition :: !DefinitionSummary,
    state :: !MigrationStatus,
    attempt :: !(Maybe AttemptId),
    steps :: ![StepSummary]
  }
  deriving stock (Eq, Show)

data RecoveryAction = Resume | RetryStep !Int | AcceptStep !Int | Finalize deriving stock (Eq, Show)

data AdoptionSummary = AdoptionSummary
  { source :: !Text,
    snapshotDigest :: !Text,
    mappingDigest :: !Text,
    definitionsDigest :: !Text,
    count :: !Int
  }
  deriving stock (Eq, Show)

data FailureSummary = FailureSummary !Text !(Maybe Int) !(Maybe Int) deriving stock (Eq, Show)

data HistoryBody
  = LedgerInitialized !TargetKey
  | MigrationDefinition !DefinitionSummary
  | StepIntent !Int !QueryId
  | StepCompletion !Int !QueryId
  | ExecutionFailure !Int !QueryId !FailureSummary
  | MigrationCompletion
  | RecoveryAuthorization !RecoveryAction !LedgerPosition !AttemptId !AttemptId !TargetKey !AuditContext
  | AcceptedCompletion !Int !EvidenceSummary
  | AdoptionBeginning !AdoptionSummary
  | AdoptedDefinition !DefinitionSummary !EvidenceSummary
  | AdoptionCompletion !Text
  deriving stock (Eq, Show)

data HistoryEvent = HistoryEvent
  { sequence :: !Word64,
    eventId :: !Text,
    ledgerId :: !LedgerId,
    runId :: !Text,
    attempt :: !(Maybe AttemptId),
    occurredAt :: !Text,
    audit :: !AuditContext,
    runnerVersion :: !Text,
    context :: !(Maybe (Text, Text, Text, Maybe (Text, Text))),
    body :: !HistoryBody
  }
  deriving stock (Eq, Show)

data LedgerPresence = LedgerUnknown | LedgerMissing | LedgerUninitialized | LedgerInitializedAt !LedgerId deriving stock (Eq, Show)

data InspectionAccess = UnguardedObservation | GuardedObservation !AccessDescription deriving stock (Eq, Show)

data HistoryReport = HistoryReport
  { target :: !TargetKey,
    server :: !(Maybe ServerIdentity),
    presence :: !LedgerPresence,
    position :: !(Maybe LedgerPosition),
    access :: !InspectionAccess,
    events :: ![HistoryEvent],
    migrations :: ![MigrationSummary],
    unresolved :: !Bool
  }
  deriving stock (Eq, Show)

data CompatibilityIssue
  = DefinitionChanged !Int !(Maybe DefinitionSummary) !(Maybe DefinitionSummary)
  | UnresolvedAttempt !AttemptId
  | IncompleteAdoption !AdoptionSummary
  deriving stock (Eq, Show)

data InspectionReport = InspectionReport
  {history :: !HistoryReport, migrations :: ![MigrationSummary], issues :: ![CompatibilityIssue]}
  deriving stock (Eq, Show)

data VerificationReport = VerificationReport
  {inspection :: !InspectionReport, current :: !Bool}
  deriving stock (Eq, Show)

data SqlObservation = SqlObservation !StepReference !QueryId !SqlEvidence deriving stock (Eq, Show)

data SqlEvidence = QueryAcknowledged | QueryRejected !RequestEvidence !TransportError deriving stock (Eq, Show)

data RunReport = RunReport
  { runId :: !Text,
    target :: !TargetKey,
    access :: !AccessDescription,
    acquired :: !Bool,
    history :: !HistoryReport,
    migrations :: ![MigrationSummary],
    observations :: ![SqlObservation],
    initialized :: !(Maybe LedgerId)
  }
  deriving stock (Eq, Show)

data CallbackPhase = EventCallback !Text | SqlDiagnosticCallback deriving stock (Eq, Show)

data RepairReason = NoActiveMigration | AdoptionInProgress | UncertainStepRemains | NoPendingSteps | SelectedStepIsResolved | StepsNotResolved | ConflictingAppend | WrongQuiescenceTarget deriving stock (Eq, Show)

data RunError
  = InvalidRuntimePlan !StepReference
  | LedgerNamespaceInSql !StepReference
  | DefinitionTooLarge !DefinitionSummary
  | AccessFailed !AccessError
  | TargetFailed !TransportError
  | LedgerFailed !LedgerError
  | LedgerRequestFailed !RequestEvidence !TransportError !(Maybe AppendReceipt)
  | InitializationFailed !Text !Text !QueryId !RequestEvidence !TransportError
  | SqlFailed !StepReference !QueryId !RequestEvidence !TransportError
  | CallbackFailed !CallbackPhase
  | IncompatibleHistory ![CompatibilityIssue]
  | VerificationNotCurrent
  | AuditTooLarge
  | LedgerRequired
  | AdoptionRejected !AdoptionError
  | ExistingBindingRequired
  | StalePosition !LedgerPosition !(Maybe LedgerPosition)
  | AttemptMismatch !AttemptId !(Maybe AttemptId)
  | StepAttemptMismatch !StepAttempt
  | RepairNotAllowed !RepairReason
  | PriorQueriesActive ![QueryId]
  | CleanupFailed
  | UnexpectedRuntimeFailure
  deriving stock (Eq, Show)

data SecondaryError = RecordingError !RunError | ObserverError !CallbackPhase | TransportCleanup !TransportError | AccessCleanup !AccessError deriving stock (Eq, Show)

data RunFailure = RunFailure
  {primary :: !RunError, report :: !RunReport, secondary :: ![SecondaryError]}
  deriving stock (Eq, Show)

data InspectionFailure = InspectionFailure
  {primary :: !RunError, observation :: !(Maybe HistoryReport), secondary :: ![SecondaryError]}
  deriving stock (Eq, Show)

historyKind :: HistoryBody -> Text
historyKind = \case
  LedgerInitialized _ -> "initialized"
  MigrationDefinition _ -> "migration-started"
  StepIntent _ _ -> "step-started"
  StepCompletion _ _ -> "step-succeeded"
  ExecutionFailure _ _ _ -> "execution-failed"
  MigrationCompletion -> "migration-completed"
  RecoveryAuthorization {} -> "recovery-authorized"
  AcceptedCompletion _ _ -> "step-accepted"
  AdoptionBeginning _ -> "adoption-started"
  AdoptedDefinition _ _ -> "adoption-entry"
  AdoptionCompletion _ -> "adoption-completed"
