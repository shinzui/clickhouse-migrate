-- | Force the complete definition/target envelope before contacting a server.
module ClickHouseMigrate.Internal.Preflight (preflight, validateRecoveryEvent, validateRecoveryCapacity) where

import ClickHouseMigrate.Internal.LedgerCodec (contextFor, definitions, encodeEvent, maxEventBytes, validateEvent)
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Reporting (stepReference, summaryDefinition)
import ClickHouseMigrate.Internal.SqlEnvelope (mentionsIdentifier, validateSql)
import ClickHouseMigrate.Internal.TargetTypes qualified as T
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target (ledgerNamespaceText)
import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NE
import Data.Word (Word64)

preflight :: T.TargetConfig -> L.AuditContext -> Plan.MigrationPlan -> Either R.RunError ()
preflight (T.TargetConfig target _ _ namespace _ _ _) audit plan = do
  let uuid = "00000000-0000-4000-8000-000000000000"
      envelope body context = L.LedgerEvent 1 uuid (T.LedgerId uuid) uuid (Just uuid) "2026-10-16T00:00:00.999999999999Z" audit "0.1.0.0" context body
      authored = [(migration, NE.toList (Plan.migrationSteps migration)) | migration <- NE.toList (Plan.inspectSchedule plan)]
      sources = zip (definitions plan) authored
  if BS.length (encodeEvent (envelope (L.Initialize target) Nothing)) > 61440 then Left R.AuditTooLarge else pure ()
  mapM_
    ( \(definition, (_, steps)) -> do
        context <- either (const (Left (R.DefinitionTooLarge (summaryDefinition definition)))) Right (contextFor definition Nothing)
        if BS.length (encodeEvent (envelope (L.StartMigration definition) (Just context))) > 61440 then Left (R.DefinitionTooLarge (summaryDefinition definition)) else pure ()
        mapM_
          ( \(index, step) -> case stepReference definition index of
              Nothing -> Left R.UnexpectedRuntimeFailure
              Just reference -> do
                either (const (Left (R.InvalidRuntimePlan reference))) Right (validateSql (Plan.stepSql step))
                mentioned <- either (const (Left (R.InvalidRuntimePlan reference))) Right (mentionsIdentifier (ledgerNamespaceText namespace) (Plan.stepSql step))
                if mentioned then Left (R.LedgerNamespaceInSql reference) else pure ()
          )
          (zip [0 ..] steps)
    )
    sources

-- Count the one canonical UTF-8/JSON encoding, including repeated evidence.
validateRecoveryEvent :: R.RecoveryEventKind -> L.LedgerEvent -> Either R.RunError ()
validateRecoveryEvent kind event
  | BS.length (encodeEvent event) > maxEventBytes = Left (R.RecoveryEventTooLarge kind)
  | otherwise = either (Left . R.LedgerFailed) Right (validateEvent event)

validateRecoveryCapacity :: Word64 -> Integer -> Either R.RunError ()
validateRecoveryCapacity current needed
  | needed < 0 || toInteger current + needed > toInteger (maxBound :: Word64) = Left (R.LedgerFailed L.LedgerLimitExceeded)
  | otherwise = Right ()
