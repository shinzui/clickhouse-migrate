{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import ClickHouseMigrate
import ClickHouseMigrate.Embed (embedComponent)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text
import Numeric (showHex)

component :: MigrationComponent
component = $(embedComponent "component/manifest.json")

main :: IO ()
main = case migrationPlan (component :| []) of
  Left _ -> fail "Embedded plan failed"
  Right plan -> mapM_ render (concatMap (NE.toList . componentMigrations) (NE.toList (inspectPlan plan)))
  where
    render migration = do
      putStrLn (Text.unpack (migrationChecksumHex (migrationChecksum migration)))
      mapM_ (putStrLn . concatMap hex . BS.unpack . stepSql) (NE.toList (migrationSteps migration))
    hex byte = case showHex byte "" of [c] -> ['0', c]; chars -> chars
