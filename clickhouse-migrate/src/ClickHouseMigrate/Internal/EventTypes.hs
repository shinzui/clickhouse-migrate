-- | Observational callback configuration. No SQL execution capability is passed.
module ClickHouseMigrate.Internal.EventTypes where

import ClickHouseMigrate.Ledger (LedgerPosition)
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report (StepReference)
import ClickHouseMigrate.Target (QueryId)

data EventPhase
  = RunBeginning
  | RunCompleted
  | BeforeMigrationStart
  | MigrationStarted
  | BeforeStepStart
  | StepStarted
  | BeforeSql
  | SqlObserved
  | BeforeStepSuccess
  | StepSucceeded
  | BeforeMigrationComplete
  | MigrationCompleted
  | RecoveryAuthorized
  | StepAccepted
  deriving stock (Eq, Ord, Show)

data RunEvent = RunEvent
  { phase :: !EventPhase,
    runId :: !Text,
    component :: !(Maybe Text),
    migration :: !(Maybe Text),
    step :: !(Maybe Text),
    queryId :: !(Maybe QueryId),
    position :: !(Maybe LedgerPosition)
  }
  deriving stock (Eq, Show)

type EventSink = RunEvent -> IO ()

-- Intentionally no Show instance: SQL enters only an explicitly configured sink.
data SqlDiagnostic = SqlDiagnostic !StepReference !QueryId !ByteString

data DiagnosticPolicy = DiagnosticPolicy !(Maybe (SqlDiagnostic -> IO ()))
