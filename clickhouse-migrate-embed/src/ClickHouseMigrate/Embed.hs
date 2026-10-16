{-# LANGUAGE TemplateHaskell #-}

-- | Compile an ordered package-relative manifest into validated definitions.
module ClickHouseMigrate.Embed (embedComponent, ManifestError (..), ManifestErrorCode (..)) where

import ClickHouseMigrate
import ClickHouseMigrate.Embed.Manifest
import ClickHouseMigrate.Prelude
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text qualified as Text
import Language.Haskell.TH (Exp, Q, listE)
import Language.Haskell.TH.Syntax (addDependentFile, getPackageRoot, lift, runIO)

-- | Paths resolve from the compiler's package root. The manifest directory is
-- the containment boundary for every SQL file. No source files are read at runtime.
embedComponent :: FilePath -> Q Exp
embedComponent file = do
  root <- getPackageRoot
  result <- runIO (loadComponentFiles root file)
  case result of
    Left failure -> fail ("clickhouse-migrate-embed: " ++ show failure)
    Right (manifest, sources, paths) -> case constructComponent manifest sources of
      Left failure -> fail ("clickhouse-migrate-embed: " ++ show failure)
      Right _ -> do
        mapM_ addDependentFile (Set.toAscList (Set.fromList paths))
        body <- componentExpression manifest sources
        [|
          case $(pure body) of
            Right component -> component
            Left _ -> error "clickhouse-migrate-embed: generated definition failed validation"
          |]

textExpression :: Text -> Q Exp
textExpression value = [|Text.pack $(lift (Text.unpack value))|]

componentExpression :: Manifest -> [(FilePath, ByteString)] -> Q Exp
componentExpression (Manifest name deps migrations) sources =
  [|
    do
      definitions <- sequence $(listE (map migrationExpression migrations))
      migrationComponentFromList $(textExpression name) (Set.fromList $(listE (map textExpression deps))) definitions
    |]
  where
    migrationExpression (ManifestMigration migration description steps) =
      [|
        do
          definitions <- sequence $(listE (map stepExpression steps))
          value <- sqlMigrationFromList $(textExpression migration) definitions
          pure (withMigrationDescription $(descriptionExpression description) value)
        |]
    stepExpression (ManifestStep step path) = case lookup path sources of
      Nothing -> fail "clickhouse-migrate-embed: validated source missing"
      Just bytes -> [|sqlStep $(textExpression step) (BS.pack $(lift (BS.unpack bytes)))|]
    descriptionExpression Nothing = [|Nothing|]
    descriptionExpression (Just description) = [|Just $(textExpression description)|]
