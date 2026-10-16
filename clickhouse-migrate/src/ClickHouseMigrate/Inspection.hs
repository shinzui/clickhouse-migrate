-- | Read-only observations. No inspection path initializes or repairs history.
module ClickHouseMigrate.Inspection
  ( InspectionOptions (Observe, Guarded),
    VerifyOptions,
    verifyOptions,
    status,
    history,
    verify,
  )
where

import ClickHouseMigrate.Internal.Exclusive (checkGuard, withExclusive)
import ClickHouseMigrate.Internal.ExclusiveTypes (AccessResult (..), ExclusiveAccess (..))
import ClickHouseMigrate.Internal.Identity (freshUuid)
import ClickHouseMigrate.Internal.LedgerStore qualified as Store
import ClickHouseMigrate.Internal.Reporting qualified as Reporting
import ClickHouseMigrate.Internal.RuntimeTypes (InspectionOptions (..), VerifyOptions (..))
import ClickHouseMigrate.Internal.ServerPolicy (TargetCheckError (..), withTransportChecked)
import ClickHouseMigrate.Internal.TargetTypes (QueryId (..), TargetConfig (..))
import ClickHouseMigrate.Internal.Transport qualified as Transport
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Prelude
import ClickHouseMigrate.Report qualified as R
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)

verifyOptions :: Bool -> VerifyOptions
verifyOptions = VerifyOptions

history :: InspectionOptions -> TargetConfig -> IO (Either R.InspectionFailure R.HistoryReport)
history options config@(TargetConfig target _ _ _ _ _ _) = do
  latest <- newIORef Nothing
  observed <- try @SomeException $ do
    probe <- QueryId . ("chm-" <>) <$> freshUuid
    let scoped guard access =
          let check = case guard of Nothing -> pure (Right ()); Just capability -> checkGuard capability >>= pure . either (const (Left (Transport.TransportError Transport.AdministrativeAccessLost Nothing Nothing))) (const (Right ()))
           in withTransportChecked config probe check $ \transport -> Store.storeResult $ do
                observation <- Store.load guard transport config
                let report = Reporting.observationReport target (Just (Transport.transportIdentity transport)) access observation
                writeIORef latest (Just report)
                pure report
        flatten (Transport.ScopeResult result cleanup) =
          ( case result of
              Left failure -> Left (R.TargetFailed failure)
              Right (Left (TargetRejected failure)) -> Left (R.TargetFailed failure)
              Right (Left (ProbeFailure failure)) -> Left (Reporting.outcomeError failure Nothing)
              Right (Right (Left failure)) -> Left (Reporting.storeError failure)
              Right (Right (Right report)) -> Right report,
            map R.TransportCleanup cleanup
          )
    case options of
      Observe -> flatten <$> scoped Nothing R.UnguardedObservation
      Guarded provider@(ExclusiveAccess description _ _ _ _) -> do
        AccessResult result cleanup <- withExclusive provider target (\guard -> scoped (Just guard) (R.GuardedObservation description))
        pure $ case result of
          Left failure -> (Left (R.AccessFailed failure), map R.AccessCleanup cleanup)
          Right value -> let (answer, errors) = flatten value in (answer, errors ++ map R.AccessCleanup cleanup)
  snapshot <- readIORef latest
  case observed of
    Left exception | isJust (fromException exception :: Maybe SomeAsyncException) -> throwIO exception
    Left _ -> pure (Left (R.InspectionFailure R.UnexpectedRuntimeFailure snapshot []))
    Right (Left failure, cleanup) -> pure (Left (R.InspectionFailure failure snapshot cleanup))
    Right (Right _, cleanup@(_ : _)) -> pure (Left (R.InspectionFailure R.CleanupFailed snapshot cleanup))
    Right (Right report, []) -> pure (Right report)

status :: InspectionOptions -> TargetConfig -> MigrationPlan -> IO (Either R.InspectionFailure R.InspectionReport)
status options config plan = fmap (Reporting.inspectHistory plan) <$> history options config

verify :: InspectionOptions -> TargetConfig -> VerifyOptions -> MigrationPlan -> IO (Either R.InspectionFailure R.VerificationReport)
verify options config (VerifyOptions requireCurrent) plan = do
  result <- status options config plan
  pure $
    result >>= \report@(R.InspectionReport snapshot _ _) -> case Reporting.compatibilityError report of
      Just failure -> Left (R.InspectionFailure failure (Just snapshot) [])
      Nothing | requireCurrent && not (Reporting.isCurrent report) -> Left (R.InspectionFailure R.VerificationNotCurrent (Just snapshot) [])
      Nothing -> Right (R.VerificationReport report (Reporting.isCurrent report))
