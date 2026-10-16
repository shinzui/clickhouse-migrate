-- | Scope ownership encloses transport cleanup. Cancellation is always rethrown.
module ClickHouseMigrate.Internal.Exclusive (withExclusive, checkGuard, guardDescription) where

import ClickHouseMigrate.Internal.ExclusiveTypes
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (TargetKey)
import Control.Exception (SomeAsyncException, SomeException, fromException, mask, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Timeout (timeout)

withExclusive :: ExclusiveAccess -> TargetKey -> (Guard -> IO a) -> IO (AccessResult a)
withExclusive (ExclusiveAccess description micros acquire release alive) target action = mask $ \restore -> do
  acquired <- try @SomeException (timeout micros (acquire target))
  case acquired of
    Left exception | asynchronous exception -> throwIO exception
    Left exception -> pure (AccessResult (Left (case fromException exception of Just (AccessAcquisitionException failure) -> failure; _ -> AcquisitionFailed)) [])
    Right Nothing -> pure (AccessResult (Left AcquisitionTimedOut) [])
    Right (Just lease) -> do
      active <- newIORef True
      lost <- newIORef False
      let check = do
            live <- readIORef active
            previouslyLost <- readIORef lost
            if not live
              then pure (Left AccessScopeClosed)
              else
                if previouslyLost
                  then pure (Left AccessLost)
                  else do
                    observation <- try @SomeException (timeout 1000000 (alive lease))
                    case observation of
                      Left exception | asynchronous exception -> throwIO exception
                      Right (Just True) -> pure (Right ())
                      _ -> writeIORef lost True >> pure (Left AccessLost)
      result <- try @SomeException (restore (action (Guard description check)))
      writeIORef active False
      released <- try @SomeException (timeout 1000000 (release lease))
      let cleanup = case released of Right (Just ()) -> []; Right Nothing -> [AccessReleaseTimedOut]; Left _ -> [AccessReleaseFailed]
      case result of
        Left exception | asynchronous exception -> throwIO exception
        _ -> case released of
          Left exception | asynchronous exception -> throwIO exception
          _ -> pure (AccessResult (either (const (Left AccessActionFailed)) Right result) cleanup)
  where
    asynchronous exception = isJust (fromException exception :: Maybe SomeAsyncException)

checkGuard :: Guard -> IO (Either AccessError ())
checkGuard (Guard _ check) = check

guardDescription :: Guard -> AccessDescription
guardDescription (Guard description _) = description
