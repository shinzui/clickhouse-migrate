-- | Fault controls for an owned fixture, with request evidence excluding SQL/auth.
module ClickHouseMigrate.TestSupport.FaultProxy
  ( FaultProxy,
    FaultMode (..),
    LedgerStage (..),
    setLedgerFault,
    setLedgerStepFault,
    addLedgerFault,
    releaseFault,
    withFaultProxy,
    withTlsFaultProxy,
    proxyEndpoint,
    setFault,
    setFaultForQuery,
    proxyEvents,
    proxyConnections,
    redirectTo,
  )
where

import ClickHouseMigrate.Prelude
import ClickHouseMigrate.TestSupport.Internal.Fixture
import Control.Exception (bracket)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified

data FaultMode = Pass | DelayHistoryBody | AppendLateError | OversizedHistoryRow | HistoryGap | HistoryIdentityConflict | HistoryDuplicateConflict | DropResponse | TruncateResponse | LateError | Redirect | CloseConnection | CloseReusedConnection | DelayResponse | DelayFirstResponse | HoldBeforeForward | UnsupportedVersion | PrereleaseVersion | WeakenedPolicy | WeakenedStorage | SwitchIdentityAfterResponse
  deriving stock (Eq, Show)

data FaultProxy = FaultProxy !Fixture !Int !Text

-- Shares the fixture owner's lifetime; the owner closes every proxy and server.
withFaultProxy :: Server -> (FaultProxy -> IO a) -> IO a
withFaultProxy server = withProxy server False

withTlsFaultProxy :: Server -> (FaultProxy -> IO a) -> IO a
withTlsFaultProxy server = withProxy server True

withProxy :: Server -> Bool -> (FaultProxy -> IO a) -> IO a
withProxy (Server fixture) tls = bracket acquire release
  where
    acquire = do
      response <- fixtureRpc fixture (object ["operation" .= ("proxy-start" :: Text), "tls" .= tls])
      identity <- field "id" response
      endpoint <- field "endpoint" response
      pure (FaultProxy fixture identity endpoint)
    release (FaultProxy _ identity _) = void $ fixtureRpc fixture (object ["operation" .= ("proxy-stop" :: Text), "id" .= identity])

proxyEndpoint :: FaultProxy -> Text
proxyEndpoint (FaultProxy _ _ endpoint) = endpoint

setFault :: FaultProxy -> FaultMode -> IO ()
setFault (FaultProxy fixture identity _) mode = void $ fixtureRpc fixture (object ["operation" .= ("proxy-mode" :: Text), "id" .= identity, "mode" .= modeName mode])

proxyEvents :: FaultProxy -> IO Value
proxyEvents (FaultProxy fixture identity _) = fixtureRpc fixture (object ["operation" .= ("proxy-events" :: Text), "id" .= identity])

redirectTo :: FaultProxy -> Text -> IO ()
redirectTo (FaultProxy fixture identity _) endpoint = void $ fixtureRpc fixture (object ["operation" .= ("proxy-redirect" :: Text), "id" .= identity, "endpoint" .= endpoint])

modeName :: FaultMode -> Text
modeName Pass = "pass"
modeName DelayHistoryBody = "delay-history-body"
modeName AppendLateError = "append-late-error"
modeName OversizedHistoryRow = "oversized-history-row"
modeName HistoryGap = "history-gap"
modeName HistoryIdentityConflict = "history-identity-conflict"
modeName HistoryDuplicateConflict = "history-duplicate-conflict"
modeName DropResponse = "drop"
modeName TruncateResponse = "truncate"
modeName LateError = "late-error"
modeName Redirect = "redirect"
modeName CloseConnection = "close"
modeName CloseReusedConnection = "close-second"
modeName DelayResponse = "delay"
modeName DelayFirstResponse = "delay-first"
modeName HoldBeforeForward = "hold-before"
modeName UnsupportedVersion = "unsupported-version"
modeName PrereleaseVersion = "prerelease-version"
modeName WeakenedPolicy = "weakened-policy"
modeName WeakenedStorage = "weakened-storage"
modeName SwitchIdentityAfterResponse = "switch-identity"

setFaultForQuery :: FaultProxy -> Text -> FaultMode -> IO ()
setFaultForQuery (FaultProxy fixture identity _) query mode = void $ fixtureRpc fixture (object ["operation" .= ("proxy-mode" :: Text), "id" .= identity, "mode" .= modeName mode, "queryId" .= query])

proxyConnections :: FaultProxy -> IO Int
proxyConnections (FaultProxy fixture identity _) = fixtureRpc fixture (object ["operation" .= ("proxy-open-connections" :: Text), "id" .= identity]) >>= fieldResult
  where
    fieldResult value = case Data.Aeson.fromJSON value of Data.Aeson.Success number -> pure number; Data.Aeson.Error _ -> fail "Invalid proxy connection count"

-- SQL bodies are inspected privately only to select a protocol stage; they are
-- never included in proxy events or diagnostics.
data LedgerStage = HistoryRead | DatabaseCreation | TableCreation | Initialization | MigrationStart | StepStart | StepSuccess | MigrationCompletion | FailureRecording | RecoveryAuthorization | StepAcceptance | AdoptionStart | AdoptionEntry | AdoptionCompletion
  deriving stock (Eq, Show)

stageName :: LedgerStage -> Text
stageName = \case
  HistoryRead -> "history-read"
  DatabaseCreation -> "ddl-database"
  TableCreation -> "ddl-table"
  Initialization -> "initialized"
  MigrationStart -> "migration-started"
  StepStart -> "step-started"
  StepSuccess -> "step-succeeded"
  MigrationCompletion -> "migration-completed"
  FailureRecording -> "execution-failed"
  RecoveryAuthorization -> "recovery-authorized"
  StepAcceptance -> "step-accepted"
  AdoptionStart -> "adoption-started"
  AdoptionEntry -> "adoption-entry"
  AdoptionCompletion -> "adoption-completed"

setLedgerFault :: FaultProxy -> LedgerStage -> FaultMode -> IO ()
setLedgerFault (FaultProxy fixture identity _) stage mode = void $ fixtureRpc fixture (object ["operation" .= ("proxy-mode" :: Text), "id" .= identity, "mode" .= modeName mode, "stage" .= stageName stage])

releaseFault :: FaultProxy -> IO ()
releaseFault (FaultProxy fixture identity _) = void $ fixtureRpc fixture (object ["operation" .= ("proxy-release" :: Text), "id" .= identity])

-- | Select a named step without exposing its SQL in recorded evidence.
setLedgerStepFault :: FaultProxy -> LedgerStage -> Text -> FaultMode -> IO ()
setLedgerStepFault (FaultProxy fixture identity _) stage step mode = void $ fixtureRpc fixture (object ["operation" .= ("proxy-mode" :: Text), "id" .= identity, "mode" .= modeName mode, "stage" .= stageName stage, "step" .= step])

-- | Overlay a ledger fault while retaining a query-specific application fault.
addLedgerFault :: FaultProxy -> LedgerStage -> FaultMode -> IO ()
addLedgerFault (FaultProxy fixture identity _) stage mode = void $ fixtureRpc fixture (object ["operation" .= ("proxy-rule" :: Text), "id" .= identity, "mode" .= modeName mode, "stage" .= stageName stage])
