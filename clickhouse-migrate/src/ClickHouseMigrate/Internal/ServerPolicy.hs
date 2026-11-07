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
import ClickHouseMigrate.Internal.ServerProfile (TargetCheckError (..))
import ClickHouseMigrate.Internal.ServerProfile qualified as Profile
import ClickHouseMigrate.Internal.TargetTypes
import ClickHouseMigrate.Internal.Transport
import ClickHouseMigrate.Prelude
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

-- Exact tested-patch policy. Keep coordinated with the checked-in candidate matrix.
supportedVersions :: [Text]
supportedVersions = ["26.8.28.14", "26.3.60.10001.altinitystable", "26.3.60.10002.altinitystable"]

probeTarget :: Http -> TargetConfig -> QueryId -> IO (Either TargetCheckError ServerIdentity)
probeTarget http config identity = validateOutcome config <$> submit http identity JsonRows (Profile.identityQuery (configTopology config))

validateOutcome :: TargetConfig -> TransportOutcome -> Either TargetCheckError ServerIdentity
validateOutcome config = Profile.validateOutcome supportedVersions (configTopology config)

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
        outcome <- probeConnection config connection (QueryId (prefix <> Text.pack (show n))) (Profile.identityQuery (configTopology config))
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
      Right identity -> do
        membership <- case Profile.membershipQuery (configTopology config) of
          Nothing -> pure (Right ())
          Just sql -> Profile.validateMembership (configTopology config) <$> submit http (QueryId (rootId <> "-members")) JsonRows sql
        case membership of
          Left failure -> pure (Left failure)
          Right () -> Right <$> action (Transport (submit http) identity)
