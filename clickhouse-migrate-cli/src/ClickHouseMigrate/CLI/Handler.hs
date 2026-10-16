-- | Dispatch with application-owned configuration, sinks and command policy.
module ClickHouseMigrate.CLI.Handler (commandEnvironment, handleCommand, planReport, quiescenceForCommand) where

import ClickHouseMigrate
import ClickHouseMigrate.Adoption qualified as A
import ClickHouseMigrate.CLI.AdoptionFile
import ClickHouseMigrate.CLI.Parser (commandName, isMutation)
import ClickHouseMigrate.CLI.Types
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.ExclusiveAccess (ExclusiveAccess)
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set

commandEnvironment :: Maybe TargetConfig -> Maybe ExclusiveAccess -> E.EventSink -> E.DiagnosticPolicy -> CommandPolicy -> CommandEnvironment
commandEnvironment = CommandEnvironment

planReport :: MigrationPlan -> [PlanComponent]
planReport plan =
  [ PlanComponent
      (componentNameText (componentViewName component))
      (map componentNameText (Set.toAscList (componentDependencies component)))
      [ PlanMigration
          (migrationNameText (migrationIdName (migrationId migration)))
          (migrationDescription migration)
          (migrationChecksumHex (migrationChecksum migration))
          [PlanStep (stepNameText (stepViewName step)) (stepChecksumHex (stepChecksum step)) | step <- NE.toList (migrationSteps migration)]
      | migration <- NE.toList (componentMigrations component)
      ]
  | component <- NE.toList (inspectPlan plan)
  ]

makeAudit :: AuditInput -> Either CommandError L.AuditContext
makeAudit (AuditInput actor reason refs) = either (const (Left InvalidAuditInput)) Right (L.auditContext actor reason refs)

makeQuiet :: TargetKey -> AuditInput -> Bool -> Either CommandError (Maybe L.QuiescenceEvidence)
makeQuiet _ _ False = Right Nothing
makeQuiet key input@(AuditInput _ _ refs) True = do
  unless (not (null refs)) (Left RecoveryEvidenceRequired)
  audit <- makeAudit input
  Just <$> either (const (Left InvalidAuditInput)) Right (L.attestQuiescence key audit)

-- Applications may use this to construct a conservative development provider.
-- It does not prove exclusion/drain; the assertion remains the caller's duty.
quiescenceForCommand :: TargetKey -> Command -> Either CommandError (Maybe L.QuiescenceEvidence)
quiescenceForCommand actual = \case
  UpCommand (UpInput expected audit _ quiet) -> match expected >> makeQuiet actual audit quiet
  RepairCommand _ (RepairInput expected _ _ _ audit quiet _) -> match expected >> required audit quiet
  AdoptCommand _ (AdoptionInput expected _ _ audit quiet _ _) -> match expected >> required audit quiet
  _ -> Right Nothing
  where
    match expected = unless (actual == expected) (Left ExpectedTargetMismatch)
    required audit quiet = do
      unless quiet (Left QuiescenceRequired)
      makeQuiet actual audit quiet

data Ready = Ready !TargetConfig !(Maybe ExclusiveAccess) !E.EventSink !E.DiagnosticPolicy

prepare :: CommandEnvironment -> Command -> Either CommandError Ready
prepare (CommandEnvironment configured provider sink diagnostics policy) command = do
  when (isMutation command && policy /= AdministrativeCommands) (Left CommandNotAllowed)
  config <- maybe (Left MissingTargetConfiguration) Right configured
  when (isMutation command && isNothing provider) (Left MissingExclusiveAccess)
  let key = configuredTargetKey config
  _ <- quiescenceForCommand key command
  case command of
    UpCommand (UpInput _ audit _ _) -> void (makeAudit audit)
    RepairCommand _ (RepairInput _ _ _ _ audit _ _) -> void (makeAudit audit)
    AdoptCommand _ (AdoptionInput _ _ _ audit _ _ file) -> do
      void (makeAudit audit)
      when (null file || '\0' `elem` file) (Left InvalidAdoptionInput)
    _ -> pure ()
  pure (Ready config provider sink diagnostics)

inspection :: Maybe ExclusiveAccess -> Bool -> Either CommandError I.InspectionOptions
inspection _ False = Right I.Observe
inspection provider True = maybe (Left MissingExclusiveAccess) (Right . I.Guarded) provider

