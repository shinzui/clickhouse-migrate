module SurvivingWork (survivingWorkCases, runnerChild) where

import ClickHouseMigrate
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.ExclusiveAccess qualified as Access
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.ExclusiveAccess (hostLocalExclusiveAccess)
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (SomeAsyncException, finally, fromException)
import Control.Monad (forM_, void)
import Data.Aeson (Value)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as Encoding
import RunnerIntegration (assert, field, fixture, fromJson, provider, right, scalar)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (createProcess, proc, terminateProcess, waitForProcess)
import System.Timeout (timeout)

mutationPlan :: T.Text -> IO MigrationPlan
mutationPlan label = do
  metadata <- right (sqlStep "metadata" (Encoding.encodeUtf8 ("ALTER TABLE default." <> label <> " ADD COLUMN note String")))
  update <- right (sqlStep "update" (Encoding.encodeUtf8 ("ALTER TABLE default." <> label <> " UPDATE value=7 WHERE id=1")))
  migration <- right (sqlMigration "one" (metadata :| [update]))
  component <- right (migrationComponent "app" Set.empty (migration :| []))
  right (migrationPlan (component :| []))

auditContext :: IO L.AuditContext
auditContext = right (L.auditContext "surviving-work fixture" "owned isolated server; explicit administration" ["parent retains exclusion until client gone and mutation effects plus all requests drained"])

