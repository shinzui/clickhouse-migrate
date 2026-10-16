-- | Configuration only; no acquired capability is stored in a public context.
module ClickHouseMigrate.Internal.RuntimeTypes where

import ClickHouseMigrate.Event (DiagnosticPolicy, EventSink)
import ClickHouseMigrate.ExclusiveAccess (ExclusiveAccess)
import ClickHouseMigrate.Ledger (AuditContext, InitializationAuthorization)
import ClickHouseMigrate.Target (TargetConfig)

data MutationContext = MutationContext !TargetConfig !ExclusiveAccess !EventSink !DiagnosticPolicy

data UpOptions = UpOptions !AuditContext !(Maybe InitializationAuthorization)

data InspectionOptions = Observe | Guarded !ExclusiveAccess

data VerifyOptions = VerifyOptions !Bool deriving stock (Eq, Show)
