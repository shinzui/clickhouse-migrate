{-# LANGUAGE ExistentialQuantification #-}

-- | Private acquisition and live-scope capability.
module ClickHouseMigrate.Internal.ExclusiveTypes where

import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (TargetKey)
import Control.Exception (Exception)

data AccessError = InvalidAccessStrategy | AcquisitionTimedOut | AcquisitionFailed | AccessLost | AccessScopeClosed | AccessActionFailed | PredecessorQuiescenceRequired | AccessReleaseFailed | AccessReleaseTimedOut
  deriving stock (Eq, Ord, Show)

data AccessDescription = AccessDescription !Text !Text deriving stock (Eq, Show)

data ExclusiveAccess
  = forall lease. ExclusiveAccess
      !AccessDescription
      !Int
      !(TargetKey -> IO lease)
      !(lease -> IO ())
      !(lease -> IO Bool)

data Guard = Guard !AccessDescription !(IO (Either AccessError ()))

data AccessResult a = AccessResult !(Either AccessError a) ![AccessError]
  deriving stock (Eq, Show)

data AccessAcquisitionException = AccessAcquisitionException !AccessError deriving stock (Show)

instance Exception AccessAcquisitionException
