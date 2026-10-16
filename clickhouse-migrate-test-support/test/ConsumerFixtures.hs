{-# LANGUAGE TemplateHaskell #-}

module ConsumerFixtures (consumerFixtureCases) where

import ClickHouseMigrate
import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.Embed (embedComponent)
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Monad (forM, forM_, void)
import Crypto.Hash.SHA256 qualified as SHA
import Data.Aeson (Value)
import Data.Aeson qualified as JSON
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as Encoding
import Data.Text.IO qualified as TextIO
import Numeric (showHex)
import Paths_clickhouse_migrate_test_support (getDataFileName)
import RunnerIntegration (assert, field, fixture, fromJson, provider, right, scalar)
import System.FilePath ((</>))

firstComponent :: MigrationComponent
firstComponent = $(embedComponent "test/fixtures/kansoku/manifest-first.json")

capturedComponent :: MigrationComponent
capturedComponent = $(embedComponent "test/fixtures/kansoku/manifest.json")

fixtureFile :: FilePath -> IO FilePath
fixtureFile name = getDataFileName ("test/fixtures/kansoku/" ++ name)

readJson :: FilePath -> IO Value
readJson name = fixtureFile name >>= BS.readFile >>= either (const (fail "Invalid frozen consumer evidence")) pure . JSON.eitherDecodeStrict'

hex :: BS.ByteString -> T.Text
hex = T.pack . concatMap (\byte -> let rendered = showHex byte "" in replicate (2 - length rendered) '0' ++ rendered) . BS.unpack . SHA.hash

-- Verify frozen byte evidence independently from embedding before server work.
checkCapture :: IO [Value]
checkCapture = do
  evidence <- readJson "provenance.json"
  source <- field "sourceProject" evidence :: IO T.Text
  revision <- field "sourceRevision" evidence :: IO T.Text
  assert "Consumer capture lacks canonical immutable origin" (source == "mori://shinzui/kansoku" && revision == "138d9a316931bbf46781757a29ab6c7fdd90f870")
  runner <- field "runner" evidence
  runnerBytes <- field "fixturePath" runner >>= fixtureFile >>= BS.readFile
  runnerHash <- field "sha256" runner
  assert "Original runner hash changed" (hex runnerBytes == runnerHash)
  files <- field "files" evidence :: IO [Value]
  assert "Captured history incomplete" (length files == 25)
  forM_ files $ \file -> do
    original <- field "original" file >>= fixtureFile >>= BS.readFile
    digest <- field "sha256" file
    assert "Original source hash changed" (hex original == digest)
    steps <- field "steps" file :: IO [Value]
    chunks <- forM steps $ \step -> do
      bytes <- field "file" step >>= fixtureFile >>= BS.readFile
      expected <- field "sha256" step
      start <- field "byteStart" step
      end <- field "byteEndExclusive" step
      assert "Reviewed source range changed" (hex bytes == expected && BS.take (end - start) (BS.drop start original) == bytes)
      pure bytes
    assert "Source ranges lose or duplicate bytes" (BS.concat chunks == original)
  adaptations <- field "nativeAdaptations" evidence :: IO [Value]
  assert "Unreviewed native adaptation count" (length adaptations == 3)
  forM_ adaptations $ \adaptation -> do
    sourceStep <- field "sourceStep" adaptation
    original <- field "file" sourceStep >>= fixtureFile >>= BS.readFile
    expected <- field "sourceStepSha256" adaptation
    assert "Assertion source changed" (hex original == expected)
    native <- field "nativeSteps" adaptation :: IO [Value]
    forM_ native $ \step -> do
      bytes <- field "file" step >>= fixtureFile >>= BS.readFile
      digest <- field "sha256" step
      assert "Reviewed native step changed" (hex bytes == digest)
  pure files

schemaObservation :: Server -> IO Value
schemaObservation server = queryServer server "SELECT table,name,type,default_kind,default_expression FROM system.columns WHERE database='analytics' ORDER BY table,position"

applicationCount :: FaultProxy -> IO Int
applicationCount proxy = do
  rows <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") rows :: IO [Maybe T.Text]
  pure (length (filter (== Just "application-sql") stages))

consumerFixtureCases :: Server -> IO ()
consumerFixtureCases server = do
  files <- checkCapture
  access <- provider
  audit <- right (L.auditContext "consumer fixture reviewer" "explicit reviewed native baseline and assertion translations" ["test/fixtures/kansoku/provenance.json: immutable source/ranges/transformations", "owned isolated server; all predecessor requests drained"])
  let runFresh label plan = withFaultProxy server $ \proxy -> do
        ledger <- newLedgerId
        key <- right (targetKey ("runner-tests/" <> label))
        config <- fixture server label (proxyEndpoint proxy) FirstUse
        result <- Run.up (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan
        report <- case result of
          Right value -> pure value
          Left failure@(R.RunFailure primary _ _) -> do
            TextIO.writeFile (serverLogDirectory server </> T.unpack label ++ ".trace") (T.pack (show failure))
            fail ("consumer native replay: " ++ show primary)
        assert "Fresh replay unexpectedly adopted evidence" (case report of R.RunReport _ _ _ _ _ migrations _ _ -> all (\(R.MigrationSummary _ state _ steps) -> state == R.Applied && all (\(R.StepSummary _ _ step _ _) -> step == R.StepObservedSuccess) steps) migrations)
        pure =<< applicationCount proxy
  first <- right (migrationPlan (firstComponent :| []))
  count <- runFresh "consumer_first" first
  assert "First real multi-statement file was not one complete native migration" (count == 2)
  assert "First source file created no real application object" . (== 1) =<< scalar server "SELECT toUInt32(count()) AS value FROM system.tables WHERE database='analytics' AND name='events_raw'"
  void (queryServer server "DROP DATABASE analytics SYNC")
  putStrLn "consumer first mapping: real immutable 0001 source file, two explicit steps, actual application table"
  complete <- right (migrationPlan (capturedComponent :| []))
  fullCount <- runFresh "consumer_fresh" complete
  assert "Fresh native statement count does not match reviewed manifest" (fullCount == 257)
  freshSchema <- schemaObservation server
  assert "Native assertion cleanup left application scratch tables" . (== 0) =<< scalar server "SELECT toUInt32(count()) AS value FROM system.tables WHERE database='analytics' AND startsWith(name,'__chm_legacy_assert_')"
  void (queryServer server "DROP DATABASE analytics SYNC")
  putStrLn "consumer fresh: all 25 native migrations / 257 reviewed steps applied; assertions checked; scratch tables cleaned"
  -- Independently replay the original source ranges, then store synthetic legacy
  -- filename/time history as the predecessor did. No native ledger exists yet.
  void (queryServer server "CREATE DATABASE analytics")
  void (queryServer server "CREATE TABLE analytics.schema_migrations (filename String, applied_at DateTime64(3,'UTC')) ENGINE=MergeTree ORDER BY filename")
  rows <- readJson "legacy-history.json" >>= fromJson :: IO [Value]
  assert "Legacy evidence row count changed" (length rows == length files)
  forM_ (zip files rows) $ \(file, row) -> do
    steps <- field "steps" file :: IO [Value]
    forM_ steps $ \step -> field "file" step >>= fixtureFile >>= BS.readFile >>= either (const (fail "Invalid captured UTF-8")) pure . Encoding.decodeUtf8' >>= void . queryServer server
    filename <- field "filename" row :: IO T.Text
    applied <- field "appliedAt" row :: IO T.Text
    -- Values come from the checked-in synthetic fixture, not external input.
    assert "Unexpected synthetic evidence spelling" (not (T.any (== '\'') filename) && not (T.any (== '\'') applied))
    void (queryServer server ("INSERT INTO analytics.schema_migrations VALUES ('" <> filename <> "', parseDateTime64BestEffort('" <> applied <> "'))"))
  legacySchema <- queryServer server "SELECT table,name,type,default_kind,default_expression FROM system.columns WHERE database='analytics' AND table!='schema_migrations' ORDER BY table,position"
  assert "Fresh native and original legacy schema observations differ" (freshSchema == legacySchema)
  observedRows <- queryServer server "SELECT filename,toString(applied_at) AS appliedAt FROM analytics.schema_migrations ORDER BY filename" >>= fromJson :: IO [Value]
  assert "Legacy reader lost filename/time rows" (length observedRows == 25)
  provenanceBytes <- fixtureFile "provenance.json" >>= BS.readFile
  let evidenceReference = "test/fixtures/kansoku/provenance.json#sha256:" <> hex provenanceBytes
  withFaultProxy server $ \proxy -> do
    ledger <- newLedgerId
    let label = "consumer_adopt"
    key <- right (targetKey ("runner-tests/" <> label))
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    quiet <- right (L.attestQuiescence key audit)
    legacy <- forM observedRows $ \row -> do
      filename <- field "filename" row
      applied <- field "appliedAt" row
      right (A.legacyRow filename applied Nothing)
    let definitions = NE.toList (componentMigrations (NE.head (inspectPlan complete)))
    mappings <- forM (zip observedRows definitions) $ \(row, migration) -> do
      filename <- field "filename" row
      right (A.attestedMapping filename "kansoku" (migrationNameText (migrationIdName (migrationId migration))) (migrationChecksumHex (migrationChecksum migration)) ["test/fixtures/kansoku/provenance.json: complete file mapping and author obligations"])
    observation <- I.status I.Observe config complete >>= right
    legacyRows <- maybe (fail "Empty legacy evidence") pure (NE.nonEmpty legacy)
    mappedRows <- maybe (fail "Empty legacy mapping") pure (NE.nonEmpty mappings)
    request <- right (A.adoptionRequest key (L.ExpectAbsent key) (Just (L.authorizeInitialization key ledger audit)) quiet audit "mori://shinzui/kansoku" evidenceReference legacyRows mappedRows)
    adoption <- right (A.planAdoption complete observation request)
    _ <- A.applyAdoption (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) complete adoption >>= right
    assert "Consumer adoption executed application SQL" . (== 0) =<< applicationCount proxy
    _ <- I.verify I.Observe bound (I.verifyOptions True) complete >>= right
    let originalMigrations = NE.toList (componentMigrations (NE.head (inspectPlan complete)))
    -- Rebuild through public smart constructors: embedding remains the source of
    -- exact original SQL bytes and names, with one explicit appended migration.
    authored <- forM originalMigrations $ \migration -> do
      steps <- forM (NE.toList (migrationSteps migration)) $ \step -> right (sqlStep (stepNameText (stepViewName step)) (stepSql step))
      nonempty <- maybe (fail "Empty captured migration") pure (NE.nonEmpty steps)
      right (sqlMigration (migrationNameText (migrationIdName (migrationId migration))) nonempty)
    nextStep <- right (sqlStep "add-probe" "ALTER TABLE analytics.events_raw ADD COLUMN clickhouse_migrate_probe UInt8")
    next <- right (sqlMigration "0026_native_probe" (nextStep :| []))
    nonempty <- maybe (fail "Empty captured component") pure (NE.nonEmpty (authored ++ [next]))
    extended <- right (migrationComponent "kansoku" Set.empty nonempty) >>= \component -> right (migrationPlan (component :| []))
    _ <- Run.up (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit Nothing) extended >>= right
    assert "Consumer cutover replayed accepted legacy work" . (== 1) =<< applicationCount proxy
    _ <- I.verify I.Observe bound (I.verifyOptions True) extended >>= right
    assert "Subsequent native migration effect missing" . (== 1) =<< scalar server "SELECT toUInt32(count()) AS value FROM system.columns WHERE database='analytics' AND table='events_raw' AND name='clickhouse_migrate_probe'"
    putStrLn "consumer existing history: original 253 statements replayed independently; schema observations match; 25 filename-only rows adopted without SQL; one subsequent native migration observed"
