-- | Guarded v1 storage. Every append is frozen, submitted once, then acknowledged
-- or made blocking. No reconciliation path writes or resumes an operation.
module ClickHouseMigrate.Internal.LedgerStore where

import ClickHouseMigrate.Internal.Checksum qualified as Checksum
import ClickHouseMigrate.Internal.Exclusive (checkGuard)
import ClickHouseMigrate.Internal.ExclusiveTypes (AccessError, Guard)
import ClickHouseMigrate.Internal.Identity (diagnosticTime, freshUuid)
import ClickHouseMigrate.Internal.LedgerCodec (decodeEvent, encodeEvent, encodeValue)
import ClickHouseMigrate.Internal.LedgerSchema qualified as Schema
import ClickHouseMigrate.Internal.LedgerTypes
import ClickHouseMigrate.Internal.Projection (appendProjection, project)
import ClickHouseMigrate.Internal.TargetTypes (TargetConfig (..))
import ClickHouseMigrate.Internal.Transport
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target hiding (ledgerId)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (Exception, throwIO, try)
import Data.Aeson (FromJSON, Key, Object, Result (..), fromJSON, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Text.Read (readMaybe)

data StoreError = LedgerProblem !LedgerError | AccessProblem !AccessError | RequestProblem !TransportOutcome !(Maybe AppendReceipt) | InitializationProblem !LedgerId !Text !QueryId !TransportOutcome
  deriving stock (Eq, Show)

data StoreAbort = StoreAbort !StoreError deriving stock (Show)

instance Exception StoreAbort

data Observation = Missing | EmptyNamespace | History !Projection deriving stock (Eq, Show)

data LedgerStore = LedgerStore !Guard !Transport !TargetKey !LedgerNamespace !(IORef (Either StoreError Projection)) !(MVar ())

storeResult :: IO a -> IO (Either StoreError a)
storeResult action = either (\(StoreAbort failure) -> Left failure) Right <$> try action

abort :: StoreError -> IO a
abort = throwIO . StoreAbort

checked :: Either LedgerError a -> IO a
checked = either (abort . LedgerProblem) pure

newQueryId :: IO QueryId
newQueryId = freshUuid >>= either (const (abort (LedgerProblem InvalidEvent))) pure . queryId . ("chm-" <>)

checkAccess :: Guard -> IO ()
checkAccess guard = checkGuard guard >>= either (abort . AccessProblem) pure

readRows :: Maybe Guard -> Transport -> ByteString -> IO [Object]
readRows = readRowsKind JsonRows

readRowsKind :: RequestKind -> Maybe Guard -> Transport -> ByteString -> IO [Object]
readRowsKind kind guard transport sql = do
  mapM_ checkAccess guard
  identity <- newQueryId
  outcome <- request transport identity kind sql
  case outcome of
    AcknowledgedSuccess (Rows rows) -> pure rows
    _ -> abort (RequestProblem outcome Nothing)

member :: (FromJSON a) => Key -> Object -> IO a
member key row = case KM.lookup key row of
  Just value -> case fromJSON value of Success result -> pure result; Error _ -> invalid
  _ -> invalid
  where
    invalid = abort (LedgerProblem InvalidLedgerSchema)

keys :: [Key] -> Object -> IO ()
keys expected row = unless (Set.fromList expected == Set.fromList (KM.keys row)) (abort (LedgerProblem InvalidLedgerSchema))

-- Shape state is separate from event projection to avoid inventing an empty
-- ledger identity. Return False for absent table after checking every object.
shape :: Maybe Guard -> Transport -> LedgerNamespace -> IO (Bool, Bool)
shape guard transport namespace = do
  checkLocalStorage guard transport
  settings <- readRows guard transport "SELECT toUInt8(getSetting('fsync_metadata')) AS fsync_metadata"
  case settings of
    [setting] -> do
      keys ["fsync_metadata"] setting
      effective <- member "fsync_metadata" setting :: IO Int
      unless (effective == 1) invalid
    _ -> invalid
  databases <- readRows guard transport (Schema.databaseQuery namespace)
  case databases of
    [] -> pure (False, False)
    [row] -> do
      keys ["name", "engine"] row
      name <- member "name" row
      engine <- member "engine" row :: IO Text
      unless (name == ledgerNamespaceText namespace && engine == "Atomic") invalid
      tables <- readRows guard transport (Schema.tableQuery namespace)
      case tables of
        [] -> pure (True, False)
        [table] -> do
          keys ["name", "engine", "engine_full", "sorting_key", "primary_key", "partition_key", "sampling_key", "create_table_query"] table
          actual <- mapM (`member` table) ["name", "engine", "engine_full", "sorting_key", "primary_key", "partition_key", "sampling_key", "create_table_query"] :: IO [Text]
          let base = ["events", "MergeTree", Schema.expectedEngine, "sequence", "sequence", "", ""]
              quotedCreate = Text.replace ("CREATE TABLE " <> ledgerNamespaceText namespace <> ".") ("CREATE TABLE " <> Schema.quoteIdentifier (ledgerNamespaceText namespace) <> ".") (Schema.expectedCreate namespace)
          unless (actual == base ++ [Schema.expectedCreate namespace] || actual == base ++ [quotedCreate]) invalid
          pure (True, True)
        _ -> invalid
    _ -> invalid
  where
    invalid = abort (LedgerProblem InvalidLedgerSchema)

-- Fsync-qualified v1 storage is the explicitly selected default policy backed by
-- healthy writable local disks. A same-named policy can otherwise point at object
-- storage, for which the native process-crash qualification does not apply.
checkLocalStorage :: Maybe Guard -> Transport -> IO ()
checkLocalStorage guard transport = do
  policies <- readRows guard transport "SELECT disks FROM system.storage_policies WHERE policy_name='default'"
  names <- concat <$> mapM (\row -> keys ["disks"] row >> (member "disks" row :: IO [Text])) policies
  unless (not (null names) && length names == Set.size (Set.fromList names)) invalid
  disks <- readRows guard transport "SELECT name, type, is_remote, is_read_only, is_broken FROM system.disks"
  decoded <-
    mapM
      ( \row -> do
          keys ["name", "type", "is_remote", "is_read_only", "is_broken"] row
          name <- member "name" row
          kind <- member "type" row :: IO Text
          flags <- mapM (`member` row) ["is_remote", "is_read_only", "is_broken"] :: IO [Int]
          pure (name, kind, flags)
      )
      disks
  mapM_
    ( \name -> case [(kind, flags) | (actual, kind, flags) <- decoded, actual == name] of
        [("Local", [0, 0, 0])] -> pure ()
        _ -> invalid
    )
    names
  where
    invalid = abort (LedgerProblem UnsupportedLedgerStorage)

load :: Maybe Guard -> Transport -> TargetConfig -> IO Observation
load guard transport (TargetConfig target _ _ namespace binding _ _) = do
  (database, table) <- shape guard transport namespace
  if not database
    then pure Missing
    else
      if not table
        then pure EmptyNamespace
        else do
          rows <- readRowsKind JsonRowStream guard transport (Schema.readQuery namespace)
          if null rows
            then pure EmptyNamespace
            else do
              events <- mapM decodeRow rows
              projection <- checked (project target events)
              case binding of
                ExistingLedger expected -> let LedgerPosition actual _ _ = position projection in unless (expected == actual) (abort (LedgerProblem LedgerIdentityMismatch))
                FirstUse -> pure ()
              pure (History projection)

decodeRow :: Object -> IO LedgerEvent
decodeRow row = do
  keys ["sequence", "event_id", "ledger_id", "event"] row
  encoded <- member "event" row
  event <- checked (decodeEvent (Encoding.encodeUtf8 encoded))
  number <- member "sequence" row :: IO Text
  identity <- member "event_id" row
  ledger <- member "ledger_id" row
  let LedgerEvent sequenceNumber eventIdentity ledgerIdentity _ _ _ _ _ _ _ = event
  unless (readMaybe (Text.unpack number) == Just sequenceNumber && identity == eventIdentity && ledger == ledgerIdText ledgerIdentity) (abort (LedgerProblem InvalidEvent))
  pure event

openStore :: Guard -> Transport -> TargetConfig -> Maybe InitializationAuthorization -> QuiescenceEvidence -> Text -> IO LedgerStore
openStore guard transport config@(TargetConfig target _ _ namespace binding _ _) authorization (QuiescenceEvidence quietTarget _) run = do
  checkAccess guard
  case authorization of
    Just (InitializationAuthorization authorized identity _) -> do
      unless (authorized == target) (abort (LedgerProblem InitializationNotAuthorized))
      case binding of ExistingLedger expected -> unless (expected == identity) (abort (LedgerProblem LedgerIdentityMismatch)); FirstUse -> pure ()
    Nothing -> pure ()
  unless (quietTarget == target) (abort (LedgerProblem OutstandingRequests))
  observation <- load (Just guard) transport config
  projection <- case observation of
    History state -> do
      case binding of
        ExistingLedger _ -> pure ()
        FirstUse -> case authorization of
          Just (InitializationAuthorization expected identity _) -> do
            let LedgerPosition actual _ _ = position state
            unless (target == expected && identity == actual) (abort (LedgerProblem LedgerIdentityMismatch))
          _ -> abort (LedgerProblem InitializationNotAuthorized)
      pure state
    _ -> case (binding, authorization) of
      (FirstUse, Just (InitializationAuthorization expected ledger authAudit)) | expected == target -> initialize guard transport config ledger authAudit run
      _ -> abort (LedgerProblem InitializationNotAuthorized)
  state <- newIORef (Right projection)
  gate <- newMVar ()
  pure (LedgerStore guard transport target namespace state gate)

initialize :: Guard -> Transport -> TargetConfig -> LedgerId -> AuditContext -> Text -> IO Projection
initialize guard transport (TargetConfig target _ _ namespace _ _ _) ledger audit run = do
  identity <- freshUuid
  time <- diagnosticTime
  let first = LedgerEvent 1 identity ledger run Nothing time audit "0.1.0.0" Nothing (Initialize target)
  _ <- checked (project target [first])
  ddl "database" (Schema.createDatabase namespace)
  _ <- shape (Just guard) transport namespace
  ddl "table" (Schema.createTable namespace)
  (_, exists) <- shape (Just guard) transport namespace
  unless exists (abort (LedgerProblem InvalidLedgerSchema))
  -- Even under exclusivity do not write over preexisting nonempty history.
  rows <- readRowsKind JsonRowStream (Just guard) transport (Schema.readQuery namespace)
  unless (null rows) (abort (LedgerProblem MissingInitialization))
  appendOnce guard transport target namespace first
  checked (project target [first])
  where
    ddl stage sql = do
      checkAccess guard
      identity <- newQueryId
      outcome <- request transport identity Command sql
      case outcome of AcknowledgedSuccess CommandAccepted -> pure (); _ -> abort (InitializationProblem ledger stage identity outcome)

appendOnce :: Guard -> Transport -> TargetKey -> LedgerNamespace -> LedgerEvent -> IO ()
appendOnce guard transport target namespace event@(LedgerEvent sequenceNumber identity ledger _ _ _ _ _ _ _) = do
  checkAccess guard
  query <- newQueryId
  let payload = object ["sequence" .= sequenceNumber, "event_id" .= identity, "ledger_id" .= ledgerIdText ledger, "event" .= Encoding.decodeUtf8 (encodeEvent event)]
      sql = Encoding.encodeUtf8 ("INSERT INTO " <> Schema.qualifiedTable namespace <> " FORMAT JSONEachRow\n") <> encodeValue payload <> "\n"
      receipt = AppendReceipt target ledger sequenceNumber identity (Checksum.digestHex (Checksum.digest (encodeEvent event))) query
  outcome <- request transport query Command sql
  case outcome of AcknowledgedSuccess CommandAccepted -> pure (); _ -> abort (RequestProblem outcome (Just receipt))

storeProjection :: LedgerStore -> IO Projection
storeProjection (LedgerStore _ _ _ _ state _) = readIORef state >>= either abort pure

append :: LedgerStore -> LedgerEvent -> IO Projection
append store@(LedgerStore guard transport target namespace state gate) event = withMVar gate $ \() -> do
  previous <- storeProjection store
  next <- checked (appendProjection previous event)
  result <- storeResult (appendOnce guard transport target namespace event)
  case result of
    Left failure -> writeIORef state (Left failure) >> abort failure
    Right () -> writeIORef state (Right next) >> pure next

-- A fresh guarded FULL read, including strict corruption validation. NotObserved
-- is evidence of this read only; it grants no authority to reuse a sequence.
reconcile :: Guard -> Transport -> TargetConfig -> AppendReceipt -> IO (Reconciliation, Observation)
reconcile guard transport config@(TargetConfig target _ _ _ _ _ _) (AppendReceipt expected ledger number identity digest _) = do
  unless (target == expected) (abort (LedgerProblem LedgerIdentityMismatch))
  observation <- load (Just guard) transport config
  let result = case observation of
        History projection ->
          let LedgerPosition actual _ _ = position projection
              matches = [event | event <- events projection, eventId event == identity || eventSequence event == number]
           in if actual /= ledger
                then Conflicting
                else case matches of
                  [] -> NotObserved
                  [event] | eventId event == identity && eventSequence event == number && Checksum.digestHex (Checksum.digest (encodeEvent event)) == digest -> PresentIdentical
                  _ -> Conflicting
        _ -> NotObserved
  pure (result, observation)
  where
    eventSequence (LedgerEvent value _ _ _ _ _ _ _ _ _) = value
