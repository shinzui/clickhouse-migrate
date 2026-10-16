-- | Versioned byte encoder. Keep in agreement with docs/user/contracts/checksum-v1.md.
module ClickHouseMigrate.Internal.Checksum
  ( completionPolicyV1,
    encodeStepV1,
    encodeMigrationV1,
    digest,
    digestHex,
  )
where

import ClickHouseMigrate.Prelude
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Builder (Builder, byteString, toLazyByteString, word64BE)
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Numeric (showHex)

completionPolicyV1 :: ByteString
completionPolicyV1 = "clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1"

field :: ByteString -> Builder
field bs = word64BE (fromIntegral (BS.length bs)) <> byteString bs

encodeStepV1 :: Text -> Text -> Text -> ByteString -> ByteString
encodeStepV1 component migration step sql =
  Lazy.toStrict $
    toLazyByteString $
      byteString "clickhouse-migrate/step\0v1\0"
        <> field completionPolicyV1
        <> foldMap (field . Text.encodeUtf8) [component, migration, step]
        <> field sql

encodeMigrationV1 :: Text -> Text -> [ByteString] -> ByteString
encodeMigrationV1 component migration steps =
  Lazy.toStrict $
    toLazyByteString $
      byteString "clickhouse-migrate/migration\0v1\0"
        <> field completionPolicyV1
        <> foldMap (field . Text.encodeUtf8) [component, migration]
        <> word64BE (fromIntegral (length steps))
        <> foldMap field steps

digest :: ByteString -> ByteString
digest = SHA256.hash

digestHex :: ByteString -> Text
digestHex = Text.pack . concatMap hex . BS.unpack
  where
    hex byte = case showHex byte "" of
      [c] -> ['0', c]
      cs -> cs
