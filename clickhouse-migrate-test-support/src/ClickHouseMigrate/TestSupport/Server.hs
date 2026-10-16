-- | Disposable native ClickHouse server. Never uses a shared developer database.
module ClickHouseMigrate.TestSupport.Server
  ( Server,
    withCandidateServer,
    serverEndpoint,
    serverLogDirectory,
    serverVersion,
    queryServer,
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
