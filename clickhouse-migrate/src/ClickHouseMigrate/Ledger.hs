-- | Validated administrative assertions and narrowly scoped ledger commands.
module ClickHouseMigrate.Ledger
  ( module ClickHouseMigrate.Internal.LedgerValidation,
    Reconciliation (PresentIdentical, Conflicting, NotObserved),
    initializeLedger,
    reconcileAppend,
    LedgerCommandResult (..),
    LedgerFailure (..),
    RequestEvidence (..),
    CleanupFailure (..),
    TransportError (..),
    TransportErrorCode (..),
  )
where

import ClickHouseMigrate.Internal.Exclusive (checkGuard, withExclusive)
import ClickHouseMigrate.Internal.ExclusiveTypes (AccessDescription, AccessError (..), AccessResult (..), ExclusiveAccess (..), Guard)
import ClickHouseMigrate.Internal.Identity (freshUuid)
import ClickHouseMigrate.Internal.LedgerStore qualified as Store
import ClickHouseMigrate.Internal.LedgerTypes
import ClickHouseMigrate.Internal.LedgerValidation
import ClickHouseMigrate.Internal.ServerPolicy (TargetCheckError (..), withTransportChecked)
import ClickHouseMigrate.Internal.TargetTypes (TargetConfig (..))
import ClickHouseMigrate.Internal.Transport (ScopeResult (..), Transport, TransportError (..), TransportErrorCode (..))
import ClickHouseMigrate.Internal.Transport qualified as Transport
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Target (QueryId, ledgerIdText, queryId)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)

-- These are safe structured observations. They carry no raw HTTP exceptions,
-- credentials, SQL, or server response bodies.
data RequestEvidence = PositiveNonSubmission | ObservedFailure | UncertainSubmission deriving stock (Eq, Show)

data LedgerFailure
  = LedgerRejected !LedgerError
  | AccessRejected !AccessError
  | RequestFailed !RequestEvidence !TransportError !(Maybe AppendReceipt)
  | InitializationFailed !Text !Text !QueryId !RequestEvidence !TransportError
  | AdministrativeScopeFailed
  deriving stock (Eq, Show)

data CleanupFailure = TransportCleanup !TransportError | AccessCleanup !AccessError deriving stock (Eq, Show)

data LedgerCommandResult a = LedgerCommandResult
  {result :: !(Either LedgerFailure a), access :: !AccessDescription, cleanupErrors :: ![CleanupFailure]}
  deriving stock (Eq, Show)

-- | Create/resume only this explicitly authorized target/UUID. On an initialized
-- matching ledger, return its observed position without appending or running SQL.
-- The caller must retain the authorization UUID after any interruption. Existing
-- binding mode never permits initialization of missing storage.
initializeLedger :: TargetConfig -> ExclusiveAccess -> InitializationAuthorization -> QuiescenceEvidence -> IO (LedgerCommandResult LedgerPosition)
initializeLedger config provider authorization quiet = command config provider $ \guard transport -> do
  run <- freshUuid
  store <- Store.openStore guard transport config (Just authorization) quiet run
  position <$> Store.storeProjection store

-- | Read-only exact-event reconciliation. NotObserved never authorizes a write.
reconcileAppend :: TargetConfig -> ExclusiveAccess -> AppendReceipt -> IO (LedgerCommandResult (Reconciliation, ExpectedLedgerState))
reconcileAppend config@(TargetConfig target _ _ _ _ _ _) provider receipt = command config provider $ \guard transport -> do
  (classification, observation) <- Store.reconcile guard transport config receipt
  pure (classification, case observation of Store.History state -> ExpectPosition (position state); _ -> ExpectAbsent target)

command :: TargetConfig -> ExclusiveAccess -> (Guard -> Transport -> IO a) -> IO (LedgerCommandResult a)
command config@(TargetConfig target _ _ _ _ _ _) provider@(ExclusiveAccess description _ _ _ _) action = do
  observed <- try @SomeException $ do
    probe <- freshUuid >>= either (const (fail "Invalid diagnostic identity")) pure . queryId . ("chm-" <>)
    withExclusive provider target $ \guard ->
      let check = checkGuard guard >>= pure . either (const (Left (TransportError AdministrativeAccessLost Nothing Nothing))) (const (Right ()))
       in withTransportChecked config probe check $ \transport -> Store.storeResult (action guard transport)
  case observed of
    Left exception | isJust (fromException exception :: Maybe SomeAsyncException) -> throwIO exception
    Left _ -> pure (LedgerCommandResult (Left AdministrativeScopeFailed) description [])
    Right (AccessResult outer accessCleanup) -> case outer of
      Left failure -> pure (LedgerCommandResult (Left (AccessRejected failure)) description (map AccessCleanup accessCleanup))
      Right (ScopeResult scoped transportCleanup) -> do
        let answer = case scoped of
              Left failure -> Left (RequestFailed UncertainSubmission failure Nothing)
              Right (Left (TargetRejected failure)) -> Left (RequestFailed PositiveNonSubmission failure Nothing)
              Right (Left (ProbeFailure outcome)) -> Left (outcomeFailure outcome Nothing)
              Right (Right (Left failure)) -> Left (storeFailure failure)
              Right (Right (Right value)) -> Right value
        pure (LedgerCommandResult answer description (map TransportCleanup transportCleanup ++ map AccessCleanup accessCleanup))

storeFailure :: Store.StoreError -> LedgerFailure
storeFailure = \case
  Store.LedgerProblem failure -> LedgerRejected failure
  Store.AccessProblem failure -> AccessRejected failure
  Store.RequestProblem outcome receipt -> outcomeFailure outcome receipt
  Store.InitializationProblem ledger stage identity outcome -> case outcomeFailure outcome Nothing of
    RequestFailed evidence failure _ -> InitializationFailed (ledgerIdText ledger) stage identity evidence failure
    _ -> AdministrativeScopeFailed

outcomeFailure :: Transport.TransportOutcome -> Maybe AppendReceipt -> LedgerFailure
outcomeFailure outcome receipt = case outcome of
  Transport.NotSubmitted failure -> RequestFailed PositiveNonSubmission failure receipt
  Transport.ObservedServerFailure failure -> RequestFailed ObservedFailure failure receipt
  Transport.SubmissionUncertain failure -> RequestFailed UncertainSubmission failure receipt
  Transport.AcknowledgedSuccess _ -> AdministrativeScopeFailed
