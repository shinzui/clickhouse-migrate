module AdoptionIntegration (adoptionEarlyCases) where

import ClickHouseMigrate
import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Monad (void)
import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as T
import RunnerIntegration (assert, field, fixture, fromJson, provider, right, scalar)

plans :: IO (MigrationPlan, MigrationPlan)
plans = do
  create <- right (sqlStep "create" "CREATE TABLE default.adoption_early (id UInt8) ENGINE=Memory")
  seed <- right (sqlStep "seed" "INSERT INTO default.adoption_early VALUES (1)")
  one <- right (sqlMigration "one" (create :| [seed]))
  add <- right (sqlStep "next" "INSERT INTO default.adoption_early VALUES (9)")
  two <- right (sqlMigration "two" (add :| []))
  component <- right (migrationComponent "app" Set.empty (one :| []))
  extended <- right (migrationComponent "app" Set.empty (one :| [two]))
  (,) <$> right (migrationPlan (component :| [])) <*> right (migrationPlan (extended :| []))

adoptionEarlyCases :: Server -> IO ()
adoptionEarlyCases server = withFaultProxy server $ \proxy -> do
  access <- provider
  audit <- right (L.auditContext "adoption fixture operator" "reviewed synthetic filename-only legacy baseline" ["fixture:legacy-table-and-seed-independent-observation"])
  ledger <- newLedgerId
  key <- right (targetKey "runner-tests/adoption_early")
  quiet <- right (L.attestQuiescence key audit)
  config <- fixture server "adoption_early" (proxyEndpoint proxy) FirstUse
  bound <- fixture server "adoption_early" (proxyEndpoint proxy) (ExistingLedger ledger)
  (plan, extended) <- plans
  -- Independent old-runner effects exist before native history. Adoption must
  -- not execute either CREATE or INSERT, even though both are valid definitions.
  void (queryServer server "CREATE TABLE default.adoption_early (id UInt8) ENGINE=Memory")
  void (queryServer server "INSERT INTO default.adoption_early SETTINGS async_insert=0 VALUES (1)")
  observed <- I.status I.Observe config extended >>= right
  row <- right (A.legacyRow "001.sql" "2020-01-01T00:00:00Z" Nothing)
  let first = NE.head (componentMigrations (NE.head (inspectPlan plan)))
  mapping <- right (A.attestedMapping "001.sql" "app" "one" (migrationChecksumHex (migrationChecksum first)) ["fixture:reviewed-two-statement-mapping"])
  request <- right (A.adoptionRequest key (L.ExpectAbsent key) (Just (L.authorizeInitialization key ledger audit)) quiet audit "synthetic-filename-ledger" "fixture:immutable-source-snapshot" (row :| []) (mapping :| []))
  adoption <- right (A.planAdoption extended observed request)
  let context = Run.mutationContext config access E.quietEvents E.redactedDiagnostics
      existing = Run.mutationContext bound access E.quietEvents E.redactedDiagnostics
  adopted <- A.applyAdoption context extended adoption >>= right
  assert "Adoption did not preserve attested step evidence" (case adopted of R.RunReport _ _ _ _ _ [R.MigrationSummary _ R.Adopted _ [R.StepSummary _ _ R.StepAccepted _ (Just (R.EvidenceSummary L.OperatorAttestation _)), R.StepSummary _ _ R.StepAccepted _ (Just (R.EvidenceSummary L.OperatorAttestation _))], R.MigrationSummary _ R.Pending _ _] [] (Just actual) -> actual == ledger; _ -> False)
  assert "Adoption replayed old INSERT" . (== 1) =<< scalar server "SELECT toUInt32(count()) AS value FROM default.adoption_early"
  received <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") received :: IO [Maybe T.Text]
  assert "Adoption executed application SQL" (null (filter (== Just "application-sql") stages))
  let writes = length (filter (\stage -> stage `elem` map Just ["initialized", "adoption-started", "adoption-entry", "adoption-completed"]) stages)
  assert "Adoption immutable batch incomplete" (writes == 4)
  _ <- I.verify I.Observe bound (I.verifyOptions False) extended >>= right
  _ <- A.applyAdoption existing extended adoption >>= right
  _ <- Run.up existing (Run.upOptions audit Nothing) extended >>= right
  assert "Next ordinary up did not execute only new migration" . (== 2) =<< scalar server "SELECT toUInt32(count()) AS value FROM default.adoption_early"
  -- The original compiled prefix still supports an inspection-only identical
  -- adoption after newer native history, without claiming that old plan current.
  _ <- A.applyAdoption existing plan adoption >>= right
  _ <- A.resumeAdoption existing plan adoption >>= right
  after <- proxyEvents proxy >>= fromJson :: IO [Value]
  afterStages <- mapM (field "stage") after :: IO [Maybe T.Text]
  assert "Committed identical adoption added events" (length (filter (\stage -> stage `elem` map Just ["initialized", "adoption-started", "adoption-entry", "adoption-completed"]) afterStages) == writes)
  assert "Committed adoption replayed native SQL" (length (filter (== Just "application-sql") afterStages) == 1)
  _ <- I.verify I.Observe bound (I.verifyOptions True) extended >>= right
  putStrLn "adoption early: reviewed two-step baseline; no SQL; immutable attestation; exactly one subsequent native migration; identical committed batch remains read-only after newer history"
