module AdoptionTests (adoptionTests) where

import ClickHouseMigrate
import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.Internal.AdoptionTypes qualified as Internal
import ClickHouseMigrate.Internal.AdoptionValidation qualified as V
import ClickHouseMigrate.Internal.Checksum qualified as Hash
import ClickHouseMigrate.Internal.LedgerCodec qualified as Codec
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Reporting qualified as Reporting
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Report qualified as R
import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail ("adoption: " ++ label))

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

adoptionTests :: IO ()
adoptionTests = do
  mapM_
    (\sql -> right (sqlStep "local-ddl" sql))
    ["CREATE OR REPLACE VIEW analytics.v AS SELECT 1", "EXCHANGE TABLES analytics.a AND analytics.b", "EXCHANGE TABLES `analytics`.`a` AND `analytics`.`b`"]
  mapM_
    (\sql -> assert "local DDL exception weakened exclusions" (case sqlStep "unsupported" sql of Left (DefinitionError UnsupportedSql _ _) -> True; _ -> False))
    ["CREATE OR REPLACE TABLE analytics.t (id UInt8) ENGINE=Memory", "CREATE OR REPLACE VIEW v AS SELECT 1", "ALTER TABLE analytics.t REPLACE PARTITION 1 FROM analytics.other", "EXCHANGE TABLES a AND analytics.b", "EXCHANGE TABLES analytics.a AND b", "EXCHANGE TABLES analytics.a AND analytics.b ON CLUSTER cluster", "EXCHANGE TABLES analytics.a AND analytics.b, analytics.c AND analytics.d", "SELECT throwIf(1)"]
  key <- right (targetKey "adoption/unit")
  other <- right (targetKey "adoption/foreign")
  ledger <- right (ledgerId "01234567-89ab-4def-8123-456789abcdef")
  audit <- right (Ledger.auditContext "unit operator" "reviewed fixture baseline" ["fixture:source"])
  quiet <- right (Ledger.attestQuiescence key audit)
  create <- right (sqlStep "create" "CREATE TABLE default.adoption (id UInt8) ENGINE=Memory")
  one <- right (sqlMigration "one" (create :| []))
  two <- right (sqlMigration "two" (create :| []))
  component <- right (migrationComponent "app" Set.empty (one :| [two]))
  plan <- right (migrationPlan (component :| []))
  (first, second) <- case Codec.definitions plan of
    [oneDefinition, twoDefinition] -> pure (oneDefinition, twoDefinition)
    _ -> fail "Unexpected adoption unit plan"
  let observation = R.HistoryReport key Nothing R.LedgerMissing Nothing R.UnguardedObservation [] [] False
      snapshot = Reporting.inspectHistory plan observation
      checksum definition = L.checksum definition
      build rows mappings = A.adoptionRequest key (Ledger.ExpectAbsent key) (Just (Ledger.authorizeInitialization key ledger audit)) quiet audit "legacy-fixture" "fixture:immutable-snapshot" rows mappings
      accept row migration digest = A.attestedMapping row "app" migration digest ["fixture:reviewed-step-mapping"]
  row <- right (A.legacyRow "001.sql" "2020-01-01T00:00:00Z" Nothing)
  later <- right (A.legacyRow "002.sql" "2020-01-02T00:00:00Z" Nothing)
  mapping <- right (accept "001.sql" "one" (checksum first))
  next <- right (accept "002.sql" "two" (checksum second))
  request <- right (build (row :| []) (mapping :| []))
  adopted <- right (A.planAdoption plan snapshot request)
  assert "independent adoption-v1 operator-attestation vector" (case A.inspectAdoption adopted of R.AdoptionSummary _ snapshotHash mappingHash definitionsHash 1 -> (snapshotHash, mappingHash, definitionsHash) == ("0cbd644a1b1871101f5944d249d1d48e6f83f487e43a427eced729390ba9e8f1", "12a26e9bb47128906ec2717968071b3b32ab931670ba83fbf4a8475b27394408", "efa03f51657e440641d3a2a303eebc9b0a933fac99f8ee1e4270e0d13416707c"); _ -> False)
  assert "filename-only history upgraded evidence" (case A.adoptionEntries adopted of [(_, R.EvidenceSummary Ledger.OperatorAttestation _)] -> True; _ -> False)
  let failure expected result = assert (show expected) (case result of Left actual -> actual == expected; Right _ -> False)
  right (build (row :| [row]) (mapping :| [])) >>= failure A.DuplicateSourceRow . A.planAdoption plan snapshot
  right (build (row :| []) (mapping :| [mapping])) >>= failure A.DuplicateMapping . A.planAdoption plan snapshot
  right (build (row :| [later]) (mapping :| [])) >>= failure A.IncompleteMapping . A.planAdoption plan snapshot
  unknown <- right (accept "unknown.sql" "one" (checksum first))
  right (build (row :| []) (unknown :| [])) >>= failure A.UnknownSourceRow . A.planAdoption plan snapshot
  right (build (row :| [later]) (next :| [mapping])) >>= failure A.MappingOrderMismatch . A.planAdoption plan snapshot
  changed <- right (accept "001.sql" "one" (checksum second))
  right (build (row :| []) (changed :| [])) >>= failure A.MappingDefinitionMismatch . A.planAdoption plan snapshot
  verified <- right (A.verifiedMapping "001.sql" "app" "one" (checksum first) "actual historical bytes" ["fixture:predecessor-checksum"])
  right (build (row :| []) (verified :| [])) >>= failure A.HistoricalChecksumRequired . A.planAdoption plan snapshot
  stored <- right (A.sourceChecksum "sha256" (Hash.digestHex (Hash.digest "actual historical bytes")))
  historical <- right (A.legacyRow "001.sql" "2020-01-01T00:00:00Z" (Just stored))
  good <- right (build (historical :| []) (verified :| [])) >>= right . A.planAdoption plan snapshot
  assert "independent adoption-v1 predecessor-checksum vector" (case A.inspectAdoption good of R.AdoptionSummary _ snapshotHash mappingHash definitionsHash 1 -> (snapshotHash, mappingHash, definitionsHash) == ("4906c7532c886734513805a2c730dcb0743e1e7a74ec621965a2b509985213bf", "32c3c3153d39088574f46249fa000b028e4c8353c9e04e6df7d49c054ecb5052", "efa03f51657e440641d3a2a303eebc9b0a933fac99f8ee1e4270e0d13416707c"); _ -> False)
  assert "actual predecessor checksum not distinguished" (case A.adoptionEntries good of [(_, R.EvidenceSummary Ledger.PredecessorChecksum _)] -> True; _ -> False)
  badBytes <- right (A.verifiedMapping "001.sql" "app" "one" (checksum first) "today's different bytes" ["fixture:predecessor-checksum"])
  right (build (historical :| []) (badBytes :| [])) >>= failure A.HistoricalChecksumMismatch . A.planAdoption plan snapshot
  failure A.UnsupportedSourceChecksum (A.sourceChecksum "unknown-algorithm" (checksum first))
  failure A.AdoptionTargetMismatch (A.adoptionRequest other (Ledger.ExpectAbsent other) (Just (Ledger.authorizeInitialization other ledger audit)) quiet audit "legacy-fixture" "fixture:snapshot" (row :| []) (mapping :| []))
  failure A.AdoptionInitializationRequired (A.adoptionRequest key (Ledger.ExpectAbsent key) Nothing quiet audit "legacy-fixture" "fixture:snapshot" (row :| []) (mapping :| []))
  -- A committed identical batch is read-only even with a stale absence token;
  -- a later native migration is retained without becoming a second import.
  let Internal.AdoptionPlan _ batch entries = adopted
      position = L.LedgerPosition ledger 5 "01234567-89ab-4def-8123-456789abcdee"
      L.AdoptionBatch source snapshotHash mappingHash definitionsHash count = batch
      event body = R.HistoryEvent 1 "01234567-89ab-4def-8123-456789abcdee" ledger "01234567-89ab-4def-8123-456789abcdee" Nothing "2026-10-16T00:00:00Z" audit "0.1.0.0" Nothing body
      recorded = [event (R.AdoptionBeginning (R.AdoptionSummary source snapshotHash mappingHash definitionsHash count))] ++ [event (R.AdoptedDefinition (Reporting.summaryDefinition definition) (R.EvidenceSummary level refs)) | (definition, L.Evidence level refs) <- entries] ++ [event (R.AdoptionCompletion mappingHash)]
      committed = R.HistoryReport key Nothing (R.LedgerInitializedAt ledger) (Just position) R.UnguardedObservation recorded [] False
  assert "identical committed batch not inspection-only" (V.checkHistory request batch entries committed == Right True)
  let changedRequest = A.adoptionRequest key (Ledger.ExpectAbsent key) (Just (Ledger.authorizeInitialization key ledger audit)) quiet audit "different-source" "fixture:immutable-snapshot" (row :| []) (mapping :| [])
  right changedRequest >>= failure A.AdoptionExpectedStateMismatch . A.planAdoption plan (Reporting.inspectHistory plan committed)
  putStrLn "Adoption mapping, prefix/order, source evidence strength and committed-batch identity checks passed."
