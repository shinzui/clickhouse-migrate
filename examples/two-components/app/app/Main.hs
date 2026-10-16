module Main (main) where

import ClickHouseMigrate
import ClickHouseMigrate.CLI
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.TestSupport.ExclusiveAccess (hostLocalExclusiveAccess)
import Control.Applicative ((<**>))
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Example.Analytics qualified as Analytics
import Example.Catalog qualified as Catalog
import Options.Applicative qualified as O
import System.Environment (getArgs, getEnv, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr, stdout)

-- These outer flags belong to this application. The library parser is mounted
-- unchanged; other applications can put it beneath their own subcommand.
data AppOptions = AppOptions !Bool !Bool !Invocation

main :: IO ()
main = do
  args <- getArgs
  let parser = O.info ((AppOptions <$> O.switch (O.long "progress" <> O.help "Write safe progress to stderr") <*> O.switch (O.long "sql-diagnostics" <> O.help "Explicitly write authored SQL to stderr; may disclose secrets") <*> commandParser) <**> O.helper) (O.fullDesc <> O.progDesc "Private two-component migration example")
  case O.execParserPure O.defaultPrefs parser args of
    O.Failure failure -> case O.renderFailure failure "clickhouse-migrate-example" of
      (helpText, ExitSuccess) -> putStrLn helpText
      _ -> emit JsonOutput (CommandResult "parse" (Left (CommandRejected InvalidArguments)))
    O.CompletionInvoked _ -> emit JsonOutput (CommandResult "parse" (Left (CommandRejected InvalidArguments)))
    O.Success (AppOptions progress rawSql (Invocation format command)) -> do
      plan <- either (const (fail "Invalid compiled example plan")) pure (migrationPlan (Catalog.component :| [Analytics.component]))
      -- Offline plan never reads configuration or even constructs a provider.
      environment <- if requiresTarget command then loadEnvironment command progress rawSql else pure (Right (commandEnvironment Nothing Nothing E.quietEvents E.redactedDiagnostics AdministrativeCommands))
      result <- case environment of Left problem -> pure (CommandResult (commandName command) (Left (CommandRejected problem))); Right configured -> handleCommand configured plan command
      emit format result

emit :: OutputFormat -> CommandResult -> IO ()
emit format result@(CommandResult _ outcome) = do
  case format of JsonOutput -> BS.hPut stdout (renderJson result <> "\n"); TextOutput -> Text.hPutStr stdout (renderText result)
  exitWith (case outcome of Right _ -> ExitSuccess; Left _ -> ExitFailure 1)

loadEnvironment :: Command -> Bool -> Bool -> IO (Either CommandError CommandEnvironment)
loadEnvironment command progress rawSql = do
  loaded <- try @IOException (loadCommandEnvironment command progress rawSql)
  pure (either (const (Left MissingTargetConfiguration)) id loaded)

loadCommandEnvironment :: Command -> Bool -> Bool -> IO (Either CommandError CommandEnvironment)
loadCommandEnvironment command progress rawSql = do
  loaded <- try @IOException $ do
    key <- required "CHM_TARGET" targetKey
    endpoint <- required "CHM_ENDPOINT" directEndpoint
    identity <- required "CHM_SERVER_ID" serverId
    namespace <- required "CHM_LEDGER_DATABASE" ledgerNamespace
    binding <- lookupEnv "CHM_LEDGER_ID" >>= maybe (pure FirstUse) (fmap ExistingLedger . validated ledgerId . Text.pack)
    user <- maybe "default" Text.pack <$> lookupEnv "CHM_USER"
    password <- Text.pack <$> getEnv "CHM_PASSWORD"
    credentials <- validated (basicCredentials user) password
    pure (targetConfig key endpoint identity namespace binding credentials defaultHttpLimits)
  case loaded of
    Left _ -> pure (Left MissingTargetConfiguration)
    Right config -> case quiescenceForCommand (configuredTargetKey config) command of
      Left problem -> pure (Left problem)
      Right quiet -> do
        let needsProvider = isMutation command || case command of StatusCommand guarded -> guarded; HistoryCommand guarded -> guarded; VerifyCommand _ guarded -> guarded; AdoptCommand _ (AdoptionInput _ _ _ _ _ guarded _) -> guarded; _ -> False
        root <- if needsProvider then lookupEnv "CHM_LOCK_ROOT" else pure Nothing
        provider <- case root of
          Nothing -> pure Nothing
          Just directory -> do
            -- This adapter is only suitable for one host whose administrators
            -- all share this canonical root. Evidence never comes from a timeout.
            created <- hostLocalExclusiveAccess directory 3000000 quiet
            either (const (fail "Invalid development coordinator")) (pure . Just) created
        let sink = if progress then \event -> Text.hPutStrLn stderr ("progress: " <> Text.pack (show event)) else E.quietEvents
            diagnostics = if rawSql then E.sqlDiagnostics (\(E.SqlDiagnostic _ query bytes) -> Text.hPutStrLn stderr ("SQL " <> queryIdText query) >> BS.hPut stderr (bytes <> "\n")) else E.redactedDiagnostics
        pure (Right (commandEnvironment (Just config) provider sink diagnostics AdministrativeCommands))
  where
    required name parse = Text.pack <$> getEnv name >>= validated parse
    validated parse value = either (const (ioError (userError "Invalid explicit application configuration"))) pure (parse value)
