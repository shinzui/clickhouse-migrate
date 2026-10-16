{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import ClickHouseMigrate
import ClickHouseMigrate.Embed (embedComponent)
import ClickHouseMigrate.Embed.Manifest qualified as Manifest
import ClickHouseMigrate.Prelude
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Char8
import Data.List (isInfixOf)

embedded :: MigrationComponent
embedded = $(embedComponent "test/fixtures/component/manifest.json")

main :: IO ()
main = do
  bytes <- BS.readFile "test/fixtures/component/manifest.json"
  manifest <- either (fail . show) pure (Manifest.decodeManifest bytes)
  create <- BS.readFile "test/fixtures/component/sql/create.sql"
  seed <- BS.readFile "test/fixtures/component/sql/seed.sql"
  ordinary <- either (fail . show) pure (Manifest.constructComponent manifest [("sql/create.sql", create), ("sql/seed.sql", seed)])
  unless (embedded == ordinary) (fail "Embedded bytes differ from public construction")
  _ <- either (fail . show) pure (migrationPlan (embedded :| []))
  mapM_
    ( \(expected, invalid) -> case Manifest.decodeManifest invalid of
        Left (Manifest.ManifestError actual _ _) | actual == expected -> pure ()
        _ -> fail ("Manifest error mismatch: " ++ show expected)
    )
    [ (Manifest.DuplicateKey, "{\"component\":\"a\",\"component\":\"b\"}"),
      (Manifest.DuplicateKey, "{\"name\":1,\"\\u006eame\":2}"),
      (Manifest.DuplicateKey, "{\"migrations\":[{\"name\":1,\"name\":2}]}"),
      (Manifest.UnknownField, "{\"unknown\":1}"),
      (Manifest.MissingField, "{}"),
      (Manifest.UnsupportedManifestVersion, "{\"manifestVersion\":2}"),
      (Manifest.WrongType, "[]"),
      (Manifest.InvalidJson, "{} trailing"),
      (Manifest.InvalidJson, "{broken"),
      (Manifest.DuplicateDependency, "{\"manifestVersion\":1,\"component\":\"a\",\"dependencies\":[\"a\",\"a\"],\"migrations\":[]}")
    ]
  case Manifest.constructComponent (Manifest.Manifest "a" [] []) [] of
    Left (Manifest.ManifestError Manifest.InvalidDefinition _ _) -> pure ()
    _ -> fail "Empty manifest migrations accepted"
  let secret = "SQL_SECRET_MARKER"
  case Manifest.constructComponent (Manifest.Manifest "a" [] [Manifest.ManifestMigration "m" Nothing [Manifest.ManifestStep "s" "query.sql"]]) [("query.sql", Char8.pack secret)] of
    Left failure | not (secret `isInfixOf` show failure) -> pure ()
    _ -> fail "Invalid SQL accepted or leaked in diagnostics"
  putStrLn "Embedded bytes match public construction; manifest ambiguity and redaction checks pass."
