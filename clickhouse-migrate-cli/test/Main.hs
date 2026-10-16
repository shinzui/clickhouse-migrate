module Main (main) where

import ClickHouseMigrate hiding (history, up)
import ClickHouseMigrate.CLI
import ClickHouseMigrate.CLI.AdoptionFile
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Report qualified as R
import Control.Monad (forM_, unless)
import Data.Aeson qualified as JSON
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Paths_clickhouse_migrate_cli (getDataFileName)

assert :: String -> Bool -> IO ()
assert label value = unless value (fail label)

right :: (Show e) => Either e a -> a
right = either (error . show) id

uuid :: Text.Text
uuid = "00000000-0000-0000-0000-000000000001"

positionText :: Text.Text
positionText = "chm1:" <> uuid <> ":5:" <> uuid

receiptText :: Text.Text
receiptText = "chm-receipt1:74657374:" <> uuid <> ":6:" <> uuid <> ":" <> Text.replicate 64 "a" <> ":append-6"

main :: IO ()
main = do
  let step = right (sqlStep "create" "CREATE TABLE default.secret_fixture (id UInt8) ENGINE=Memory")
      migration = right (sqlMigration "one" (step :| []))
      component = right (migrationComponent "app" Set.empty (migration :| []))
      plan = right (migrationPlan (component :| []))
      key = right (targetKey "test")
      audit = right (L.auditContext "fixture actor" "fixture reason" ["fixture/drain"])
      quiet = right (L.attestQuiescence key audit)
      ledger = right (ledgerId uuid)
      authorization = Just (L.authorizeInitialization key ledger audit)
      decode = decodeAdoptionInput key (L.ExpectAbsent key) authorization quiet audit
  offline <- handleCommand (error "Offline plan forced configuration") plan PlanCommand
  assert "offline plan missing" (case offline of CommandResult "plan" (Right (PlanReport [_])) -> True; _ -> False)
  assert "offline plan leaked SQL" (not ("secret_fixture" `Text.isInfixOf` Encoding.decodeUtf8 (renderJson offline)))
  let auditArgs = ["--expect-target", "test", "--actor", "fixture actor", "--reason", "fixture reason"]
      recoveryArgs = auditArgs ++ ["--expect-position", Text.unpack positionText, "--attempt", Text.unpack uuid, "--evidence", "fixture/drain", "--quiescent", "--pending-append", Text.unpack receiptText]
      selected = ["--step-attempt", Text.unpack uuid, "--step", "insert", "--query-id", "query-2"]
      adoptionArgs = auditArgs ++ ["--expect-absent", "--initialize-ledger", Text.unpack uuid, "--evidence", "fixture/drain", "--quiescent", "--request", "input.json"]
  forM_ ([["plan", "--json"], ["status"], ["history", "--guarded"], ["verify", "--require-current"], ["up"] ++ auditArgs] ++ [["repair", op] ++ recoveryArgs ++ if op `elem` ["retry-step", "accept-step"] then selected else [] | op <- ["resume", "retry-step", "accept-step", "finalize"]] ++ [["adopt", op] ++ adoptionArgs | op <- ["plan", "apply", "resume"]]) $ \args -> assert ("Valid parser case rejected: " ++ show args) (case parseInvocation args of Right _ -> True; _ -> False)
  forM_ [[], ["reset"], ["up", "--force"], ["repair", "accept-step"] ++ recoveryArgs, ["repair", "resume"] ++ filter (/= "--quiescent") recoveryArgs, ["up"] ++ auditArgs ++ ["--actor", "secret-password"], ["adopt", "apply"] ++ auditArgs ++ ["--expect-absent", "--quiescent", "--evidence", "fixture/drain", "--request", "a.json"], ["status", "--initialize-ledger", Text.unpack uuid]] $ \args -> assert "Malformed parser input accepted" (case parseInvocation args of Left ArgumentsRejected -> True; _ -> False)
  assert "Help missing" (case parseInvocation ["verify", "--help"] of Left (HelpRequested text) -> "schema equality" `Text.isInfixOf` text; _ -> False)
  let noTarget = commandEnvironment Nothing Nothing E.quietEvents E.redactedDiagnostics AdministrativeCommands
      config = targetConfig key (right (directEndpoint "http://127.0.0.1:1")) (right (serverId uuid)) (right (ledgerNamespace "fixture_history")) FirstUse (right (basicCredentials "default" "secret-password")) defaultHttpLimits
      noProvider = commandEnvironment (Just config) Nothing E.quietEvents E.redactedDiagnostics AdministrativeCommands
      forbidden = commandEnvironment Nothing Nothing E.quietEvents E.redactedDiagnostics ReadOnlyCommands
      up = UpCommand (UpInput key (AuditInput "actor" "reason" []) Nothing False)
  forM_ [(noTarget, StatusCommand False, MissingTargetConfiguration), (noProvider, up, MissingExclusiveAccess), (noProvider, StatusCommand True, MissingExclusiveAccess), (forbidden, up, CommandNotAllowed)] $ \(env, command, expected) -> do
    result <- handleCommand env plan command
    assert "Preflight error wrong" (case result of CommandResult _ (Left (CommandRejected actual)) -> actual == expected; _ -> False)
  forM_ [("{", InvalidJsonInput), ("{\"schemaVersion\":1,\"schemaVersion\":1}", DuplicateJsonKey), ("{\"schemaVersion\":1,\"schema\\u0056ersion\":1}", DuplicateJsonKey), ("{\"schemaVersion\":2}", UnsupportedInputVersion), ("{\"schemaVersion\":1,\"force\":true}", InvalidAdoptionInput), ("{} {}", InvalidJsonInput)] $ \(bytes, expected) -> assert "Unsafe adoption JSON accepted" (case decode bytes of Left actual -> actual == expected; _ -> False)
  forM_ goldenCases $ \(name, result) -> do
    path <- getDataFileName ("test/golden/" ++ name ++ ".json")
    bytes <- BS.readFile path
    let actual = JSON.eitherDecodeStrict' (renderJson result) :: Either String JSON.Value
        expected = JSON.eitherDecodeStrict' bytes :: Either String JSON.Value
    assert ("JSON golden mismatch: " ++ name) (actual == expected && either (const False) (const True) expected)
    forM_ [renderJson result, Encoding.encodeUtf8 (renderText result)] $ \rendered -> assert "Sensitive SQL or credentials escaped" (not (BS.isInfixOf "SQL_SECRET_MARKER" rendered) && not (BS.isInfixOf "secret-password" rendered))
  putStrLn "CLI: offline environment unforced; all commands parsed; fail-closed policy/access; strict adoption decoding; four schemaVersion 1 golden results"

