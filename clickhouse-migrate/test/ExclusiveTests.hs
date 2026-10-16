module ExclusiveTests (exclusiveTests) where

import ClickHouseMigrate.ExclusiveAccess
import ClickHouseMigrate.Internal.Exclusive
import ClickHouseMigrate.Internal.ExclusiveTypes (AccessResult (..))
import ClickHouseMigrate.Target (targetKey)
import Control.Concurrent (threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeAsyncException, throwIO, try)
import Control.Monad (unless)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail ("exclusive: " ++ label))

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

exclusiveTests :: IO ()
exclusiveTests = do
  target <- right (targetKey "unit/isolated")
  released <- newIORef (0 :: Int)
  let provider release = right (externallySerialized "controlled-unit-provider" "complete isolated target" 1000000 (const (pure ())) release (const (pure True)))
  normal <- provider (const (modifyIORef' released (+ 1)))
  result <- withExclusive normal target $ \guard -> checkGuard guard
  assert "normal scoped observation" (case result of AccessResult (Right (Right ())) [] -> True; _ -> False)
  readIORef released >>= assert "release once" . (== 1)
  escaped <- withExclusive normal target pure
  case escaped of
    AccessResult (Right guard) [] -> checkGuard guard >>= assert "escaped guard closed" . (== Left AccessScopeClosed)
    _ -> fail "Unexpected guard qualification result"
  cancelled <- try @SomeAsyncException (withExclusive normal target (const (throwIO ThreadKilled :: IO ())))
  assert "action cancellation rethrown" (either (const True) (const False) cancelled)
  readIORef released >>= assert "cancellation still releases" . (== 3)
  interruptedRelease <- provider (const (throwIO ThreadKilled))
  cleanupCancellation <- try @SomeAsyncException (withExclusive interruptedRelease target (const (fail "Primary synchronous failure" :: IO ())))
  assert "cleanup cancellation not swallowed by primary failure" (either (const True) (const False) cleanupCancellation)
  broken <- provider (const (fail "Synthetic release failure"))
  both <- withExclusive broken target (const (fail "Primary synchronous failure" :: IO ()))
  assert "primary and release failure separate" (case both of AccessResult (Left AccessActionFailed) [AccessReleaseFailed] -> True; _ -> False)
  delayed <- provider (const (threadDelay 2000000))
  bounded <- withExclusive delayed target (const (pure ()))
  assert "release deadline distinct from command success" (case bounded of AccessResult (Right ()) [AccessReleaseTimedOut] -> True; _ -> False)
  alive <- newIORef True
  lease <- right (externallySerialized "controlled-lease" "complete target" 1000000 (const (pure ())) (const (pure ())) (const (readIORef alive)))
  observed <- withExclusive lease target $ \guard -> do
    writeIORef alive False
    first <- checkGuard guard
    writeIORef alive True
    second <- checkGuard guard
    pure (first, second)
  assert "lost lease cannot resurrect" (case observed of AccessResult (Right (Left AccessLost, Left AccessLost)) [] -> True; _ -> False)
  putStrLn "Exclusive scope, cancellation, lease loss and separate bounded release checks passed."
