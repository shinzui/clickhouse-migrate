-- | Concise human summaries, with complete safe failure detail retained.
module ClickHouseMigrate.CLI.Render.Text (renderText) where

import ClickHouseMigrate.CLI.Render.Json (renderJson)
import ClickHouseMigrate.CLI.Types
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

renderText :: CommandResult -> Text
renderText result@(CommandResult command outcome) = Text.unlines $ case outcome of
  Left _ -> [command <> ": error", "Safe failure detail (schemaVersion 1; latest acknowledged report, local observations and secondary errors):", Encoding.decodeUtf8 (renderJson result)]
  Right report ->
    (command <> ": ok") : case report of
      PlanReport components -> concatMap componentLines components
      StatusReport (R.InspectionReport history migrations issues) -> historyLines history ++ migrationLines migrations ++ ["Compatibility issues: " <> number (length issues)]
      HistoryReport history -> historyLines history ++ eventLines history
      VerificationReport (R.VerificationReport (R.InspectionReport history migrations _) current) -> ["Compatible: yes", "Current: " <> if current then "yes" else "no (pending definitions)"] ++ historyLines history ++ migrationLines migrations
      RunReport (R.RunReport _ _ _ acquired history migrations observations _) -> ["Administrative access acquired: " <> if acquired then "yes" else "no"] ++ historyLines history ++ migrationLines migrations ++ ["Local SQL observations: " <> number (length observations)]
      AdoptionPlanReport history (R.AdoptionSummary source _ _ _ count) _ -> historyLines history ++ ["Adoption source: " <> source, "Reviewed prefix entries: " <> number count, "No application SQL executed."]
  where
    componentLines (PlanComponent name dependencies migrations) = ("Component: " <> name <> " (depends on: " <> Text.intercalate ", " dependencies <> ")") : concatMap migration migrations
    migration (PlanMigration name _ checksum steps) = ("  " <> name <> " " <> checksum) : ["    " <> step <> " " <> digest | PlanStep step digest <- steps]

number :: Int -> Text
number = Text.pack . show

historyLines :: R.HistoryReport -> [Text]
historyLines (R.HistoryReport target _ presence position access _ _ unresolved) =
  [ "Target: " <> T.targetKeyText target,
    "Ledger: " <> case presence of R.LedgerUnknown -> "unknown"; R.LedgerMissing -> "missing"; R.LedgerUninitialized -> "uninitialized"; R.LedgerInitializedAt identity -> T.ledgerIdText identity,
    "Position: " <> maybe "none" L.ledgerPositionText position,
    "Observation: " <> case access of R.UnguardedObservation -> "unguarded"; R.GuardedObservation _ -> "guarded",
    "Unresolved: " <> if unresolved then "yes" else "no"
  ]

eventLines :: R.HistoryReport -> [Text]
eventLines (R.HistoryReport _ _ _ _ _ events _ _) = [Text.pack (show ordinal) <> " " <> R.historyKind body | R.HistoryEvent ordinal _ _ _ _ _ _ _ _ body <- events]

migrationLines :: [R.MigrationSummary] -> [Text]
migrationLines = concatMap $ \(R.MigrationSummary (R.DefinitionSummary _ _ component _ name _ _) state _ steps) ->
  (component <> "/" <> name <> ": " <> migrationState state) : ["  " <> step <> ": " <> stepState status | R.StepSummary step _ status _ _ <- steps]
  where
    migrationState = \case R.Pending -> "pending"; R.InProgress -> "in-progress"; R.Failed -> "failed"; R.Applied -> "applied"; R.Adopted -> "adopted"; R.Invalid -> "invalid"
    stepState = \case R.StepPending -> "pending"; R.StepUncertain -> "uncertain"; R.StepObservedSuccess -> "observed-success"; R.StepObservedFailure -> "observed-failure"; R.StepAccepted -> "accepted (operator attestation)"
