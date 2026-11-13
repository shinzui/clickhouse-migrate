module ClickHouseMigrate.Internal.RepairTypes where

import ClickHouseMigrate.Ledger (AppendReceipt, AttemptId, AuditContext, LedgerPosition, QuiescenceEvidence)
import ClickHouseMigrate.Report (StepAttempt)
import ClickHouseMigrate.Target (QueryId)

-- Observations describe diagnostics, never the authority to enter recovery.
data RepairObservation
  = NoRecordedQueries
  | NoVisibleRecordedQueries
  | RecordedQueriesActive ![QueryId]
  | ProcessObservationUnavailable
  deriving stock (Eq, Show)

type RepairObservationSink = RepairObservation -> IO ()

data ProcessObservationPolicy = StrictObservation | ExternalDrain !RepairObservationSink

data RecoveryEvidence = RecoveryEvidence !AuditContext !QuiescenceEvidence ![AppendReceipt] !ProcessObservationPolicy

data RepairRequest
  = ResumeRequest !LedgerPosition !AttemptId !RecoveryEvidence
  | RetryStepRequest !LedgerPosition !AttemptId !StepAttempt !RecoveryEvidence
  | AcceptStepRequest !LedgerPosition !AttemptId !StepAttempt !RecoveryEvidence
  | FinalizeRequest !LedgerPosition !AttemptId !RecoveryEvidence

data RepairRequestError = MissingRecoveryEvidence | InvalidStepAttempt | InvalidRecoveryTarget | TooManyPendingReceipts | ForeignLedgerReceipt
  deriving stock (Eq, Show)
