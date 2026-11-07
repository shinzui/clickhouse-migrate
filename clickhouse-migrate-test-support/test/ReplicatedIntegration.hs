module ReplicatedIntegration (replicatedCases) where

import ClickHouseMigrate
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.Server
import Control.Monad (forM, forM_, void, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as JSON
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as Encoding
import RunnerIntegration (assert, field, provider, right)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

rowsAt :: Server -> Int -> T.Text -> IO [Value]
rowsAt server replica sql = do
  result <- queryReplica server replica sql
  httpStatus <- field "status" result :: IO Int
  body <- field "body" result
  assert ("Independent read failed: " ++ T.unpack body) (httpStatus == 200)
  mapM (right . JSON.eitherDecodeStrict' . Encoding.encodeUtf8) (filter (not . T.null) (T.lines body))

replicatedCases :: Server -> IO ()
replicatedCases server = do
  replicas <- forM [0, 1] $ \replica -> do
    rows <- rowsAt server replica "SELECT toString(serverUUID()) AS id"
    case rows of [row] -> field "id" row >>= right . serverId; _ -> fail "Missing replica identity"
  ids <- case replicas of a : b : [] -> pure (a :| [b]); _ -> fail "Missing replicas"
  cluster <- right (clusterName "fixture")
  endpoint <- right (directEndpoint (serverEndpoint server))
  credentials <- right (basicCredentials "app" "test-password")
  access <- provider
  audit <- right (L.auditContext "replicated fixture" "owned fixture; predecessor requests drained" ["fixture/controlled-drain"])
  let configAt key namespace binding ep = right (replicatedTargetConfig key ep cluster ids namespace binding credentials defaultHttpLimits)
      configure name binding = do
        key <- right (targetKey ("replicated/" <> name))
        namespace <- right (ledgerNamespace ("fixture_" <> name))
        configAt key namespace binding endpoint
      createNamespace name = void (queryServer server ("CREATE DATABASE fixture_" <> name <> " ON CLUSTER fixture ENGINE=Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')"))
      context config sink = Run.mutationContext config access sink E.redactedDiagnostics
      observe config plan = I.status I.Observe config plan >>= right
  -- An actual application-mounted executable, through the alternating endpoint.
  example <- getEnv "CLICKHOUSE_MIGRATE_EXAMPLE"
  inherited <- getEnvironment
  exampleLedger <- newLedgerId
  let exampleKey = "replicated/example"
      configured = [("CHM_CLUSTER", "fixture"), ("CHM_REPLICA_IDS", T.unpack (T.intercalate "," (map serverIdText replicas))), ("CHM_TARGET", exampleKey), ("CHM_ENDPOINT", T.unpack (serverEndpoint server)), ("CHM_USER", "app"), ("CHM_PASSWORD", "test-password"), ("CHM_LEDGER_DATABASE", "fixture_ledger"), ("CHM_LOCK_ROOT", serverLogDirectory server </> "example-lock")]
      run extra args = do
        let values = extra ++ configured
            env = values ++ filter (\(name, _) -> name `notElem` map fst values) inherited
        (exit, output, errors) <- readCreateProcessWithExitCode ((proc example ("--replicated-example" : args)) {env = Just env}) ""
        assert ("Replicated mounted example failed: " ++ output ++ errors) (exit == ExitSuccess)
        value <- right (JSON.eitherDecodeStrict' (Encoding.encodeUtf8 (T.pack output)) :: Either String Value)
        pure value
      upArgs = ["up", "--json", "--expect-target", exampleKey, "--actor", "fixture", "--reason", "owned predecessor drained", "--evidence", "fixture/drain", "--quiescent"]
      bound = [("CHM_LEDGER_ID", T.unpack (ledgerIdText exampleLedger))]
  offline <- run [] ["plan", "--json"]
  components <- field "result" offline >>= field "components" :: IO [Value]
  authored <- concat <$> mapM (field "migrations") components :: IO [Value]
  expectedDigests <- mapM (\migration -> field "checksums" migration >>= field "sha256-v2") authored :: IO [T.Text]
  pending <- run [] ["status", "--json"]
  summaries <- field "result" pending >>= field "report" >>= field "migrations" :: IO [Value]
  pendingDigests <- mapM (\migration -> field "definition" migration >>= field "checksum") summaries :: IO [T.Text]
  assert "Empty replicated ledger status used v1 pending checksums" (pendingDigests == expectedDigests)
  void (run [] (upArgs ++ ["--initialize-ledger", T.unpack (ledgerIdText exampleLedger)]))
  before <- rowsAt server 0 "SELECT event FROM fixture_ledger.events ORDER BY sequence"
  void (run bound upArgs)
  after <- rowsAt server 1 "SELECT event FROM fixture_ledger.events ORDER BY sequence"
  assert "Repeated up appended history or replicas diverged" (before == after)
  statusJson <- run bound ["status", "--json"]
  format <- field "result" statusJson >>= field "report" >>= field "observation" >>= field "checksumFormat" :: IO T.Text
  assert "Replicated status is not v2" (format == "sha256-v2")
  void (run bound ["history", "--json"])
  void (run bound ["verify", "--require-current", "--json"])
  forM_ ["chm_replicated_catalog", "chm_replicated_events"] $ \table -> do
    a <- rowsAt server 0 ("SELECT * FROM fixture_app." <> table)
    b <- rowsAt server 1 ("SELECT * FROM fixture_app." <> table)
    assert "Acknowledged application data differs between replicas" (a == b && not (null a))
  forM_ [0, 1] $ \replica -> do
    stopReplica server replica
    startReplica server replica
    durable <- rowsAt server replica "SELECT event FROM fixture_ledger.events ORDER BY sequence"
    assert "Acknowledged ledger lost after restart" (durable == before)
  putStrLn "replicated: mounted up/status/history/verify; v2; no-op reapply; identical data/history; both process restarts"
  -- Missing, Atomic, malformed and foreign-format ledgers fail closed.
  minimal <- makePlan [("one", "CREATE TABLE fixture_app.shape_probe (x UInt8) ENGINE=ReplicatedMergeTree ORDER BY x")]
  missing <- configure "missing" FirstUse
  absent <- I.history I.Observe missing
  assert "Missing replicated ledger database accepted" (case absent of Left (R.InspectionFailure (R.LedgerFailed L.LedgerDatabaseMissing) _ _) -> True; _ -> False)
  void (queryServer server "CREATE DATABASE fixture_atomic ON CLUSTER fixture ENGINE=Atomic")
  atomic <- configure "atomic" FirstUse
  rejected <- I.history I.Observe atomic
  assert "Atomic replicated ledger accepted" (case rejected of Left (R.InspectionFailure (R.LedgerFailed L.InvalidLedgerSchema) _ _) -> True; _ -> False)
  createNamespace "badshape"
  void (queryServer server "CREATE TABLE fixture_badshape.events (sequence UInt64, event_id UUID, ledger_id UUID, event String) ENGINE=Memory")
  badshape <- configure "badshape" FirstUse
  malformed <- I.history I.Observe badshape
  assert "Wrong ledger engine accepted" (case malformed of Left (R.InspectionFailure (R.LedgerFailed L.InvalidLedgerSchema) _ _) -> True; _ -> False)
  createNamespace "foreign"
  void (queryServer server "CREATE TABLE fixture_foreign.events (sequence UInt64, event_id UUID, ledger_id UUID, event String) ENGINE=ReplicatedMergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'")
  originalInitialization <- case before of row : _ -> field "event" row; _ -> fail "Missing initialization for foreign-format test"
  decodedInitialization <- right (JSON.eitherDecodeStrict' (Encoding.encodeUtf8 originalInitialization) :: Either String Value)
  eventId <- field "eventId" decodedInitialization :: IO T.Text
  oldPolicy <- field "body" decodedInitialization >>= field "policy"
  let foreignEvent = T.replace "replicated/example" "replicated/foreign" (T.replace oldPolicy (Encoding.decodeUtf8 completionPolicy) (T.replace "sha256-v2" "sha256-v1" originalInitialization))
      foreignRow = object ["sequence" .= (1 :: Int), "event_id" .= eventId, "ledger_id" .= ledgerIdText exampleLedger, "event" .= foreignEvent]
  void (queryServer server ("INSERT INTO fixture_foreign.events FORMAT JSONEachRow\n" <> Encoding.decodeUtf8 (Lazy.toStrict (JSON.encode foreignRow))))
  forM_ [0, 1] $ \replica -> void (rowsAt server replica "SYSTEM SYNC REPLICA fixture_foreign.events")
  foreignConfig <- configure "foreign" FirstUse
  foreignFormat <- I.history I.Observe foreignConfig
  assert "Replicated target accepted a v1 ledger" (case foreignFormat of Left (R.InspectionFailure (R.LedgerFailed L.UnsupportedLedgerVersion) _ _) -> True; _ -> False)
  identityResult <- queryReplica server 0 "SELECT 1"
  directEndpointText <- field "endpoint" identityResult
  directEndpointValue <- right (directEndpoint directEndpointText)
  key <- right (targetKey "replicated/membership")
  namespace <- right (ledgerNamespace "fixture_ledger")
  wrongCount <- right (replicatedTargetConfig key directEndpointValue cluster (NE.head ids :| []) namespace FirstUse credentials defaultHttpLimits)
  wrong <- I.history I.Observe wrongCount
  assert "Wrong membership count accepted" (case wrong of Left (R.InspectionFailure (R.TargetFailed (L.TransportError L.ReplicaSetMismatch _ _)) _ _) -> True; _ -> False)
  -- Database creation is rejected before even initializing the pending ledger.
  createNamespace "database_step"
  databaseConfig <- configure "database_step" FirstUse
  databasePlan <- makePlan [("one", "/* before header */ CREATE DATABASE forbidden_fixture_database")]
  databaseLedger <- newLedgerId
  databaseResult <- Run.up (context databaseConfig E.quietEvents) (Run.upOptions audit (Just (L.authorizeInitialization (configuredTargetKey databaseConfig) databaseLedger audit))) databasePlan
  assert "CREATE DATABASE reached replicated runner" (case databaseResult of Left (R.RunFailure (R.DatabaseCreationOnReplicatedTarget _) _ _) -> True; _ -> False)
  objects <- rowsAt server 0 "SELECT name FROM system.tables WHERE database='fixture_database_step'"
  assert "Preflight initialized a ledger before rejecting database creation" (null objects)
  -- Plain MergeTree reaches the server and is classified with Code 56.
  createNamespace "plain"
  plainConfig <- configure "plain" FirstUse
  plainLedger <- newLedgerId
  plainPlan <- makePlan [("one", "CREATE TABLE fixture_app.plain (x UInt8) ENGINE=MergeTree ORDER BY x")]
  plain <- Run.up (context plainConfig E.quietEvents) (Run.upOptions audit (Just (L.authorizeInitialization (configuredTargetKey plainConfig) plainLedger audit))) plainPlan
  assert "Code 56 was not an observed SQL failure" (case plain of Left (R.RunFailure (R.SqlFailed _ _ L.ObservedFailure (L.TransportError _ _ (Just 56))) _ _) -> True; _ -> False)
  putStrLn "replicated: missing/Atomic/wrong ledger shapes, membership mismatch and pending CREATE DATABASE rejected; plain MergeTree observed Code 56"
  -- Stop the other replica only after intent is acknowledged, so the actual DDL
  -- failure and the dependent ledger uncertainty are both observable.
  createNamespace "failure"
  first <- configure "failure" FirstUse
  firstDirect <- configAt (configuredTargetKey first) (either (error . show) id (ledgerNamespace "fixture_failure")) FirstUse directEndpointValue
  ledger <- newLedgerId
  let sink (E.RunEvent phase _ _ _ _ _ _) = when (phase == E.BeforeSql) (stopReplica server 1)
  failed <- timeout 65000000 (Run.up (context firstDirect sink) (Run.upOptions audit (Just (L.authorizeInitialization (configuredTargetKey first) ledger audit))) minimal)
  assert "Missing replica did not fail within bounded request waits" (case failed of Just (Left (R.RunFailure (R.SqlFailed _ _ L.ObservedFailure _) _ _)) -> True; _ -> False)
  startReplica server 1
  void (rowsAt server 1 "SYSTEM SYNC DATABASE REPLICA fixture_app")
  forM_ [0, 1] $ \replica -> void (rowsAt server replica "SYSTEM SYNC REPLICA fixture_failure.events")
  boundConfig <- configAt (configuredTargetKey first) (either (error . show) id (ledgerNamespace "fixture_failure")) (ExistingLedger ledger) directEndpointValue
  R.InspectionReport (R.HistoryReport _ _ _ (Just position) _ _ _ _) [R.MigrationSummary _ _ (Just attempt) [R.StepSummary _ _ state (Just selected) _]] _ <- observe boundConfig minimal
  assert "Failed DDL was recorded as succeeded" (state `elem` [R.StepUncertain, R.StepObservedFailure])
  quiet <- right (L.attestQuiescence (configuredTargetKey first) audit)
  evidence <- right (Repair.recoveryEvidence audit quiet [])
  accept <- right (Repair.acceptStepRequest position attempt selected evidence)
  void (Repair.repair (context boundConfig E.quietEvents) minimal accept >>= right)
  R.InspectionReport (R.HistoryReport _ _ _ (Just next) _ _ _ _) [R.MigrationSummary _ _ (Just nextAttempt) _] _ <- observe boundConfig minimal
  finalize <- right (Repair.finalizeRequest next nextAttempt evidence)
  void (Repair.repair (context boundConfig E.quietEvents) minimal finalize >>= right)
  void (I.verify I.Observe boundConfig (I.verifyOptions True) minimal >>= right)
  putStrLn "replicated: stopped replica produced server failure and uncertain ledger append; restart, explicit accept/finalize and verify succeeded"

makePlan :: [(T.Text, BS.ByteString)] -> IO MigrationPlan
makePlan sources = do
  migrations <- forM sources $ \(name, sql) -> do
    step <- right (sqlStep "execute" sql)
    right (sqlMigration name (step :| []))
  component <- right (migrationComponentFromList "replicated" Set.empty migrations)
  right (migrationPlan (component :| []))
