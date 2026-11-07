-- | Disposable native ClickHouse server. Never uses a shared developer database.
module ClickHouseMigrate.TestSupport.Server
  ( Server,
    withCandidateServer,
    withReplicatedCandidate,
    queryReplica,
    stopReplica,
    startReplica,
    serverEndpoint,
    serverLogDirectory,
    serverVersion,
    queryServer,
    restartCandidateServer,
  )
where

import ClickHouseMigrate.Prelude
import ClickHouseMigrate.TestSupport.Internal.Fixture
import Data.Aeson (Value, object, (.=))

withCandidateServer :: Text -> (Server -> IO a) -> IO a
withCandidateServer entry action = withFixture entry (action . Server)

serverEndpoint :: Server -> Text
serverEndpoint (Server fixture) = fixtureEndpoint fixture

serverLogDirectory :: Server -> FilePath
serverLogDirectory (Server fixture) = fixtureRoot fixture

serverVersion :: Server -> Text
serverVersion (Server fixture) = fixtureVersion fixture

queryServer :: Server -> Text -> IO Value
queryServer (Server fixture) sql = fixtureRpc fixture (object ["operation" .= ("query" :: Text), "sql" .= sql])

-- | SIGKILL/restart the owned candidate using the same temporary data root.
restartCandidateServer :: Server -> IO ()
restartCandidateServer (Server fixture) = void $ fixtureRpc fixture (object ["operation" .= ("restart" :: Text)])

-- | Keeper and two owned Linux replicas behind a TCP round-robin endpoint.
withReplicatedCandidate :: Text -> (Server -> IO a) -> IO a
withReplicatedCandidate entry action = withFixtureMode ["--replicated"] entry (action . Server)

-- | Complete HTTP observation, including body/status, for independent assertions.
queryReplica :: Server -> Int -> Text -> IO Value
queryReplica (Server fixture) replica sql = fixtureRpc fixture (object ["operation" .= ("query-replica" :: Text), "replica" .= replica, "sql" .= sql])

stopReplica :: Server -> Int -> IO ()
stopReplica (Server fixture) replica = void $ fixtureRpc fixture (object ["operation" .= ("stop-replica" :: Text), "replica" .= replica])

startReplica :: Server -> Int -> IO ()
startReplica (Server fixture) replica = void $ fixtureRpc fixture (object ["operation" .= ("start-replica" :: Text), "replica" .= replica])