runnerChild :: String -> String -> String -> String -> String -> IO ()
runnerChild endpoint identity labelText ledgerText root = do
  let label = T.pack labelText
  key <- right (targetKey ("runner-tests/" <> label))
  ledger <- right (ledgerId (T.pack ledgerText))
  config <- targetConfig key <$> right (directEndpoint (T.pack endpoint)) <*> right (serverId (T.pack identity)) <*> right (ledgerNamespace (label <> "_history")) <*> pure FirstUse <*> right (basicCredentials "default" "test-password") <*> pure defaultHttpLimits
  access <- hostLocalExclusiveAccess root 1000000 Nothing >>= right
  plan <- mutationPlan label
  audit <- auditContext
  result <- Run.up (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan
  fail ("Controlled client returned before kill: " ++ show result)

waitUntil :: String -> IO Bool -> IO ()
waitUntil label predicate = do
  finished <- timeout 8000000 loop
  assert label (finished == Just ())
  where
    loop = predicate >>= \done -> if done then pure () else threadDelay 20000 >> loop

survivingWorkCases :: Server -> IO ()
survivingWorkCases server = do
  forM_ [False, True] $ \asyncCancellation -> withFaultProxy server $ \proxy -> do
    let label = if asyncCancellation then "async_survivor" else "killed_survivor"
        root = serverLogDirectory server </> T.unpack label ++ "-locks"
    ledger <- newLedgerId
    key <- right (targetKey ("runner-tests/" <> label))
    audit <- auditContext
    plan <- mutationPlan label
    config <- fixture server label (proxyEndpoint proxy) FirstUse
    bound <- fixture server label (proxyEndpoint proxy) (ExistingLedger ledger)
    void (queryServer server ("CREATE TABLE default." <> label <> " (id UInt8, value UInt8) ENGINE=MergeTree ORDER BY id"))
    void (queryServer server ("INSERT INTO default." <> label <> " SETTINGS async_insert=0 VALUES (1,0)"))
    void (queryServer server ("SYSTEM STOP MERGES default." <> label))
    let activeMutation = (> 0) <$> scalar server ("SELECT toUInt32(count()) AS value FROM system.mutations WHERE database='default' AND table='" <> label <> "' AND NOT is_done")
        startMerges = void (queryServer server ("SYSTEM START MERGES default." <> label))
    ( do
        stopOnce <-
          if asyncCancellation
            then do
              access <- hostLocalExclusiveAccess root 1000000 Nothing >>= right
              done <- newEmptyMVar
              thread <- forkFinally (Run.up (Run.mutationContext config access E.quietEvents E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan) (putMVar done)
              pure $ do
                killThread thread
                result <- takeMVar done
                assert
                  "Async cancellation became a normal RunFailure"
                  ( case result of
                      Left exception -> case fromException exception :: Maybe SomeAsyncException of
                        Just _ -> True
                        _ -> False
                      _ -> False
                  )
            else do
              binary <- getExecutablePath
              rows <- queryServer server "SELECT toString(serverUUID()) AS server_id" >>= fromJson :: IO [Value]
              identity <- case rows of [row] -> field "server_id" row; _ -> fail "Missing server UUID"
              (_, _, _, process) <- createProcess (proc binary ["runner-child", T.unpack (proxyEndpoint proxy), T.unpack identity, T.unpack label, T.unpack (ledgerIdText ledger), root])
              pure $ do
                terminateProcess process
                exitCode <- waitForProcess process
                assert "Killed client reported success" (exitCode /= ExitSuccess)
        stopped <- newIORef False
        let stopClient = do
              already <- atomicModifyIORef' stopped (\done -> (True, done))
              if already then pure () else stopOnce
        ( do
            waitUntil "Mutation did not start before client cancellation" activeMutation
            observation <- I.status I.Observe bound plan >>= right
            let R.InspectionReport (R.HistoryReport _ _ _ position _ _ _ _) migrations _ = observation
            (expected, attempt, selected) <- case (position, migrations) of
              (Just expected, [R.MigrationSummary _ R.InProgress (Just attempt) [R.StepSummary _ _ R.StepObservedSuccess _ _, R.StepSummary "update" _ R.StepUncertain (Just selected) _]]) -> pure (expected, attempt, selected)
              _ -> fail ("Missing active mutation intent " ++ show observation)
            let R.StepAttempt _ _ query = selected
                activeQuery = (> 0) <$> scalar server ("SELECT toUInt32(count()) AS value FROM system.processes WHERE query_id='" <> queryIdText query <> "'")
            assert "Controlled mutation query not active" =<< activeQuery
            -- Negative test: deliberately supply false external evidence and a test
            -- provider that allows overlap. Positive process evidence must still win.
            broken <- provider
            falseQuiet <- right (L.attestQuiescence key audit)
            falseEvidence <- right (Repair.recoveryEvidence audit falseQuiet [])
            unsafe <- right (Repair.acceptStepRequest expected attempt selected falseEvidence)
            rejected <- Repair.repair (Run.mutationContext bound broken E.quietEvents E.redactedDiagnostics) plan unsafe
            assert "Recovery accepted a positively active predecessor" (case rejected of Left (R.RunFailure (R.PriorQueriesActive queries) _ _) -> query `elem` queries; _ -> False)
            stopClient
            assert "Server mutation did not survive client shutdown" =<< activeMutation
            blocked <- hostLocalExclusiveAccess root 1000000 Nothing >>= right
            ordinary <- Run.up (Run.mutationContext bound blocked E.quietEvents E.redactedDiagnostics) (Run.upOptions audit Nothing) plan
            assert "OS unlock was mistaken for server quiescence" (case ordinary of Left (R.RunFailure (R.AccessFailed Access.PredecessorQuiescenceRequired) _ _) -> True; _ -> False)
            startMerges
            waitUntil "Surviving mutation never committed" ((== 7) <$> scalar server ("SELECT toUInt32(value) AS value FROM default." <> label <> " WHERE id=1"))
            waitUntil "Original query failed to drain" (not <$> activeQuery)
            waitUntil "Background mutation failed to drain" (not <$> activeMutation)
            quiet <- right (L.attestQuiescence key audit)
            access <- hostLocalExclusiveAccess root 1000000 (Just quiet) >>= right
            evidence <- right (Repair.recoveryEvidence audit quiet [])
            accepted <- right (Repair.acceptStepRequest expected attempt selected evidence) >>= Repair.repair (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan >>= right
            (after, current) <- case accepted of R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just after) _ _ _ _) [R.MigrationSummary _ _ (Just current) _] _ _ -> pure (after, current); _ -> fail "Missing accepted attempt"
            final <- right (Repair.finalizeRequest after current evidence)
            _ <- Repair.repair (Run.mutationContext bound access E.quietEvents E.redactedDiagnostics) plan final >>= right
            _ <- I.verify I.Observe bound (I.verifyOptions True) plan >>= right
            requests <- proxyEvents proxy >>= fromJson :: IO [Value]
            stages <- mapM (field "stage") requests :: IO [Maybe T.Text]
            assert "Killed-client recovery replayed application SQL" (length (filter (== Just "application-sql") stages) == 2)
            putStrLn ("surviving server mutation: async cancellation=" ++ show asyncCancellation ++ "; active-query refusal, host marker, external drain, accept/finalize without replay")
          )
          `finally` stopClient
      )
      `finally` startMerges
