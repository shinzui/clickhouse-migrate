-- | Fault controls for an owned fixture, with request evidence excluding SQL/auth.
module ClickHouseMigrate.TestSupport.FaultProxy
  ( FaultProxy,
    FaultMode (..),
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

data FaultMode = Pass | DropResponse | TruncateResponse | LateError | Redirect | CloseConnection | CloseReusedConnection | DelayResponse | DelayFirstResponse | UnsupportedVersion | PrereleaseVersion | WeakenedPolicy | SwitchIdentityAfterResponse
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
modeName DropResponse = "drop"
modeName TruncateResponse = "truncate"
modeName LateError = "late-error"
modeName Redirect = "redirect"
modeName CloseConnection = "close"
modeName CloseReusedConnection = "close-second"
modeName DelayResponse = "delay"
modeName DelayFirstResponse = "delay-first"
modeName UnsupportedVersion = "unsupported-version"
modeName PrereleaseVersion = "prerelease-version"
modeName WeakenedPolicy = "weakened-policy"
modeName SwitchIdentityAfterResponse = "switch-identity"

setFaultForQuery :: FaultProxy -> Text -> FaultMode -> IO ()
setFaultForQuery (FaultProxy fixture identity _) query mode = void $ fixtureRpc fixture (object ["operation" .= ("proxy-mode" :: Text), "id" .= identity, "mode" .= modeName mode, "queryId" .= query])

proxyConnections :: FaultProxy -> IO Int
proxyConnections (FaultProxy fixture identity _) = fixtureRpc fixture (object ["operation" .= ("proxy-open-connections" :: Text), "id" .= identity]) >>= fieldResult
  where
    fieldResult value = case Data.Aeson.fromJSON value of Data.Aeson.Success number -> pure number; Data.Aeson.Error _ -> fail "Invalid proxy connection count"
