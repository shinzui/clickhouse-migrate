-- | Fresh client identities exist before any request is submitted.
module ClickHouseMigrate.Internal.Identity (freshUuid, diagnosticTime) where

import ClickHouseMigrate.Prelude
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Numeric (showHex)
import System.Entropy (getEntropy)

freshUuid :: IO Text
freshUuid = do
  bytes <- BS.unpack <$> getEntropy 16
  let normalized = [if i == 6 then (b .&. 15) .|. 64 else if i == 8 then (b .&. 63) .|. 128 else b | (i, b) <- zip [0 :: Int ..] bytes]
      hex = concatMap (\b -> let value = showHex b "" in replicate (2 - length value) '0' ++ value) normalized
  if length hex /= 32
    then fail "Insufficient identity entropy"
    else
      pure (Text.pack (take 8 hex ++ "-" ++ take 4 (drop 8 hex) ++ "-" ++ take 4 (drop 12 hex) ++ "-" ++ take 4 (drop 16 hex) ++ "-" ++ drop 20 hex))

diagnosticTime :: IO Text
diagnosticTime = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" <$> getCurrentTime
