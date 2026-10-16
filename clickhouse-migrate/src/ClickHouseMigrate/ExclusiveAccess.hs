-- | Explicit integration with the application's administrative coordinator.
module ClickHouseMigrate.ExclusiveAccess
  ( ExclusiveAccess,
    externallySerialized,
    AccessDescription,
    accessStrategy,
    accessScope,
    rejectAccessAcquisition,
    AccessError (..),
  )
where

import ClickHouseMigrate.Internal.ExclusiveTypes
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (TargetKey)
import Control.Exception (throwIO)
import Data.Text qualified as Text

-- | Acquire excludes ALL administrators for the complete target, and must be
-- exception safe. Release must not admit a successor until this client cannot
-- submit and all predecessor server work, including ledger INSERTs/DDL, is
-- quiescent. Returning True from 'alive' attests the lease is still held; a lost
-- lease cannot fence already submitted SQL. Types cannot verify these external
-- promises. There is deliberately no default/no-op provider.
externallySerialized :: Text -> Text -> Int -> (TargetKey -> IO lease) -> (lease -> IO ()) -> (lease -> IO Bool) -> Either AccessError ExclusiveAccess
externallySerialized strategy scope acquisitionMicros acquire release alive
  | valid strategy && valid scope && acquisitionMicros > 0 && acquisitionMicros <= 300000000 =
      Right (ExclusiveAccess (AccessDescription strategy scope) acquisitionMicros acquire release alive)
  | otherwise = Left InvalidAccessStrategy
  where
    valid value = not (Text.null (Text.strip value)) && Text.length value <= 1024 && not (Text.any (== '\0') value)

accessStrategy :: AccessDescription -> Text
accessStrategy (AccessDescription strategy _) = strategy

accessScope :: AccessDescription -> Text
accessScope (AccessDescription _ scope) = scope

-- | Reject acquisition with a safe typed code from a caller-owned provider.
rejectAccessAcquisition :: AccessError -> IO a
rejectAccessAcquisition = throwIO . AccessAcquisitionException
