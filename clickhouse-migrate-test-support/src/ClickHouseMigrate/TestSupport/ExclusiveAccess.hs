-- | Conservative HOST-LOCAL development/test coordination. All administrators
-- must share this host, canonical lock root and target key. Not distributed fencing.
module ClickHouseMigrate.TestSupport.ExclusiveAccess (hostLocalExclusiveAccess) where

import ClickHouseMigrate.ExclusiveAccess
import ClickHouseMigrate.Ledger (QuiescenceEvidence, quiescenceTarget)
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (targetKeyText)
import Control.Concurrent (threadDelay)
import Control.Exception (mask, onException)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.Text.Encoding qualified as Encoding
import Numeric (showHex)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.FileLock (SharedExclusive (Exclusive), tryLockFile, unlockFile)
import System.FilePath ((</>))

-- | A persistent marker survives BOTH normal release and process death: OS lock
-- release cannot prove server quiescence. A later acquisition requires explicit
-- target-bound external evidence, even after a clean client exit. This deliberate
-- inconvenience prevents this development adapter from silently authorizing a
-- successor after a lost response. Evidence remains the caller's responsibility.
hostLocalExclusiveAccess :: FilePath -> Int -> Maybe QuiescenceEvidence -> IO (Either AccessError ExclusiveAccess)
hostLocalExclusiveAccess directory micros evidence = do
  createDirectoryIfMissing True directory
  root <- canonicalizePath directory
  let acquire target = mask $ \restore -> do
        let digest = concatMap (\byte -> let value = showHex byte "" in replicate (2 - length value) '0' ++ value) (BS.unpack (SHA256.hash (Encoding.encodeUtf8 (targetKeyText target))))
            lockPath = root </> digest ++ ".lock"
            marker = root </> digest ++ ".requires-quiescence"
            wait =
              tryLockFile lockPath Exclusive >>= \case
                Nothing -> restore (threadDelay 10000) >> wait
                Just lease -> pure lease
        lease <- wait
        ( do
            dirty <- doesFileExist marker
            when dirty $ case evidence of
              Just assertion | quiescenceTarget assertion == target -> pure ()
              _ -> rejectAccessAcquisition PredecessorQuiescenceRequired
            BS.writeFile marker (Encoding.encodeUtf8 (targetKeyText target))
            pure lease
          )
          `onException` unlockFile lease
  pure (externallySerialized "host-local-os-file-lock" "one host and canonical lock root; complete target key; persistent quiescence marker" micros acquire unlockFile (const (pure True)))
