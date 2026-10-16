-- | Apply the ordered pending suffix once per authorized attempt. Ordinary up
-- never resumes an interrupted migration or adoption, nor retries an append.
module ClickHouseMigrate.Runner
  ( MutationContext,
    mutationContext,
    UpOptions,
    upOptions,
    up,
  )
where

import ClickHouseMigrate.Event (DiagnosticPolicy, EventSink)
import ClickHouseMigrate.ExclusiveAccess (ExclusiveAccess)
import ClickHouseMigrate.Internal.Execution
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Projection (unresolved)
import ClickHouseMigrate.Internal.RuntimeTypes
import ClickHouseMigrate.Ledger (AuditContext, InitializationAuthorization)
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report (RunError (LedgerFailed), RunFailure, RunReport)
import ClickHouseMigrate.Target (TargetConfig)

mutationContext :: TargetConfig -> ExclusiveAccess -> EventSink -> DiagnosticPolicy -> MutationContext
mutationContext = MutationContext

-- | Recurring runs should use Nothing. First use/resumption is a separate,
-- explicitly UUID-bound authorization, never a standing deployment default.
upOptions :: AuditContext -> Maybe InitializationAuthorization -> UpOptions
upOptions = UpOptions

up :: MutationContext -> UpOptions -> MigrationPlan -> IO (Either RunFailure RunReport)
up context (UpOptions audit authorization) plan = withRuntime context audit authorization Nothing plan $ \runtime -> do
  projection <- runtimeProjection runtime
  when (unresolved projection) (abort (LedgerFailed L.UnresolvedHistory))
  mapM_ (uncurry (executeMigration runtime)) (drop (length (L.completed projection)) (orderedMigrations plan))
