-- | Content-qualified Cabal entry point. Never executes application SQL.
module Main (main) where

import ClickHouseMigrate.Embed.Manifest (constructComponent, loadComponentFiles)
import ClickHouseMigrate.Prelude
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Builder (Builder, byteString, toLazyByteString, word64BE)
import Data.ByteString.Lazy qualified as Lazy
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Numeric (showHex)
import System.Environment (getArgs)
import System.Process (callProcess)

main :: IO ()
main = do
  args <- getArgs
  (inputs, command, options) <- either fail pure (parseArguments [] args)
  chunks <- traverse fingerprintInput inputs
  let hash = SHA256.hash (Lazy.toStrict (toLazyByteString (byteString "clickhouse-migrate/embed-build-v1\0" <> mconcat chunks)))
      hex byte = case showHex byte "" of [c] -> ['0', c]; chars -> chars
      token = concatMap hex (BS.unpack hash)
  -- The content token changes Cabal's build configuration before its file
  -- monitor can incorrectly skip GHC. Force-recomp makes the resulting compiler
  -- invocation independent of GHC's own source timestamp shortcuts.
  callProcess "cabal" ([command, "--ghc-options=-fforce-recomp -DCHM_EMBED_INPUT_" ++ token] ++ options)

parseArguments :: [(FilePath, FilePath)] -> [String] -> Either String ([(FilePath, FilePath)], String, [String])
parseArguments inputs ("--input" : root : manifest : rest) = parseArguments (inputs ++ [(root, manifest)]) rest
parseArguments inputs ("--" : command : options)
  | not (null inputs) && command `elem` ["build", "test", "haddock"] = Right (inputs, command, options)
parseArguments _ _ = Left "Usage: clickhouse-migrate-embed-build --input PACKAGE_ROOT MANIFEST [--input ROOT MANIFEST ...] -- build|test|haddock [CABAL_ARGS...]"

fingerprintInput :: (FilePath, FilePath) -> IO Builder
fingerprintInput (root, manifest) = do
  result <- loadComponentFiles root manifest
  (parsed, sources, paths) <- either (fail . show) pure result
  void (either (fail . show) pure (constructComponent parsed sources))
  fields <-
    traverse
      ( \path -> do
          bytes <- BS.readFile path
          pure (field (Encoding.encodeUtf8 (Text.pack path)) <> field bytes)
      )
      (Set.toAscList (Set.fromList paths))
  pure (mconcat fields)
  where
    field bytes = word64BE (fromIntegral (BS.length bytes)) <> byteString bytes