goldenCases :: [(String, CommandResult)]
goldenCases = [("malformed", CommandResult "parse" (Left (CommandRejected InvalidArguments))), ("partial", CommandResult "up" (Left (RunFailed (R.RunFailure (R.SqlFailed reference query L.UncertainSubmission problem) run [R.AccessCleanup Access.AccessReleaseFailed])))), ("delayed-ledger", CommandResult "up" (Left (RunFailed (R.RunFailure (R.LedgerRequestFailed L.UncertainSubmission problem (Just receipt)) run [R.RecordingError (R.LedgerFailed L.OutstandingRequests)])))), ("accepted", CommandResult "status" (Right (StatusReport (R.InspectionReport history [accepted] []))))]
  where
    identity = right (ledgerId uuid)
    attempt = right (L.parseAttemptId uuid)
    query = right (queryId "query-2")
    receipt = right (L.parseAppendReceipt receiptText)
    position = right (L.parseLedgerPosition positionText)
    key = right (targetKey "test")
    access = Access.exclusiveAccessDescription (right (Access.externallySerialized "fixture" "owned target" 1000 (const (fail "Golden provider must never acquire")) (const (pure ())) (const (pure False))))
    definition = R.DefinitionSummary 0 0 "app" [] "one" "migration-hash" [("create", "create-hash"), ("insert", "insert-hash")]
    reference = R.StepReference "app" "one" "insert" "migration-hash" "insert-hash"
    selected = R.StepAttempt attempt "insert" query
    create = R.StepSummary "create" "create-hash" R.StepObservedSuccess (Just (R.StepAttempt attempt "create" (right (queryId "query-1")))) Nothing
    unresolved = R.MigrationSummary definition R.InProgress (Just attempt) [create, R.StepSummary "insert" "insert-hash" R.StepUncertain (Just selected) Nothing]
    accepted = R.MigrationSummary definition R.InProgress (Just attempt) [create, R.StepSummary "insert" "insert-hash" R.StepAccepted (Just selected) (Just (R.EvidenceSummary L.OperatorAttestation ["fixture/drain"]))]
    history = R.HistoryReport key Nothing (R.LedgerInitializedAt identity) (Just position) (R.GuardedObservation access) [] [unresolved] True
    problem = L.TransportError L.ResponseInterrupted Nothing Nothing
    run = R.RunReport "run-fixture" key access True history [unresolved] [R.SqlObservation reference query (R.QueryRejected L.UncertainSubmission problem)] (Just identity)
