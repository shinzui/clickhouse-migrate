-- | Composable optparse-applicative parser. The caller owns its outer executable.
module ClickHouseMigrate.CLI.Parser (commandParser, commandInfo, parseInvocation, commandName, requiresTarget, isMutation) where

import ClickHouseMigrate.CLI.Types
import ClickHouseMigrate.Definition qualified as D
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Control.Applicative (many, optional, some, (<**>), (<|>))
import Data.Text qualified as Text
import Options.Applicative qualified as O
import System.Exit (ExitCode (..))

readValidated :: (Show e) => (Text -> Either e a) -> O.ReadM a
readValidated parse = O.eitherReader (either (Left . show) Right . parse . Text.pack)

textOption :: String -> String -> String -> O.Parser Text
textOption name metavar description = O.option reader (O.long name <> O.metavar metavar <> O.help description)
  where
    reader = O.eitherReader $ \raw ->
      let value = Text.pack raw
          checked = case name of "actor" -> L.auditContext value "parser validation" []; "reason" -> L.auditContext "parser validation" value []; _ -> L.auditContext "parser validation" "parser validation" [value]
       in either (const (Left "Invalid audit field")) (const (Right value)) checked

output :: O.Parser OutputFormat
output = O.flag TextOutput JsonOutput (O.long "json" <> O.help "Return one schemaVersion 1 command-result JSON document; progress uses the caller sink")

audit :: Bool -> O.Parser AuditInput
audit required = AuditInput <$> textOption "actor" "ACTOR" "Administrative actor retained in immutable history" <*> textOption "reason" "REASON" "Reason retained in immutable history" <*> (if required then some evidence else many evidence)
  where
    evidence = textOption "evidence" "REFERENCE" "External evidence reference; repeat for additional evidence"

expectedTarget :: O.Parser T.TargetKey
expectedTarget = O.option (readValidated T.targetKey) (O.long "expect-target" <> O.metavar "TARGET" <> O.help "Exact configured target key")

initialization :: O.Parser (Maybe T.LedgerId)
initialization = optional (O.option (readValidated T.ledgerId) (O.long "initialize-ledger" <> O.metavar "UUID" <> O.help "Explicit first-use UUID; retain before submission, then persist the returned ledger binding"))

quiescent :: Bool -> O.Parser Bool
quiescent required = if required then O.flag' True description else O.switch description
  where
    description = O.long "quiescent" <> O.help "Assert external exclusion and complete drain of all predecessor SQL, ledger and bootstrap requests; absence/timeout is insufficient"

guarded :: O.Parser Bool
guarded = O.switch (O.long "guarded" <> O.help "Acquire the caller's provider for this observation")

stepAttempt :: O.Parser R.StepAttempt
stepAttempt = R.StepAttempt <$> O.option (readValidated L.parseAttemptId) (O.long "step-attempt" <> O.metavar "UUID" <> O.help "Original migration attempt owning the selected step query") <*> O.option (O.eitherReader (either (const (Left "Invalid stable step name")) (Right . D.stepNameText) . D.stepName . Text.pack)) (O.long "step" <> O.metavar "STEP") <*> O.option (readValidated T.queryId) (O.long "query-id" <> O.metavar "QUERY_ID" <> O.help "Exact selected query identity from history")

repairInput :: Bool -> O.Parser RepairInput
repairInput selected = RepairInput <$> expectedTarget <*> O.option (readValidated L.parseLedgerPosition) (O.long "expect-position" <> O.metavar "TOKEN") <*> O.option (readValidated L.parseAttemptId) (O.long "attempt" <> O.metavar "UUID" <> O.help "Current migration attempt from fresh guarded history") <*> (if selected then Just <$> stepAttempt else pure Nothing) <*> audit True <*> quiescent True <*> many (O.option (readValidated L.parseAppendReceipt) (O.long "pending-append" <> O.metavar "RECEIPT" <> O.help "Retained exact uncertain append receipt; repeat as needed"))

adoptionInput :: O.Parser AdoptionInput
adoptionInput = AdoptionInput <$> expectedTarget <*> expected <*> initialization <*> audit True <*> quiescent True <*> guarded <*> O.strOption (O.long "request" <> O.metavar "FILE" <> O.help "Explicit source-neutral adoption input JSON; contains no executable migration definitions")
  where
    expected = (PositionInput <$> O.option (readValidated L.parseLedgerPosition) (O.long "expect-position" <> O.metavar "TOKEN")) <|> O.flag' AbsentInput (O.long "expect-absent" <> O.help "Expect missing or compatible uninitialized native history; requires explicit initialization UUID")

leaf :: String -> String -> O.Parser Command -> O.Mod O.CommandFields Invocation
leaf name description parser = O.command name (O.info ((Invocation <$> output <*> parser) <**> O.helper) (O.progDesc description))