-- Offline plan deliberately does not force the environment argument.
handleCommand :: CommandEnvironment -> MigrationPlan -> Command -> IO CommandResult
handleCommand _ plan PlanCommand = pure (CommandResult "plan" (Right (PlanReport (planReport plan))))
handleCommand environment plan command =
  let name = commandName command
      reject = pure . CommandResult name . Left . CommandRejected
      finish = pure . CommandResult name
   in case prepare environment command of
        Left failure -> reject failure
        Right (Ready config provider sink diagnostics) ->
          let readWith guarded action = case inspection provider guarded of Left failure -> reject failure; Right options -> action options >>= finish
              mutate action = case provider of Nothing -> reject MissingExclusiveAccess; Just access -> action (Run.mutationContext config access sink diagnostics)
           in case command of
                StatusCommand guarded -> readWith guarded (\options -> fmap (either (Left . InspectionFailed) (Right . StatusReport)) (I.status options config plan))
                HistoryCommand guarded -> readWith guarded (\options -> fmap (either (Left . InspectionFailed) (Right . HistoryReport)) (I.history options config))
                VerifyCommand current guarded -> readWith guarded (\options -> fmap (either (Left . InspectionFailed) (Right . VerificationReport)) (I.verify options config (I.verifyOptions current) plan))
                UpCommand (UpInput target input initialization _) -> case makeAudit input of
                  Left failure -> reject failure
                  Right audit -> mutate $ \context -> Run.up context (Run.upOptions audit (fmap (\ledger -> L.authorizeInitialization target ledger audit) initialization)) plan >>= finish . either (Left . RunFailed) (Right . RunReport)
                RepairCommand operation (RepairInput _ expected attempt selected input quiet receipts) -> case recovery config input quiet receipts of
                  Left failure -> reject failure
                  Right evidence -> case buildRepair operation expected attempt selected evidence of
                    Left failure -> reject failure
                    Right request -> mutate $ \context -> Repair.repair context plan request >>= finish . either (Left . RunFailed) (Right . RunReport)
                AdoptCommand operation (AdoptionInput target expected initialization input quiet guarded file) -> case makeAdoption target expected initialization input quiet of
                  Left failure -> reject failure
                  Right (state, authorization, established, audit) -> do
                    loaded <- readAdoptionInput file
                    case loaded >>= decodeAdoptionInput target state authorization established audit of
                      Left failure -> reject failure
                      Right request -> case inspection provider guarded of
                        Left failure -> reject failure
                        Right options -> do
                          observed <- I.status options config plan
                          case observed of
                            Left failure -> finish (Left (InspectionFailed failure))
                            Right snapshot -> case A.planAdoption plan snapshot request of
                              Left failure -> let R.InspectionReport observedHistory _ _ = snapshot in finish (Left (AdoptionRejected failure observedHistory))
                              Right adoption -> case operation of
                                PlanAdoption -> let R.InspectionReport observedHistory _ _ = snapshot in finish (Right (AdoptionPlanReport observedHistory (A.inspectAdoption adoption) (A.adoptionEntries adoption)))
                                ApplyAdoption -> mutate $ \context -> A.applyAdoption context plan adoption >>= finish . either (Left . RunFailed) (Right . RunReport)
                                ResumeAdoption -> mutate $ \context -> A.resumeAdoption context plan adoption >>= finish . either (Left . RunFailed) (Right . RunReport)

recovery :: TargetConfig -> AuditInput -> Bool -> [L.AppendReceipt] -> Either CommandError Repair.RecoveryEvidence
recovery config input quiet receipts = do
  established <- makeQuiet (configuredTargetKey config) input quiet >>= maybe (Left QuiescenceRequired) Right
  audit <- makeAudit input
  either (const (Left InvalidRepairInput)) Right (Repair.recoveryEvidence audit established receipts)

buildRepair :: RepairOperation -> L.LedgerPosition -> L.AttemptId -> Maybe R.StepAttempt -> Repair.RecoveryEvidence -> Either CommandError Repair.RepairRequest
buildRepair operation expected attempt selected evidence = either (const (Left InvalidRepairInput)) Right $ case (operation, selected) of
  (Resume, Nothing) -> Repair.resumeRequest expected attempt evidence
  (Finalize, Nothing) -> Repair.finalizeRequest expected attempt evidence
  (RetryStep, Just step) -> Repair.retryStepRequest expected attempt step evidence
  (AcceptStep, Just step) -> Repair.acceptStepRequest expected attempt step evidence
  _ -> Left Repair.InvalidStepAttempt

makeAdoption :: TargetKey -> ExpectedInput -> Maybe LedgerId -> AuditInput -> Bool -> Either CommandError (L.ExpectedLedgerState, Maybe L.InitializationAuthorization, L.QuiescenceEvidence, L.AuditContext)
makeAdoption target expected initialization input quiet = do
  established <- makeQuiet target input quiet >>= maybe (Left QuiescenceRequired) Right
  audit <- makeAudit input
  let state = case expected of AbsentInput -> L.ExpectAbsent target; PositionInput position -> L.ExpectPosition position
      authorization = fmap (\ledger -> L.authorizeInitialization target ledger audit) initialization
  when (case expected of AbsentInput -> isNothing authorization; _ -> False) (Left InitializationRequired)
  pure (state, authorization, established, audit)
