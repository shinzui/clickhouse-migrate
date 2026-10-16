-- | Dedicated direct HTTP resources, bounded full responses, and no replay.
module ClickHouseMigrate.Internal.Http (Http, withHttp, withHttpAdmission, withHttpFinalizer, probeConnection, submit) where

import ClickHouseMigrate.Internal.TargetTypes
import ClickHouseMigrate.Internal.Transport hiding (request)
import ClickHouseMigrate.Prelude
import Control.Concurrent (ThreadId, myThreadId, threadDelay, throwTo)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeAsyncException, SomeException, bracket, finally, fromException, mask, onException, throwIO, try)
import Data.Aeson (Object, eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Char8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.Internal qualified as Internal
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data Http = Http !TargetConfig !HTTP.Manager !(IORef Bool) !(MVar ()) !(IORef Bool) !(IORef [ThreadId])

data AdmissionFailure = AdmissionFailure !TransportError deriving stock (Show)

instance Exception AdmissionFailure

safeError :: TransportErrorCode -> TransportError
safeError c = TransportError c Nothing Nothing

-- http-client's closeManager is a no-op. Track/close every owned socket instead.
-- Async cancellation is rethrown after bounded cleanup; never turn it into success.
withHttp :: TargetConfig -> (Http -> IO a) -> IO (ScopeResult a)
withHttp config = withHttpFinalizer config (pure ())

-- Private qualification hook runs through the real cleanup path after sockets.
withHttpFinalizer :: TargetConfig -> IO () -> (Http -> IO a) -> IO (ScopeResult a)
withHttpFinalizer config finalizer = withHttpOwned config (const (pure (Right ()))) finalizer

withHttpAdmission :: TargetConfig -> (Internal.Connection -> IO (Either TransportError ())) -> (Http -> IO a) -> IO (ScopeResult a)
withHttpAdmission config admit = withHttpOwned config admit (pure ())

withHttpOwned :: TargetConfig -> (Internal.Connection -> IO (Either TransportError ())) -> IO () -> (Http -> IO a) -> IO (ScopeResult a)
withHttpOwned config admit finalizer action = mask $ \restore -> do
  submitted <- newIORef False
  active <- newIORef True
  connections <- newIORef [(0 :: Int, finalizer)]
  nextConnection <- newIORef (1 :: Int)
  inflight <- newIORef []
  gate <- newMVar ()
  let track factory = do
        open <- factory
        pure $ \address host port -> mask $ \restoreOpen -> do
          conn <- restoreOpen (open address host port)
          closeGate <- newMVar False
          connectionId <- atomicModifyIORef' nextConnection (\old -> (old + 1, old))
          let close = modifyMVar_ closeGate $ \closed ->
                if closed
                  then pure True
                  else do
                    Internal.connectionClose conn `onException` writeIORef active False
                    atomicModifyIORef' connections (\old -> (filter ((/= connectionId) . fst) old, ()))
                    pure True
              wrapped =
                conn
                  { Internal.connectionWrite = \bytes -> do
                      live <- readIORef active
                      unless live (fail "HTTP scope closed")
                      writeIORef submitted True
                      Internal.connectionWrite conn bytes,
                    Internal.connectionClose = close
                  }
          atomicModifyIORef' connections (\old -> ((connectionId, close) : old, ()))
          live <- readIORef active
          unless live (close >> fail "HTTP scope closed")
          admitted <- restoreOpen (admit conn) `onException` close
          case admitted of
            Left failure -> close >> throwIO (AdmissionFailure failure)
            Right () -> pure ()
          stillLive <- readIORef active
          unless stillLive (close >> fail "HTTP scope closed")
          pure wrapped
      settings =
        HTTP.managerSetProxy
          HTTP.noProxy
          tlsManagerSettings
            { HTTP.managerConnCount = 1,
              HTTP.managerIdleConnectionCount = 1,
              HTTP.managerRetryableException = const False,
              HTTP.managerRawConnection = track (HTTP.managerRawConnection tlsManagerSettings),
              HTTP.managerTlsConnection = track (HTTP.managerTlsConnection tlsManagerSettings)
            }
  manager <- HTTP.newManager settings
  result <- try @SomeException (restore (action (Http config manager submitted gate active inflight)))
  writeIORef active False
  owner <- myThreadId
  running <- readIORef inflight
  cancelled <- try @SomeException $ timeout 1000000 $ do
    mapM_ (\thread -> unless (thread == owner) (throwTo thread ThreadKilled)) running
    let wait = do
          remaining <- readIORef inflight
          unless (null remaining) (threadDelay 1000 >> wait)
    wait
  closers <- map snd <$> readIORef connections
  closed <- mapM (\close -> try @SomeException (timeout 1000000 close)) closers
  let observations = cancelled : closed
      cleanup =
        concatMap
          ( \case
              Right (Just ()) -> []
              Right Nothing -> [safeError CleanupTimedOut]
              Left _ -> [safeError CleanupFailed]
          )
          observations
      cancelledDuringCleanup = [exception | Left exception <- observations, isJust (fromException exception :: Maybe SomeAsyncException)]
  case result of
    Left exception | isJust (fromException exception :: Maybe SomeAsyncException) -> throwIO exception
    _ | exception : _ <- cancelledDuringCleanup -> throwIO exception
    Left _ -> pure (ScopeResult (Left (safeError ClientScopeFailed)) cleanup)
    Right value -> pure (ScopeResult (Right value) cleanup)

submit :: Http -> QueryId -> RequestKind -> ByteString -> IO TransportOutcome
submit (Http (TargetConfig _ (DirectEndpoint endpoint) _ _ _ (Credentials user password) (HttpLimits micros maxBytes)) manager submitted gate active inflight) (QueryId identity) kind sql = registered inflight $ withMVar gate $ \() -> do
  writeIORef submitted False
  live <- readIORef active
  if not live || BS.null sql || BS.elem 0 sql
    then pure (NotSubmitted (safeError InvalidRequest))
    else do
      result <- try @SomeException $ timeout micros $ do
        request <- makeRequest endpoint user password micros identity sql
        HTTP.withResponse request manager $ \response -> do
          bytes <- readBounded maxBytes (HTTP.responseBody response)
          pure $ case bytes of
            Left () -> SubmissionUncertain (safeError ResponseTooLarge)
            Right body -> classify kind (statusCode (HTTP.responseStatus response)) (lookup "X-ClickHouse-Exception-Code" (HTTP.responseHeaders response)) body
      didSubmit <- readIORef submitted
      case result of
        Left exception | isJust (fromException exception :: Maybe SomeAsyncException) -> throwIO exception
        Left exception | Just (AdmissionFailure failure) <- fromException exception -> pure (NotSubmitted failure)
        Left _ -> pure $ if didSubmit then SubmissionUncertain (safeError ResponseInterrupted) else NotSubmitted (safeError ConnectionFailed)
        Right Nothing -> pure $ if didSubmit then SubmissionUncertain (safeError DeadlineExpired) else NotSubmitted (safeError DeadlineExpired)
        Right (Just outcome) -> pure outcome

readBounded :: Int -> HTTP.BodyReader -> IO (Either () ByteString)
readBounded limit reader = loop 0 []
  where
    loop size chunks = do
      chunk <- HTTP.brRead reader
      if BS.null chunk
        then pure (Right (BS.concat (reverse chunks)))
        else
          if BS.length chunk > limit - size
            then pure (Left ())
            else loop (size + BS.length chunk) (chunk : chunks)

classify :: RequestKind -> Int -> Maybe ByteString -> ByteString -> TransportOutcome
classify kind status exceptionHeader body
  | status >= 300 && status < 400 = ObservedServerFailure (TransportError RedirectRejected (Just status) serverCode)
  | status /= 200 || isJust exceptionHeader || isJust bodyCode = ObservedServerFailure (TransportError ServerRejected (Just status) serverCode)
  | kind == Command = if BS.all (`elem` [9, 10, 13, 32]) body then AcknowledgedSuccess CommandAccepted else unexpected
  | otherwise = case traverse (eitherDecodeStrict' :: ByteString -> Either String Object) (filter (not . BS.all (`elem` [9, 13, 32])) (Char8.lines body)) of
      Left _ -> unexpected
      Right rows -> AcknowledgedSuccess (Rows rows)
  where
    headerCode = exceptionHeader >>= readMaybe . Char8.unpack
    bodyCode = Char8.stripPrefix "Code: " body >>= readMaybe . Char8.unpack . Char8.takeWhile (\c -> c >= '0' && c <= '9')
    serverCode = case headerCode of Just code -> Just code; Nothing -> bodyCode
    unexpected = SubmissionUncertain (TransportError UnexpectedResponse (Just status) serverCode)

-- Probe on exactly the new owned connection, before returning it to the pool.
-- dummyManaged supplies no cleanup/replay; the factory owns this socket and closes
-- it on failure. The bounded response parser is the same as for ordinary requests.
probeConnection :: TargetConfig -> Internal.Connection -> QueryId -> ByteString -> IO TransportOutcome
probeConnection (TargetConfig _ (DirectEndpoint endpoint) _ _ _ (Credentials user password) (HttpLimits micros maxBytes)) connection (QueryId identity) sql = do
  result <- try @SomeException $ timeout micros $ do
    request <- makeRequest endpoint user password micros identity sql
    continuation <- Internal.requestBuilder request connection
    bracket
      (Internal.getResponse (Just (Internal.MaxHeaderLength 4096)) (Just (Internal.MaxNumberHeaders 64)) (Just micros) request (Internal.dummyManaged connection) continuation)
      HTTP.responseClose
      ( \response -> do
          body <- readBounded maxBytes (HTTP.responseBody response)
          pure $ case body of
            Left () -> SubmissionUncertain (safeError ResponseTooLarge)
            Right bytes -> classify JsonRows (statusCode (HTTP.responseStatus response)) (lookup "X-ClickHouse-Exception-Code" (HTTP.responseHeaders response)) bytes
      )
  case result of
    Left exception | isJust (fromException exception :: Maybe SomeAsyncException) -> throwIO exception
    Left _ -> pure (SubmissionUncertain (safeError ResponseInterrupted))
    Right Nothing -> pure (SubmissionUncertain (safeError DeadlineExpired))
    Right (Just outcome) -> pure outcome

makeRequest :: Text -> ByteString -> ByteString -> Int -> Text -> ByteString -> IO HTTP.Request
makeRequest endpoint user password micros identity sql = do
  base <- HTTP.parseRequest (Text.unpack endpoint)
  let request =
        HTTP.applyBasicAuth user password $
          HTTP.setQueryString
            [ ("query_id", Just (Encoding.encodeUtf8 identity)),
              ("async_insert", Just "0"),
              ("mutations_sync", Just "1"),
              ("alter_sync", Just "1"),
              ("wait_end_of_query", Just "1"),
              ("default_format", Just "JSONEachRow")
            ]
            base
              { HTTP.method = "POST",
                HTTP.requestBody = HTTP.RequestBodyBS sql,
                HTTP.redirectCount = 0,
                HTTP.checkResponse = \_ _ -> pure (),
                HTTP.responseTimeout = HTTP.responseTimeoutMicro micros,
                HTTP.decompress = const False,
                HTTP.requestHeaders = [("Content-Type", "text/plain; charset=utf-8")]
              }
  pure request

registered :: IORef [ThreadId] -> IO a -> IO a
registered threads action = mask $ \restore -> do
  identity <- myThreadId
  atomicModifyIORef' threads (\old -> (identity : old, ()))
  restore action `finally` atomicModifyIORef' threads (\old -> (filter (/= identity) old, ()))
