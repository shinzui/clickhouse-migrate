-- | Private representations. Adoption input cannot bypass validated construction.
module ClickHouseMigrate.Internal.AdoptionTypes where

import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (TargetKey)

data AdoptionError
  = InvalidSourceEvidence
  | UnsupportedSourceChecksum
  | InvalidSourceChecksum
  | DuplicateSourceRow
  | DuplicateMapping
  | IncompleteMapping
  | UnknownSourceRow
  | MappingOrderMismatch
  | MappingDefinitionMismatch
  | HistoricalChecksumMismatch
  | HistoricalChecksumRequired
  | AdoptionTargetMismatch
  | AdoptionInitializationRequired
  | AdoptionExpectedStateMismatch
  | AdoptionNativeConflict
  | AdoptionBatchConflict
  | AdoptionResumeRequired
  | AdoptionBatchTooLarge
  deriving stock (Eq, Show)

data SourceChecksum = SourceChecksum !Text !Text deriving stock (Eq, Show)

data LegacyRow = LegacyRow !Text !Text !(Maybe SourceChecksum) deriving stock (Eq, Show)

-- Historical source bytes deliberately have no Show instance and never enter
-- default reports. They are used only to verify an actual predecessor checksum.
data MappingEvidence = Attested ![Text] | Verified !ByteString ![Text]

data AdoptionMapping = AdoptionMapping !Text !Text !Text !Text !MappingEvidence

data AdoptionRequest
  = AdoptionRequest
      !TargetKey
      !L.ExpectedLedgerState
      !(Maybe L.InitializationAuthorization)
      !L.QuiescenceEvidence
      !L.AuditContext
      !Text
      !Text
      ![LegacyRow]
      ![AdoptionMapping]

data AdoptionPlan = AdoptionPlan !AdoptionRequest !L.AdoptionBatch ![(L.Definition, L.Evidence)]
