{-# LANGUAGE PatternSynonyms #-}

-- | Command values contain input, never an acquired administrative capability.
module ClickHouseMigrate.CLI.Types
  ( OutputFormat (..),
    Invocation (..),
    AuditInput (..),
    UpInput (..),
    RepairOperation (..),
    RepairInput (..),
    AdoptionOperation (..),
    ExpectedInput (..),
    AdoptionInput (..),
    Command (..),
    CommandPolicy (..),
    CommandEnvironment (..),
    CommandError (..),
    CommandFailure (..),
    PlanStep (PlanStep, PlanStepChecksums),
    PlanMigration (PlanMigration, PlanMigrationChecksums),
    PlanComponent (..),
    CommandReport (..),
    CommandResult (..),
    ParseIssue (..),
  )
where

import ClickHouseMigrate.Adoption (AdoptionError)
import ClickHouseMigrate.Event (DiagnosticPolicy, EventSink)
import ClickHouseMigrate.ExclusiveAccess (ExclusiveAccess)
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target (LedgerId, TargetConfig, TargetKey)

data OutputFormat = TextOutput | JsonOutput deriving stock (Eq, Show)

data Invocation = Invocation !OutputFormat !Command deriving stock (Show)

data AuditInput = AuditInput !Text !Text ![Text] deriving stock (Show)

data UpInput = UpInput !TargetKey !AuditInput !(Maybe LedgerId) !Bool deriving stock (Show)

data RepairOperation = Resume | RetryStep | AcceptStep | Finalize deriving stock (Eq, Show)

data RepairInput = RepairInput !TargetKey !L.LedgerPosition !L.AttemptId !(Maybe R.StepAttempt) !AuditInput !Bool ![L.AppendReceipt] deriving stock (Show)

data AdoptionOperation = PlanAdoption | ApplyAdoption | ResumeAdoption deriving stock (Eq, Show)

data ExpectedInput = AbsentInput | PositionInput !L.LedgerPosition deriving stock (Show)

data AdoptionInput = AdoptionInput !TargetKey !ExpectedInput !(Maybe LedgerId) !AuditInput !Bool !Bool !FilePath deriving stock (Show)

data Command
  = PlanCommand
  | StatusCommand !Bool
  | HistoryCommand !Bool
  | VerifyCommand !Bool !Bool
  | UpCommand !UpInput
  | RepairCommand !RepairOperation !RepairInput
  | AdoptCommand !AdoptionOperation !AdoptionInput
  deriving stock (Show)

data CommandPolicy = ReadOnlyCommands | AdministrativeCommands deriving stock (Eq, Show)

-- Configuration and sinks are explicitly supplied. No implicit environment,
-- credentials, stdout, process exit, or live guard is owned by this value.
data CommandEnvironment = CommandEnvironment !(Maybe TargetConfig) !(Maybe ExclusiveAccess) !EventSink !DiagnosticPolicy !CommandPolicy

data CommandError
  = InvalidArguments
  | MissingTargetConfiguration
  | MissingExclusiveAccess
  | CommandNotAllowed
  | ExpectedTargetMismatch
  | InvalidAuditInput
  | QuiescenceRequired
  | RecoveryEvidenceRequired
  | InvalidRepairInput
  | InitializationRequired
  | InvalidAdoptionInput
  | InputUnavailable
  | InputTooLarge
  | InvalidJsonInput
  | DuplicateJsonKey
  | UnsupportedInputVersion
  deriving stock (Eq, Show)

data CommandFailure
  = CommandRejected !CommandError
  | RunFailed !R.RunFailure
  | InspectionFailed !R.InspectionFailure
  | AdoptionRejected !AdoptionError !R.HistoryReport
  deriving stock (Show)

data PlanStep = PlanStepChecksums !Text !Text !(Maybe Text) deriving stock (Eq, Show)

data PlanMigration = PlanMigrationChecksums !Text !(Maybe Text) !Text !(Maybe Text) ![PlanStep] deriving stock (Eq, Show)

-- Preserve existing construction and matching arities while retaining additive
-- v2 data. Manually constructed legacy reports have no known v2 digest.
pattern PlanStep :: Text -> Text -> PlanStep
pattern PlanStep name checksum <- PlanStepChecksums name checksum _
  where
    PlanStep name checksum = PlanStepChecksums name checksum Nothing

pattern PlanMigration :: Text -> Maybe Text -> Text -> [PlanStep] -> PlanMigration
pattern PlanMigration name description checksum steps <- PlanMigrationChecksums name description checksum _ steps
  where
    PlanMigration name description checksum steps = PlanMigrationChecksums name description checksum Nothing steps

{-# COMPLETE PlanStep #-}

{-# COMPLETE PlanMigration #-}

data PlanComponent = PlanComponent !Text ![Text] ![PlanMigration] deriving stock (Eq, Show)

data CommandReport
  = PlanReport ![PlanComponent] ![(Text, Text)]
  | StatusReport !R.InspectionReport
  | HistoryReport !R.HistoryReport
  | VerificationReport !R.VerificationReport
  | RunReport !R.RunReport
  | AdoptionPlanReport !R.HistoryReport !R.AdoptionSummary ![(R.DefinitionSummary, R.EvidenceSummary)]
  deriving stock (Show)

data CommandResult = CommandResult !Text !(Either CommandFailure CommandReport) deriving stock (Show)

data ParseIssue = HelpRequested !Text | ArgumentsRejected | CompletionRequested deriving stock (Show)