commandParser :: O.Parser Invocation
commandParser =
  O.hsubparser
    ( leaf "plan" "Inspect compiled definitions offline; no target or server required" (pure PlanCommand)
        <> leaf "status" "Observe definition compatibility and recorded states; never initialize" (StatusCommand <$> guarded)
        <> leaf "history" "Observe immutable history without requiring compatible current definitions" (HistoryCommand <$> guarded)
        <> leaf "verify" "Verify compatible history; pending is compatible unless --require-current. This does not verify schema equality" (VerifyCommand <$> O.switch (O.long "require-current" <> O.help "Fail when any migration remains pending") <*> guarded)
        <> leaf "up" "Execute pending SQL once per authorized attempt; unresolved history blocks; no automatic repair" (UpCommand <$> (UpInput <$> expectedTarget <*> audit False <*> initialization <*> quiescent False))
        <> O.command "repair" (O.info (repairs <**> O.helper) (O.progDesc "Explicit expected-state recovery; no force, reset or checksum rewriting"))
        <> O.command "adopt" (O.info (adoptions <**> O.helper) (O.progDesc "Review/apply/resume a complete legacy prefix without executing its SQL"))
    )
  where
    repairs = O.hsubparser (leaf "resume" "Run only never-started remaining steps of the selected migration" (RepairCommand Resume <$> repairInput False) <> leaf "retry-step" "Authorize fresh attempt/query IDs and execute only the selected step" (RepairCommand RetryStep <$> repairInput True) <> leaf "accept-step" "Attest the selected uncertain step; no SQL, continuation or finalization" (RepairCommand AcceptStep <$> repairInput True) <> leaf "finalize" "Complete a fully resolved migration without application SQL" (RepairCommand Finalize <$> repairInput False))
    adoptions = O.hsubparser (leaf "plan" "Read and validate the entire source/mapping before mutation" (AdoptCommand PlanAdoption <$> adoptionInput) <> leaf "apply" "Initialize only when explicitly authorized; append a reviewed fresh batch" (AdoptCommand ApplyAdoption <$> adoptionInput) <> leaf "resume" "Resume the identical interrupted batch at fresh expected state" (AdoptCommand ResumeAdoption <$> adoptionInput))

commandInfo :: O.ParserInfo Invocation
commandInfo = O.info (commandParser <**> O.helper) (O.fullDesc <> O.progDesc "Compiled ClickHouse migrations; application-owned configuration, coordination, logging and exit policy")

-- Invalid arguments deliberately do not echo arbitrary values or secrets.
-- Applications needing optparse's richer diagnostics may use commandInfo directly.
parseInvocation :: [String] -> Either ParseIssue Invocation
parseInvocation args = case O.execParserPure O.defaultPrefs commandInfo args of
  O.Success invocation@(Invocation _ command) -> validateParsed command >> Right invocation
  O.Failure failure -> let (helpText, exit) = O.renderFailure failure "clickhouse-migrate" in Left (if exit == ExitSuccess then HelpRequested (Text.pack helpText) else ArgumentsRejected)
  O.CompletionInvoked _ -> Left CompletionRequested

validateParsed :: Command -> Either ParseIssue ()
validateParsed = \case
  UpCommand (UpInput target input _ quiet) -> do
    auditContext <- checkedAudit input
    when (quiet && null (L.auditReferences auditContext)) (Left ArgumentsRejected)
    _ <- if quiet then validate (L.attestQuiescence target auditContext) else Right ()
    pure ()
  RepairCommand operation (RepairInput target expected attempt step input quiet receipts) -> do
    auditContext <- checkedAudit input
    unless quiet (Left ArgumentsRejected)
    established <- either (const (Left ArgumentsRejected)) Right (L.attestQuiescence target auditContext)
    evidence <- either (const (Left ArgumentsRejected)) Right (Repair.recoveryEvidence auditContext established receipts)
    case (operation, step) of
      (Resume, Nothing) -> validate (Repair.resumeRequest expected attempt evidence)
      (Finalize, Nothing) -> validate (Repair.finalizeRequest expected attempt evidence)
      (RetryStep, Just selected) -> validate (Repair.retryStepRequest expected attempt selected evidence)
      (AcceptStep, Just selected) -> validate (Repair.acceptStepRequest expected attempt selected evidence)
      _ -> Left ArgumentsRejected
  AdoptCommand _ (AdoptionInput _ expected initialLedger input quiet _ file) -> do
    auditContext <- checkedAudit input
    unless (quiet && not (null (L.auditReferences auditContext)) && not (null file) && not ('\0' `elem` file)) (Left ArgumentsRejected)
    case expected of AbsentInput | isNothing initialLedger -> Left ArgumentsRejected; _ -> Right ()
  _ -> Right ()
  where
    checkedAudit (AuditInput actor reason refs) = either (const (Left ArgumentsRejected)) Right (L.auditContext actor reason refs)
    validate = either (const (Left ArgumentsRejected)) (const (Right ()))

commandName :: Command -> Text
commandName = \case
  PlanCommand -> "plan"
  StatusCommand _ -> "status"
  HistoryCommand _ -> "history"
  VerifyCommand _ _ -> "verify"
  UpCommand _ -> "up"
  RepairCommand operation _ -> case operation of Resume -> "repair.resume"; RetryStep -> "repair.retry-step"; AcceptStep -> "repair.accept-step"; Finalize -> "repair.finalize"
  AdoptCommand operation _ -> case operation of PlanAdoption -> "adopt.plan"; ApplyAdoption -> "adopt.apply"; ResumeAdoption -> "adopt.resume"

requiresTarget :: Command -> Bool
requiresTarget PlanCommand = False
requiresTarget _ = True

isMutation :: Command -> Bool
isMutation = \case UpCommand _ -> True; RepairCommand _ _ -> True; AdoptCommand PlanAdoption _ -> False; AdoptCommand _ _ -> True; _ -> False
