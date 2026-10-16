-- | Private ledger protocol. No unchecked construction is exported publicly.
module ClickHouseMigrate.Internal.LedgerTypes where

import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (LedgerId, QueryId, TargetKey)
import Data.Word (Word64)

-- Tokens contain observations, never authority to mutate.
data AppendReceipt = AppendReceipt !TargetKey !LedgerId !Word64 !Text !Text !QueryId deriving stock (Eq, Show)

data Reconciliation = PresentIdentical | Conflicting | NotObserved deriving stock (Eq, Show)

data LedgerPosition = LedgerPosition !LedgerId !Word64 !Text deriving stock (Eq, Ord, Show)

data ExpectedLedgerState = ExpectAbsent !TargetKey | ExpectPosition !LedgerPosition deriving stock (Eq, Show)

data AuditContext = AuditContext !Text !Text ![Text] deriving stock (Eq, Show)

data QuiescenceEvidence = QuiescenceEvidence !TargetKey !AuditContext deriving stock (Eq, Show)

data InitializationAuthorization = InitializationAuthorization !TargetKey !LedgerId !AuditContext deriving stock (Eq, Show)

data EvidenceLevel = OperatorAttestation | PredecessorChecksum deriving stock (Eq, Ord, Show)

data Evidence = Evidence !EvidenceLevel ![Text] deriving stock (Eq, Show)

data LedgerError
  = InvalidPosition
  | InvalidAudit
  | InvalidEvidence
  | InvalidEvent
  | UnsupportedLedgerVersion
  | SequenceGap
  | SequenceConflict
  | EventIdentityConflict
  | LedgerIdentityMismatch
  | MissingInitialization
  | ImpossibleTransition
  | DefinitionMismatch
  | InvalidLedgerSchema
  | UnsupportedLedgerStorage
  | LedgerAbsent
  | LedgerUninitialized
  | InitializationNotAuthorized
  | StaleLedgerState
  | UnresolvedHistory
  | OutstandingRequests
  | LedgerLimitExceeded
  deriving stock (Eq, Ord, Show)

data Definition = Definition
  { ordinal :: !Int,
    componentIndex :: !Int,
    component :: !Text,
    dependencies :: ![Text],
    migration :: !Text,
    checksum :: !Text,
    steps :: ![StepDefinition]
  }
  deriving stock (Eq, Show)

data StepDefinition = StepDefinition !Text !Text deriving stock (Eq, Show)

data FailureEvidence = FailureEvidence !Text !(Maybe Int) !(Maybe Int) deriving stock (Eq, Show)

data RecoveryAction = Resume | RetryStep !Int | AcceptStep !Int | Finalize deriving stock (Eq, Show)

data Recovery = Recovery !RecoveryAction !LedgerPosition !Text !Text !QuiescenceEvidence deriving stock (Eq, Show)

data AdoptionBatch = AdoptionBatch !Text !Text !Text !Text !Int deriving stock (Eq, Show)

data EventBody
  = Initialize !TargetKey
  | StartMigration !Definition
  | StartStep !Int !Text
  | SucceedStep !Int !Text
  | FailStep !Int !Text !FailureEvidence
  | CompleteMigration
  | AuthorizeRecovery !Recovery
  | AcceptCompletion !Int !Evidence
  | StartAdoption !AdoptionBatch
  | AdoptEntry !Definition !Evidence
  | CompleteAdoption !Text
  deriving stock (Eq, Show)

data EventContext = EventContext !Text !Text !Text !(Maybe (Text, Text)) deriving stock (Eq, Show)

data LedgerEvent = LedgerEvent
  { sequence :: !Word64,
    eventId :: !Text,
    ledgerId :: !LedgerId,
    runId :: !Text,
    attemptId :: !(Maybe Text),
    occurredAt :: !Text,
    audit :: !AuditContext,
    runnerVersion :: !Text,
    context :: !(Maybe EventContext),
    body :: !EventBody
  }
  deriving stock (Eq, Show)

data StepState = NeverStarted | Started !Text | Succeeded !Text | Failed !Text !FailureEvidence | Accepted !Evidence
  deriving stock (Eq, Show)

data MigrationState = Applied | Adopted deriving stock (Eq, Show)

data RecordedMigration = RecordedMigration !Definition !MigrationState ![StepState] deriving stock (Eq, Show)

data ActiveMigration = ActiveMigration !Definition !Text ![StepState] !(Maybe RecoveryAction) deriving stock (Eq, Show)

data ActiveAdoption = ActiveAdoption !AdoptionBatch ![RecordedMigration] deriving stock (Eq, Show)

data Projection = Projection
  { position :: !LedgerPosition,
    target :: !TargetKey,
    completed :: ![RecordedMigration],
    active :: !(Maybe ActiveMigration),
    adoption :: !(Maybe ActiveAdoption),
    events :: ![LedgerEvent]
  }
  deriving stock (Eq, Show)
