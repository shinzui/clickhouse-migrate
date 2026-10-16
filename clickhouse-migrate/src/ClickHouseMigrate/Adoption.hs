-- | Reviewed source-neutral adoption into fresh history. Adoption never runs SQL.
module ClickHouseMigrate.Adoption
  ( AdoptionError (..),
    SourceChecksum,
    sourceChecksum,
    LegacyRow,
    legacyRow,
    AdoptionMapping,
    attestedMapping,
    verifiedMapping,
    AdoptionRequest,
    adoptionRequest,
    AdoptionPlan,
    planAdoption,
    inspectAdoption,
    adoptionEntries,
    applyAdoption,
    resumeAdoption,
  )
where

import ClickHouseMigrate.Event qualified as Event
import ClickHouseMigrate.Internal.AdoptionTypes
import ClickHouseMigrate.Internal.AdoptionValidation (adoptionRequest, legacyRow, sourceChecksum)
import ClickHouseMigrate.Internal.AdoptionValidation qualified as Validation
import ClickHouseMigrate.Internal.Execution
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Reporting qualified as Reporting
import ClickHouseMigrate.Internal.RuntimeTypes (MutationContext (..))
import ClickHouseMigrate.Internal.TargetTypes qualified as T
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R

-- | Filename/time history, even with today's source bytes, remains attested.
attestedMapping :: Text -> Text -> Text -> Text -> [Text] -> Either AdoptionError AdoptionMapping
attestedMapping row component migration checksum refs = Validation.mapping row component migration checksum (Attested refs)

-- | Use only when the predecessor actually stored a supported checksum.
-- Supplied historical source bytes must match that stored value; this does not
-- prove that a partially executed legacy file completed or that native SQL ran.
verifiedMapping :: Text -> Text -> Text -> Text -> ByteString -> [Text] -> Either AdoptionError AdoptionMapping
verifiedMapping row component migration checksum bytes refs = Validation.mapping row component migration checksum (Verified bytes refs)

planAdoption :: Plan.MigrationPlan -> R.InspectionReport -> AdoptionRequest -> Either AdoptionError AdoptionPlan
planAdoption plan (R.InspectionReport snapshot _ _) request = do
  (batch, entries) <- Validation.buildBatch plan request
  _ <- Validation.checkHistory request batch entries snapshot
  pure (AdoptionPlan request batch entries)

inspectAdoption :: AdoptionPlan -> R.AdoptionSummary
inspectAdoption (AdoptionPlan _ (L.AdoptionBatch source snapshot mapping definitions count) _) = R.AdoptionSummary source snapshot mapping definitions count

adoptionEntries :: AdoptionPlan -> [(R.DefinitionSummary, R.EvidenceSummary)]
adoptionEntries (AdoptionPlan _ _ entries) = [(Reporting.summaryDefinition definition, R.EvidenceSummary level refs) | (definition, L.Evidence level refs) <- entries]

applyAdoption :: MutationContext -> Plan.MigrationPlan -> AdoptionPlan -> IO (Either R.RunFailure R.RunReport)
applyAdoption = executeAdoption False

resumeAdoption :: MutationContext -> Plan.MigrationPlan -> AdoptionPlan -> IO (Either R.RunFailure R.RunReport)
resumeAdoption = executeAdoption True

executeAdoption :: Bool -> MutationContext -> Plan.MigrationPlan -> AdoptionPlan -> IO (Either R.RunFailure R.RunReport)
executeAdoption resume context@(MutationContext (T.TargetConfig actual _ _ _ binding _ _) _ _ _) plan (AdoptionPlan request@(AdoptionRequest target _ authorization quiet audit _ _ _ _) batch entries) =
  let validate snapshot = either (Left . R.AdoptionRejected) Right $ do
        (current, definitions) <- Validation.buildBatch plan request
        Validation.require MappingDefinitionMismatch (current == batch && definitions == entries)
        committed <- Validation.checkHistory request batch entries snapshot
        unless committed $ do
          let R.HistoryReport _ _ _ _ _ events _ _ = snapshot
              interrupted = any (\case R.HistoryEvent _ _ _ _ _ _ _ _ _ (R.AdoptionBeginning _) -> True; _ -> False) events
          Validation.require (if resume then AdoptionBatchConflict else AdoptionResumeRequired) (resume == interrupted)
        unless committed $ case snapshot of
          R.HistoryReport _ _ presence _ _ _ _ _ | presence `elem` [R.LedgerMissing, R.LedgerUninitialized] -> Validation.require AdoptionInitializationRequired (binding == T.FirstUse && isJust authorization)
          _ -> pure ()
        pure committed
      prerequisite = if target == actual then Right () else Left (R.AdoptionRejected AdoptionTargetMismatch)
   in withRuntimeObservation prerequisite (Just validate) context audit authorization (Just quiet) plan $ \runtime -> do
        projection <- runtimeProjection runtime
        case L.adoption projection of
          Nothing -> do
            when resume (abort (R.AdoptionRejected AdoptionBatchConflict))
            emit runtime Event.BeforeAdoptionStart Nothing Nothing Nothing
            appendEvent runtime Nothing (L.StartAdoption batch) Nothing
            emit runtime Event.AdoptionStarted Nothing Nothing Nothing
          Just (L.ActiveAdoption current _) -> do
            unless resume (abort (R.AdoptionRejected AdoptionResumeRequired))
            unless (current == batch) (abort (R.AdoptionRejected AdoptionBatchConflict))
        after <- runtimeProjection runtime
        completed <- case L.adoption after of Just (L.ActiveAdoption _ values) -> pure (length values); _ -> abort R.UnexpectedRuntimeFailure
        mapM_
          ( \(definition, evidence) -> do
              emit runtime Event.BeforeAdoptionEntry (Just definition) Nothing Nothing
              bound <- contextAt definition Nothing
              appendEvent runtime Nothing (L.AdoptEntry definition evidence) bound
              emit runtime Event.AdoptionEntryRecorded (Just definition) Nothing Nothing
          )
          (drop completed entries)
        let L.AdoptionBatch _ _ mapping _ _ = batch
        emit runtime Event.BeforeAdoptionComplete Nothing Nothing Nothing
        appendEvent runtime Nothing (L.CompleteAdoption mapping) Nothing
        emit runtime Event.AdoptionCompleted Nothing Nothing Nothing
