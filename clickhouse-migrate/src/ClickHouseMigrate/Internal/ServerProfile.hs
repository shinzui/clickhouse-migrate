{-# LANGUAGE MultilineStrings #-}

-- | Server-dependent bytes and expectations. Direct policy is frozen by unit pins.
module ClickHouseMigrate.Internal.ServerProfile where

import ClickHouseMigrate.Internal.SqlEnvelope (replicatedEngineSuffix)
import ClickHouseMigrate.Internal.TargetTypes
import ClickHouseMigrate.Internal.Transport
import ClickHouseMigrate.Internal.Types (ChecksumFormat (..))
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (ledgerNamespaceText, serverId)
import Data.Aeson (FromJSON, Key, Object, Result (..), fromJSON)
import Data.Aeson.Key qualified as DataKey
import Data.Aeson.KeyMap qualified as KM
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding

data TargetCheckError = ProbeFailure !TransportOutcome | TargetRejected !TransportError
  deriving stock (Eq, Show)

validateOutcome :: [Text] -> TargetTopology -> TransportOutcome -> Either TargetCheckError ServerIdentity
validateOutcome supportedVersions (DirectServer expected) outcome = case outcome of
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
validateOutcome versions topology@(ReplicatedCluster (ClusterName cluster) replicas) outcome = case outcome of
  AcknowledgedSuccess (Rows [row]) -> do
    actual <- maybe (rejected UnexpectedResponse) (either (const (rejected UnexpectedResponse)) Right . serverId) (get "server_id" row)
    version <- maybe (rejected UnexpectedResponse) Right (get "version" row)
    host <- maybe (rejected UnexpectedResponse) Right (get "host" row)
    macro <- maybe (rejected UnexpectedResponse) Right (get "cluster" row)
    unless (actual `elem` replicas) (rejected ServerIdentityMismatch)
    unless (version `elem` versions) (rejected UnsupportedServer)
    unless (macro == cluster) (rejected ReplicaSetMismatch)
    unless (get "storage_ok" row == Just (1 :: Int)) (rejected CompletionPolicyMismatch)
    unless (all (\(key, value) -> get key row == Just value) (replicatedEffective topology)) (rejected CompletionPolicyMismatch)
    Right (ServerIdentity actual version host)
  AcknowledgedSuccess _ -> rejected UnexpectedResponse
  failure -> Left (ProbeFailure failure)
  where
    rejected code = Left (TargetRejected (TransportError code Nothing Nothing))

replicatedEffective :: TargetTopology -> [(Key, Text)]
replicatedEffective (DirectServer _) = []
replicatedEffective (ReplicatedCluster _ replicas) =
  [("async_insert", "0"), ("mutations_sync", "2"), ("alter_sync", "2"), ("insert_quorum", Text.pack (show (NE.length replicas))), ("insert_quorum_parallel", "0"), ("distributed_ddl_output_mode", "none"), ("select_sequential_consistency", "1"), ("fsync_metadata", "1")]

get :: (FromJSON a) => Key -> Object -> Maybe a
get key row = KM.lookup key row >>= \value -> case fromJSON value of Success result -> Just result; Error _ -> Nothing

identityQuery :: TargetTopology -> ByteString
identityQuery (DirectServer _) =
  """
  SELECT toString(serverUUID()) AS server_id, version() AS version, hostName() AS host,
         toUInt8(getSetting('async_insert')) AS async_insert,
         toUInt8(getSetting('mutations_sync')) AS mutations_sync,
         toUInt8(getSetting('alter_sync')) AS alter_sync
  """
identityQuery topology@(ReplicatedCluster _ _) =
  "SELECT toString(serverUUID()) AS server_id, version() AS version, hostName() AS host, getMacro('cluster') AS cluster, "
    <> Encoding.encodeUtf8 (Text.intercalate ", " [(if key == "distributed_ddl_output_mode" then "toString(getSetting('" <> key <> "'))" else "toString(toUInt64(getSetting('" <> key <> "')))") <> " AS " <> key | (key, _) <- map (\(key, value) -> (DataKey.toText key, value)) (replicatedEffective topology)])
    <> ", toUInt8((SELECT count() FROM system.storage_policies WHERE policy_name='default' AND length(disks)>0)>0 AND (SELECT count() FROM system.disks WHERE name IN (SELECT arrayJoin(disks) FROM system.storage_policies WHERE policy_name='default') AND (type!='Local' OR is_remote OR is_read_only OR is_broken))=0) AS storage_ok"

requestSettings :: TargetTopology -> HttpLimits -> Text -> RequestKind -> [(ByteString, Maybe ByteString)]
requestSettings (DirectServer _) _ identity kind =
  [ ("query_id", Just (Encoding.encodeUtf8 identity)),
    ("async_insert", Just "0"),
    ("mutations_sync", Just "1"),
    ("alter_sync", Just "1"),
    ("fsync_metadata", Just "1"),
    ("wait_end_of_query", Just "1"),
    ("default_format", Just "JSONEachRow")
  ]
    ++ if kind /= Command
      then
        [ ("max_rows_to_read", Just "0"),
          ("max_bytes_to_read", Just "0"),
          ("max_result_rows", Just "0"),
          ("max_result_bytes", Just "0"),
          ("read_overflow_mode", Just "throw"),
          ("result_overflow_mode", Just "throw"),
          ("timeout_overflow_mode", Just "throw"),
          ("sort_overflow_mode", Just "throw")
        ]
      else []
requestSettings topology@(ReplicatedCluster _ _) limits@(HttpLimits micros _) identity kind =
  [("query_id", Just (Encoding.encodeUtf8 identity))]
    ++ [(Encoding.encodeUtf8 (DataKey.toText key), Just (Encoding.encodeUtf8 value)) | (key, value) <- replicatedEffective topology]
    ++ [("distributed_ddl_task_timeout", Just seconds), ("replication_wait_for_inactive_replica_timeout", Just seconds), ("insert_quorum_timeout", Just millis)]
    ++ [("wait_end_of_query", Just "1"), ("default_format", Just "JSONEachRow")]
    ++ drop 7 (requestSettings (DirectServer (NE.head replicas)) limits identity kind)
  where
    ReplicatedCluster _ replicas = topology
    -- DDL and ALTER waits may occur in sequence. Share the budget rather than
    -- allowing each wait to consume the whole HTTP deadline.
    waitSeconds = max 1 ((micros `div` 1000000 - 2) `div` 3)
    seconds = Encoding.encodeUtf8 (Text.pack (show waitSeconds))
    millis = Encoding.encodeUtf8 (Text.pack (show (waitSeconds * 1000)))

-- A scoped membership read needs no REMOTE privilege. Individual sockets still
-- require expected UUIDs; counts do not attest UUIDs on unvisited replicas.
membershipQuery :: TargetTopology -> Maybe ByteString
membershipQuery (DirectServer _) = Nothing
membershipQuery (ReplicatedCluster (ClusterName cluster) _) = Just (Encoding.encodeUtf8 ("SELECT count() AS replicas, uniqExact(shard_num) AS shards FROM system.clusters WHERE cluster='" <> cluster <> "'"))

validateMembership :: TargetTopology -> TransportOutcome -> Either TargetCheckError ()
validateMembership (DirectServer _) _ = Right ()
validateMembership (ReplicatedCluster _ replicas) outcome = case outcome of
  AcknowledgedSuccess (Rows [row]) | get "replicas" row == Just (NE.length replicas), get "shards" row == Just (1 :: Int) -> Right ()
  AcknowledgedSuccess _ -> Left (TargetRejected (TransportError ReplicaSetMismatch Nothing Nothing))
  failure -> Left (ProbeFailure failure)

completionPolicyV1 :: ByteString
completionPolicyV1 = "clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1"

completionPolicy :: TargetTopology -> ByteString
completionPolicy (DirectServer _) = completionPolicyV1
completionPolicy (ReplicatedCluster _ _) = completionPolicyV2

checksumFormat :: TargetTopology -> ChecksumFormat
checksumFormat (DirectServer _) = ChecksumV1
checksumFormat (ReplicatedCluster _ _) = ChecksumV2

databaseEngine :: TargetTopology -> Text
databaseEngine (DirectServer _) = "Atomic"
databaseEngine (ReplicatedCluster _ _) = "Replicated"

quoteIdentifier :: Text -> Text
quoteIdentifier value = "`" <> Text.replace "`" "``" value <> "`"

createDatabase :: TargetTopology -> LedgerNamespace -> Maybe ByteString
createDatabase (DirectServer _) namespace = Just (Encoding.encodeUtf8 ("CREATE DATABASE IF NOT EXISTS " <> quoteIdentifier (ledgerNamespaceText namespace) <> " ENGINE=Atomic"))
createDatabase (ReplicatedCluster _ _) _ = Nothing

createTable :: TargetTopology -> LedgerNamespace -> ByteString
createTable topology namespace = Encoding.encodeUtf8 ("CREATE TABLE IF NOT EXISTS " <> (quoteIdentifier (ledgerNamespaceText namespace) <> ".`events`") <> " " <> columnsSql <> " ENGINE=" <> tableEngine topology <> " ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'")

columnsSql :: Text
columnsSql = "(sequence UInt64, event_id UUID, ledger_id UUID, event String)"

expectedCreate :: TargetTopology -> LedgerNamespace -> Text
expectedCreate topology namespace = "CREATE TABLE " <> ledgerNamespaceText namespace <> ".events (`sequence` UInt64, `event_id` UUID, `ledger_id` UUID, `event` String) ENGINE = " <> expectedEngine topology

expectedEngine :: TargetTopology -> Text
expectedEngine topology = tableEngine topology <> engineTail

engineTail :: Text
engineTail = " ORDER BY sequence SETTINGS fsync_after_insert = 1, fsync_part_directory = 1, storage_policy = 'default', index_granularity = 8192"

tableEngine :: TargetTopology -> Text
tableEngine (DirectServer _) = "MergeTree"
tableEngine (ReplicatedCluster _ _) = "ReplicatedMergeTree"

-- | Entire direct physical shape, including accepted server identifier quoting.
validTableShape :: TargetTopology -> LedgerNamespace -> [Text] -> Bool
validTableShape topology@(DirectServer _) namespace actual =
  let base = ["events", "MergeTree", expectedEngine topology, "sequence", "sequence", "", ""]
      create = expectedCreate topology namespace
      quoted = Text.replace ("CREATE TABLE " <> ledgerNamespaceText namespace <> ".") ("CREATE TABLE " <> quoteIdentifier (ledgerNamespaceText namespace) <> ".") create
   in actual == base ++ [create] || actual == base ++ [quoted]
validTableShape (ReplicatedCluster _ _) namespace actual = case actual of
  ["events", "ReplicatedMergeTree", engine, "sequence", "sequence", "", "", create] ->
    replicatedEngineSuffix engine == Just engineTail
      && let prefix = "CREATE TABLE " <> ledgerNamespaceText namespace <> ".events (`sequence` UInt64, `event_id` UUID, `ledger_id` UUID, `event` String) ENGINE = "
             quoted = Text.replace ("CREATE TABLE " <> ledgerNamespaceText namespace <> ".") ("CREATE TABLE " <> quoteIdentifier (ledgerNamespaceText namespace) <> ".") prefix
          in create == prefix <> engine || create == quoted <> engine
  _ -> False

replicaHealthQuery :: TargetTopology -> LedgerNamespace -> Maybe ByteString
replicaHealthQuery (DirectServer _) _ = Nothing
replicaHealthQuery (ReplicatedCluster _ _) (LedgerNamespace namespace) = Just (Encoding.encodeUtf8 ("SELECT is_readonly, total_replicas FROM system.replicas WHERE database='" <> namespace <> "' AND table='events'"))

validReplicaHealth :: TargetTopology -> [Object] -> Bool
validReplicaHealth (DirectServer _) _ = True
validReplicaHealth (ReplicatedCluster _ replicas) [row] = get "is_readonly" row == Just (0 :: Int) && get "total_replicas" row == Just (NE.length replicas)
validReplicaHealth _ _ = False

requiresLedgerDatabase :: TargetTopology -> Bool
requiresLedgerDatabase (DirectServer _) = False
requiresLedgerDatabase (ReplicatedCluster _ _) = True

completionPolicyV2 :: ByteString
completionPolicyV2 = "clickhouse-migrate/replicated-sync-v1;async_insert=0;mutations_sync=2;alter_sync=2;insert_quorum=all;insert_quorum_parallel=0;distributed_ddl_output_mode=none;select_sequential_consistency=1"

policyForFormat :: ChecksumFormat -> ByteString
policyForFormat ChecksumV1 = completionPolicyV1
policyForFormat ChecksumV2 = completionPolicyV2
