-- | One scoped administrative operation. No live capability is public.
module ClickHouseMigrate.Internal.Execution where

import ClickHouseMigrate.Event qualified as Event
import ClickHouseMigrate.Internal.EventTypes (DiagnosticPolicy (..), SqlDiagnostic (..))
import ClickHouseMigrate.Internal.Exclusive (checkGuard, guardDescription, withExclusive)
import ClickHouseMigrate.Internal.ExclusiveTypes (AccessDescription (..), AccessResult (..), ExclusiveAccess (..), Guard)
import ClickHouseMigrate.Internal.Identity (diagnosticTime, freshUuid)
import ClickHouseMigrate.Internal.LedgerCodec (contextFor, definitions)
import ClickHouseMigrate.Internal.LedgerStore qualified as Store
import ClickHouseMigrate.Internal.LedgerTypes qualified as L
import ClickHouseMigrate.Internal.Preflight (preflight)
import ClickHouseMigrate.Internal.Reporting qualified as Reporting
import ClickHouseMigrate.Internal.RuntimeTypes
import ClickHouseMigrate.Internal.ServerPolicy (TargetCheckError (..), withTransportChecked)
import ClickHouseMigrate.Internal.TargetTypes qualified as T
import ClickHouseMigrate.Internal.Transport qualified as Transport
import ClickHouseMigrate.Ledger qualified as Ledger
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target (queryIdText)
import Control.Exception (Exception, SomeAsyncException, SomeException, fromException, mask, throwIO, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text

-- Configuration, audit, plan, scope, transport, store, run ID, latest ack and
-- secondary observations are owned by one synchronous command invocation.
data Runtime = Runtime !MutationContext !L.AuditContext !Plan.MigrationPlan !Guard !Transport.Transport !Store.LedgerStore !Text !(IORef R.RunReport) !(IORef [R.SecondaryError])

data RunAbort = RunAbort !R.RunError deriving stock (Show)

instance Exception RunAbort

abort :: R.RunError -> IO a
abort = throwIO . RunAbort

callStore :: IO a -> IO a
callStore action = Store.storeResult action >>= either (abort . Reporting.storeError) pure

isAsync :: SomeException -> Bool
isAsync exception = isJust (fromException exception :: Maybe SomeAsyncException)

tryAction :: IO a -> IO (Either R.RunError a)
tryAction action =
  try @SomeException action >>= \case
    Left exception | isAsync exception -> throwIO exception
    Left exception -> pure (Left (case fromException exception of Just (RunAbort failure) -> failure; _ -> R.UnexpectedRuntimeFailure))
    Right value -> pure (Right value)

withRuntime :: MutationContext -> L.AuditContext -> Maybe L.InitializationAuthorization -> Maybe L.QuiescenceEvidence -> Plan.MigrationPlan -> (Runtime -> IO ()) -> IO (Either R.RunFailure R.RunReport)
withRuntime = withRuntimeCheck (Right ())

withRuntimeCheck :: Either R.RunError () -> MutationContext -> L.AuditContext -> Maybe L.InitializationAuthorization -> Maybe L.QuiescenceEvidence -> Plan.MigrationPlan -> (Runtime -> IO ()) -> IO (Either R.RunFailure R.RunReport)
withRuntimeCheck prerequisite = withRuntimeObservation prerequisite Nothing

-- Adoption validates its fresh read before openStore may initialize anything.
-- Ordinary execution retains its existing single-load path.
withRuntimeObservation :: Either R.RunError () -> Maybe (R.HistoryReport -> Either R.RunError Bool) -> MutationContext -> L.AuditContext -> Maybe L.InitializationAuthorization -> Maybe L.QuiescenceEvidence -> Plan.MigrationPlan -> (Runtime -> IO ()) -> IO (Either R.RunFailure R.RunReport)
withRuntimeObservation prerequisite validateObservation context@(MutationContext config@(T.TargetConfig target _ _ _ _ _ _) provider@(ExclusiveAccess description _ _ _ _) _ _) audit initialization quiet plan action = do
  seed <- try @SomeException freshUuid
  let identity = either (const "00000000-0000-4000-8000-000000000000") id seed
  latest <- newIORef (Reporting.initialRun identity target description plan)
  secondary <- newIORef []
  result <- case seed of
    Left exception | isAsync exception -> throwIO exception
    Left _ -> pure (Left R.UnexpectedRuntimeFailure, [])
    Right _ -> do
      checked <- tryAction $ do
        either abort pure prerequisite
        either abort pure (preflight config audit plan)
        case initialization of
          Just (L.InitializationAuthorization authorized _ authAudit) -> do
            unless (authorized == target) (abort (R.LedgerFailed L.InitializationNotAuthorized))
            either abort pure (preflight config authAudit plan)
          Nothing -> pure ()
        emitAt context identity latest Event.RunBeginning Nothing Nothing Nothing
      case checked of
        Left failure -> pure (Left failure, [])
        Right () -> do
          scoped <- tryAction $ withExclusive provider target $ \guard -> do
            modifyIORef' latest (\report -> report {R.acquired = True})
            probe <- T.QueryId . ("chm-" <>) <$> freshUuid
            let check = checkGuard guard >>= pure . either (const (Left (Transport.TransportError Transport.AdministrativeAccessLost Nothing Nothing))) (const (Right ()))
            withTransportChecked config probe check $ \transport -> tryAction $ do
              let server = Just (Transport.transportIdentity transport)
              modifyIORef'
                latest
                ( \report -> case Reporting.runHistory report of
                    R.HistoryReport key _ presence position access events migrations unresolved -> Reporting.updateRun plan (R.HistoryReport key server presence position access events migrations unresolved) report
                )
              let AccessDescription strategy scope = guardDescription guard
                  -- The caller's coordinator contract is the authority for a new
                  -- ordinary job. Repair supplies a separate explicit operator
                  -- attestation; no elapsed-time/process-list inference is made.
                  established = fromMaybe (L.QuiescenceEvidence target (L.AuditContext (Ledger.auditActor audit) "Coordinator granted a job after all predecessor requests became quiescent" ["strategy:" <> strategy, "scope:" <> scope])) quiet
              observationOnly <- case validateObservation of
                Nothing -> pure False
                Just validate -> do
                  observation <- callStore (Store.load (Just guard) transport config)
                  let snapshot = Reporting.observationReport target server (R.GuardedObservation (guardDescription guard)) observation
                  modifyIORef' latest (Reporting.updateRun plan snapshot)
                  either abort pure (validate snapshot)
              if observationOnly
                then do
                  emitAt context identity latest Event.RunCompleted Nothing Nothing Nothing
                  callStore (Store.checkAccess guard)
                else do
                  opened <- Store.storeResult (Store.openStore guard transport config initialization established identity)
                  store <- case opened of
                    Left (Store.LedgerProblem L.InitializationNotAuthorized) | T.TargetConfig _ _ _ _ (T.ExistingLedger _) _ _ <- config, isNothing initialization -> abort R.LedgerRequired
                    Left failure -> abort (Reporting.storeError failure)
                    Right value -> pure value
                  let runtime = Runtime context audit plan guard transport store identity latest secondary
                  refresh runtime
                  case (config, initialization) of
                    (T.TargetConfig _ _ _ _ T.FirstUse _ _, Just (L.InitializationAuthorization _ ledger _)) -> modifyIORef' latest (\report -> report {R.initialized = Just ledger})
                    _ -> pure ()
                  report <- readIORef latest
                  let R.InspectionReport _ _ issues = Reporting.inspectHistory plan (Reporting.runHistory report)
                      changes = [issue | issue@R.DefinitionChanged {} <- issues]
                  unless (null changes) (abort (R.IncompatibleHistory changes))
                  action runtime
                  emit runtime Event.RunCompleted Nothing Nothing Nothing
                  callStore (Store.checkAccess guard)
          pure $ case scoped of
            Left failure -> (Left failure, [])
            Right (AccessResult acquired accessCleanup) -> case acquired of
              Left failure -> (Left (R.AccessFailed failure), map R.AccessCleanup accessCleanup)
              Right (Transport.ScopeResult network transportCleanup) ->
                let outcome = case network of
                      Left failure -> Left (R.TargetFailed failure)
                      Right (Left (TargetRejected failure)) -> Left (R.TargetFailed failure)
                      Right (Left (ProbeFailure failure)) -> Left (Reporting.outcomeError failure Nothing)
                      Right (Right value) -> value
                 in (outcome, map R.TransportCleanup transportCleanup ++ map R.AccessCleanup accessCleanup)
  snapshot <- readIORef latest
  extra <- readIORef secondary
  pure $ case result of
    (Left failure, cleanup) -> Left (R.RunFailure failure snapshot (extra ++ cleanup))
    (Right (), []) | null extra -> Right snapshot
    (Right (), cleanup) -> Left (R.RunFailure R.CleanupFailed snapshot (extra ++ cleanup))

runtimeStore :: Runtime -> Store.LedgerStore
runtimeStore (Runtime _ _ _ _ _ store _ _ _) = store

runtimeTransport :: Runtime -> Transport.Transport
runtimeTransport (Runtime _ _ _ _ transport _ _ _ _) = transport

runtimeGuard :: Runtime -> Guard
runtimeGuard (Runtime _ _ _ guard _ _ _ _ _) = guard

runtimeRunId :: Runtime -> Text
runtimeRunId (Runtime _ _ _ _ _ _ identity _ _) = identity

runtimeSnapshot :: Runtime -> IO R.RunReport
runtimeSnapshot (Runtime _ _ _ _ _ _ _ latest _) = readIORef latest

runtimeProjection :: Runtime -> IO L.Projection
runtimeProjection = callStore . Store.storeProjection . runtimeStore

runtimeAudit :: Runtime -> L.AuditContext
runtimeAudit (Runtime _ audit _ _ _ _ _ _ _) = audit

refresh :: Runtime -> IO ()
refresh runtime@(Runtime _ _ plan guard transport _ _ latest _) = do
  projection <- runtimeProjection runtime
  let snapshot = Reporting.fromProjection (Just (Transport.transportIdentity transport)) (R.GuardedObservation (guardDescription guard)) projection
  modifyIORef' latest (Reporting.updateRun plan snapshot)

emitAt :: MutationContext -> Text -> IORef R.RunReport -> Event.EventPhase -> Maybe L.Definition -> Maybe Int -> Maybe T.QueryId -> IO ()
emitAt (MutationContext _ _ sink _) identity latest phase definition index query = do
  report <- readIORef latest
  let component = fmap L.component definition
      migration = fmap L.migration definition
      step = do def <- definition; i <- index; L.StepDefinition name _ <- Reporting.at i (L.steps def); pure name
      event = Event.RunEvent phase identity component migration step query (Reporting.runPosition report)
  result <- try @SomeException (sink event)
  case result of
    Left exception | isAsync exception -> throwIO exception
    Left _ -> abort (R.CallbackFailed (R.EventCallback (Text.pack (show phase))))
    Right () -> pure ()

emit :: Runtime -> Event.EventPhase -> Maybe L.Definition -> Maybe Int -> Maybe T.QueryId -> IO ()
emit (Runtime context _ _ _ _ _ identity latest _) = emitAt context identity latest

appendEvent :: Runtime -> Maybe Text -> L.EventBody -> Maybe L.EventContext -> IO ()
appendEvent runtime attempt body context = do
  projection <- runtimeProjection runtime
  let L.LedgerPosition ledger number _ = L.position projection
  identity <- freshUuid
  time <- diagnosticTime
  let event = L.LedgerEvent (number + 1) identity ledger (runtimeRunId runtime) attempt time (runtimeAudit runtime) "0.1.0.0" context body
  mask $ \restore -> do
    _ <- restore (callStore (Store.append (runtimeStore runtime) event))
    refresh runtime

contextAt :: L.Definition -> Maybe Int -> IO (Maybe L.EventContext)
contextAt definition index = Just <$> either (const (abort R.UnexpectedRuntimeFailure)) pure (contextFor definition index)

recordObservation :: Runtime -> R.SqlObservation -> IO ()
recordObservation (Runtime _ _ _ _ _ _ _ latest _) value = modifyIORef' latest (Reporting.recordSql value)

secondaryAction :: Runtime -> (R.RunError -> R.SecondaryError) -> IO () -> IO ()
secondaryAction (Runtime _ _ _ _ _ _ _ _ errors) classify action =
  tryAction action >>= \case
    Left failure -> modifyIORef' errors (++ [classify failure])
    Right () -> pure ()

executeStep :: Runtime -> L.Definition -> Text -> Int -> Plan.StepView -> IO ()
executeStep runtime@(Runtime (MutationContext _ _ _ (DiagnosticPolicy diagnostic)) _ _ _ transport _ _ _ _) definition attempt index step = do
  reference <- maybe (abort R.UnexpectedRuntimeFailure) pure (Reporting.stepReference definition index)
  query <- Store.newQueryId
  context <- contextAt definition (Just index)
  emit runtime Event.BeforeStepStart (Just definition) (Just index) (Just query)
  appendEvent runtime (Just attempt) (L.StartStep index (queryIdText query)) context
  emit runtime Event.StepStarted (Just definition) (Just index) (Just query)
  emit runtime Event.BeforeSql (Just definition) (Just index) (Just query)
  case diagnostic of
    Nothing -> pure ()
    Just sink -> do
      observed <- try @SomeException (sink (SqlDiagnostic reference query (Plan.stepSql step)))
      case observed of Left exception | isAsync exception -> throwIO exception; Left _ -> abort (R.CallbackFailed R.SqlDiagnosticCallback); Right () -> pure ()
  outcome <- Transport.request transport query Transport.Command (Plan.stepSql step)
  case outcome of
    Transport.AcknowledgedSuccess Transport.CommandAccepted -> do
      recordObservation runtime (R.SqlObservation reference query R.QueryAcknowledged)
      emit runtime Event.SqlObserved (Just definition) (Just index) (Just query)
      emit runtime Event.BeforeStepSuccess (Just definition) (Just index) (Just query)
      appendEvent runtime (Just attempt) (L.SucceedStep index (queryIdText query)) context
      emit runtime Event.StepSucceeded (Just definition) (Just index) (Just query)
    _ -> do
      let (evidence, failure) = case outcome of
            Transport.NotSubmitted value -> (Ledger.PositiveNonSubmission, value)
            Transport.ObservedServerFailure value -> (Ledger.ObservedFailure, value)
            Transport.SubmissionUncertain value -> (Ledger.UncertainSubmission, value)
            _ -> (Ledger.UncertainSubmission, Transport.TransportError Transport.UnexpectedResponse Nothing Nothing)
          primary = R.SqlFailed reference query evidence failure
      recordObservation runtime (R.SqlObservation reference query (R.QueryRejected evidence failure))
      when (evidence == Ledger.ObservedFailure) $
        secondaryAction runtime R.RecordingError (appendEvent runtime (Just attempt) (L.FailStep index (queryIdText query) (L.FailureEvidence (Text.pack (show (Transport.code failure))) (Transport.httpStatus failure) (Transport.serverCode failure))) context)
      secondaryAction runtime (\case R.CallbackFailed phase -> R.ObserverError phase; other -> R.RecordingError other) (emit runtime Event.SqlObserved (Just definition) (Just index) (Just query))
      abort primary

executeMigration :: Runtime -> L.Definition -> Plan.MigrationView -> IO ()
executeMigration runtime definition migration = do
  attempt <- freshUuid
  context <- contextAt definition Nothing
  emit runtime Event.BeforeMigrationStart (Just definition) Nothing Nothing
  appendEvent runtime (Just attempt) (L.StartMigration definition) context
  emit runtime Event.MigrationStarted (Just definition) Nothing Nothing
  mapM_ (\(index, step) -> executeStep runtime definition attempt index step) (zip [0 ..] (NE.toList (Plan.migrationSteps migration)))
  finishMigration runtime definition attempt

finishMigration :: Runtime -> L.Definition -> Text -> IO ()
finishMigration runtime definition attempt = do
  emit runtime Event.BeforeMigrationComplete (Just definition) Nothing Nothing
  context <- contextAt definition Nothing
  appendEvent runtime (Just attempt) L.CompleteMigration context
  emit runtime Event.MigrationCompleted (Just definition) Nothing Nothing

orderedMigrations :: Plan.MigrationPlan -> [(L.Definition, Plan.MigrationView)]
orderedMigrations plan = zip (definitions plan) [migration | component <- NE.toList (Plan.inspectPlan plan), migration <- NE.toList (Plan.componentMigrations component)]
