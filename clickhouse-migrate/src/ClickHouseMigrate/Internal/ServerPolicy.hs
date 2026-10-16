{-# LANGUAGE MultilineStrings #-}

-- | Pinned-server admission before application/ledger work. No initialization.
module ClickHouseMigrate.Internal.ServerPolicy
  ( TargetCheckError (..),
    probeTarget,
    withTransport,
    withTransportChecked,
    supportedVersions,
  )
where

import ClickHouseMigrate.Internal.Checksum qualified as Checksum
import ClickHouseMigrate.Internal.Http (Http, probeConnection, submit, withHttpAdmissionChecked)
import ClickHouseMigrate.Internal.TargetTypes
import ClickHouseMigrate.Internal.Transport
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (serverId)
import Data.Aeson (FromJSON, Key, Object, Result (..), fromJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

-- Exact tested-patch policy. Keep coordinated with the checked-in candidate matrix.
supportedVersions :: [Text]
supportedVersions = ["26.8.28.14"]

data TargetCheckError = ProbeFailure !TransportOutcome | TargetRejected !TransportError
  deriving stock (Eq, Show)

probeTarget :: Http -> TargetConfig -> QueryId -> IO (Either TargetCheckError ServerIdentity)
probeTarget http config identity = validateOutcome config <$> submit http identity JsonRows identityQuery

validateOutcome :: TargetConfig -> TransportOutcome -> Either TargetCheckError ServerIdentity
validateOutcome (TargetConfig _ _ expected _ _ _ _) outcome = case outcome of
  AcknowledgedSuccess (Rows [row]) -> validate row
  AcknowledgedSuccess _ -> rejected UnexpectedResponse
  failure -> Left (ProbeFailure failure)
  where
    rejected code = Left (TargetRejected (TransportError code Nothing Nothing))
    validate row
      | Set.fromList (KM.keys row) /= Set.fromList ["server_id", "version", "host", "async_insert", "mutations_sync", "alter_sync"] = rejected UnexpectedResponse
      | otherwise = case (get "server_id" row, get "version" row, get "host" row, get "async_insert" row, get "mutations_sync" row, get "alter_sync" row) of
          (Just uuid, Just version, Just host, Just (async :: Int), Just (mutation :: Int), Just (alter :: Int)) -> case serverId uuid of
            Left _ -> rejected UnexpectedResponse
            Right actual
              | actual /= expected -> rejected ServerIdentityMismatch
              | version `notElem` supportedVersions -> rejected UnsupportedServer
              | async /= 0 || mutation /= 1 || alter /= 1 -> rejected CompletionPolicyMismatch
              | otherwise -> Right (ServerIdentity actual version host)
          _ -> rejected UnexpectedResponse

get :: (FromJSON a) => Key -> Object -> Maybe a
get key row = KM.lookup key row >>= \value -> case fromJSON value of Success result -> Just result; Error _ -> Nothing

identityQuery :: ByteString
identityQuery =
  """
  SELECT toString(serverUUID()) AS server_id, version() AS version, hostName() AS host,
         toUInt8(getSetting('async_insert')) AS async_insert,
         toUInt8(getSetting('mutations_sync')) AS mutations_sync,
         toUInt8(getSetting('alter_sync')) AS alter_sync
  """

-- The only production constructor for a checked transport. Its Http resources
-- close at scope exit; a capability used after exit cannot submit again.
withTransport :: TargetConfig -> QueryId -> (Transport -> IO a) -> IO (ScopeResult (Either TargetCheckError a))
withTransport config probeId = withTransportChecked config probeId (pure (Right ()))

withTransportChecked :: TargetConfig -> QueryId -> IO (Either TransportError ()) -> (Transport -> IO a) -> IO (ScopeResult (Either TargetCheckError a))
withTransportChecked config probeId@(QueryId rootId) check action = do
  counter <- newIORef (0 :: Int)
  let prefix = "chm-admission-" <> Checksum.digestHex (Checksum.digest (Encoding.encodeUtf8 rootId)) <> "-"
      admit connection = do
        n <- atomicModifyIORef' counter (\old -> (old + 1, old))
        outcome <- probeConnection config connection (QueryId (prefix <> Text.pack (show n))) identityQuery
        pure $ case validateOutcome config outcome of
          Right _ -> Right ()
          Left (TargetRejected failure) -> Left failure
          Left (ProbeFailure (NotSubmitted failure)) -> Left failure
          Left (ProbeFailure (SubmissionUncertain failure)) -> Left failure
          Left (ProbeFailure (ObservedServerFailure failure)) -> Left failure
          Left _ -> Left (TransportError UnexpectedResponse Nothing Nothing)
  withHttpAdmissionChecked config admit check $ \http -> do
    checked <- probeTarget http config probeId
    case checked of
      Left failure -> pure (Left failure)
      Right identity -> Right <$> action (Transport (submit http) identity)
