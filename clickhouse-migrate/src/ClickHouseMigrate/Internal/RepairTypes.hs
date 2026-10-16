module ClickHouseMigrate.Internal.RepairTypes where

import ClickHouseMigrate.Ledger (AppendReceipt, AttemptId, AuditContext, LedgerPosition, QuiescenceEvidence)
import ClickHouseMigrate.Report (StepAttempt)

data RecoveryEvidence = RecoveryEvidence !AuditContext !QuiescenceEvidence ![AppendReceipt]

data RepairRequest
  = ResumeRequest !LedgerPosition !AttemptId !RecoveryEvidence
  | RetryStepRequest !LedgerPosition !AttemptId !StepAttempt !RecoveryEvidence
  | AcceptStepRequest !LedgerPosition !AttemptId !StepAttempt !RecoveryEvidence
  | FinalizeRequest !LedgerPosition !AttemptId !RecoveryEvidence

data RepairRequestError = MissingRecoveryEvidence | InvalidStepAttempt | InvalidRecoveryTarget | TooManyPendingReceipts | ForeignLedgerReceipt
  deriving stock (Eq, Show)
