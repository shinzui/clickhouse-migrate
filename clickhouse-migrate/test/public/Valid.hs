{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import ClickHouseMigrate
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set

libraryA :: Either DefinitionError MigrationComponent
libraryA = do
  step <- sqlStep "create" "CREATE TABLE app.a (id UInt64) ENGINE=MergeTree ORDER BY id"
  migration <- sqlMigration "0001" (step :| [])
  migrationComponent "library-a" Set.empty (withMigrationDescription (Just "A") migration :| [])

libraryB :: Either DefinitionError MigrationComponent
libraryB = do
  step <- sqlStep "create" "CREATE TABLE app.b (id UInt64) ENGINE=MergeTree ORDER BY id"
  migration <- sqlMigration "0001" (step :| [])
  migrationComponent "library-b" (Set.singleton "library-a") (migration :| [])

main :: IO ()
main = case (libraryA, libraryB) of
  (Right a, Right b) -> case do
    ca <- componentName "library-a"
    cb <- componentName "library-b"
    name <- migrationName "0001"
    pure [migrationIdFromNames ca name, migrationIdFromNames cb name] of
    Right ids -> case scheduledMigrationPlanFromList [a, b] ids of
      Right p
        | map (componentNameText . componentViewName) (NE.toList (inspectPlan p)) == ["library-a", "library-b"] ->
            mapM_ (print . migrationChecksumHex . migrationChecksum) (concatMap (NE.toList . componentMigrations) (NE.toList (inspectPlan p)))
      _ -> fail "Public plan composition failed"
    _ -> fail "Public schedule identity failed"
  _ -> fail "Public authoring failed"
