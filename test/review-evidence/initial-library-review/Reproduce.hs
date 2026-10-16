{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

import ClickHouseMigrate
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.ExclusiveAccess qualified as A
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Repair qualified as Repair
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Runner qualified as Run
import ClickHouseMigrate.TestSupport.Server
import Control.Monad
import Data.Aeson qualified as J
import Data.Aeson.KeyMap qualified as KM
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

mkMigration name statements = traverse (uncurry sqlStep) statements >>= sqlMigrationFromList name

mkComponent name deps migrations = migrationComponentFromList name (Set.fromList deps) migrations

summary :: Either R.RunFailure R.RunReport -> String
summary (Left (R.RunFailure failure _ _)) = "Left " ++ show failure
summary (Right _) = "Right success"

readSummary :: Either R.InspectionFailure R.HistoryReport -> String
readSummary (Left (R.InspectionFailure failure _ _)) = "Left " ++ show failure
readSummary (Right _) = "Right success"

main = withCandidateServer "lts-native" $ \server -> do
  J.Array rows <- queryServer server "SELECT toString(serverUUID()) AS id"
  let J.Object row = head (foldr (:) [] rows)
      Just (J.String sid) = KM.lookup "id" row
  endpoint <- right (directEndpoint (serverEndpoint server))
  identity <- right (serverId sid)
  creds <- right (basicCredentials "default" "test-password")
  access <- right (A.externallySerialized "review-owned-server" "single parent, no other administrators" 1000000 (const (pure ())) (const (pure ())) (const (pure True)))
  audit <- right (L.auditContext "review" "reproduction" ["owned fixture"])
  let config label binding limits = do
        key <- right (targetKey label)
        ns <- right (ledgerNamespace label)
        pure (targetConfig key endpoint identity ns binding creds limits)
      run conf au auth plan = Run.up (Run.mutationContext conf access E.quietEvents E.redactedDiagnostics) (Run.upOptions au auth) plan
      migration name = right (mkMigration name [("s", "CREATE TABLE IF NOT EXISTS default.review_table (x UInt8) ENGINE=Memory")])
  m1 <- migration "one"
  m2 <- migration "two"
  a <- right (mkComponent "a" [] [m1])
  a2 <- right (mkComponent "a" [] [m1, m2])
  b <- right (mkComponent "b" ["a"] [m1])
  old <- right (migrationPlan (a :| [b]))
  updated <- right (migrationPlan (a2 :| [b]))
  ledger <- newLedgerId
  conf <- config "review_components" FirstUse defaultHttpLimits
  let auth = L.authorizeInitialization (configuredTargetKey conf) ledger audit
  run conf audit (Just auth) old >>= putStrLn . ("component initial: " ++) . summary
  bound <- config "review_components" (ExistingLedger ledger) defaultHttpLimits
  run bound audit Nothing updated >>= putStrLn . ("append to component a: " ++) . summary
  bigAudit <- right (L.auditContext "review" "capacity reproduction" (replicate 24 (T.replicate 2000 "x")))
  steps <- right (mkMigration "large" [(T.pack ("s" ++ show n), "CREATE TABLE IF NOT EXISTS default.review_table (x UInt8) ENGINE=Memory") | n <- [1 .. 12 :: Int]])
  comp <- right (mkComponent "capacity" [] [steps])
  plan <- right (migrationPlan (comp :| []))
  capLedger <- newLedgerId
  capConf <- config "review_capacity" FirstUse defaultHttpLimits
  run capConf bigAudit (Just (L.authorizeInitialization (configuredTargetKey capConf) capLedger audit)) plan >>= putStrLn . ("capacity initial: " ++) . summary
  capBound <- config "review_capacity" (ExistingLedger capLedger) defaultHttpLimits
  I.history I.Observe capBound >>= putStrLn . ("capacity next history: " ++) . readSummary
  maxLimits <- right (httpLimits 30000000 16777216)
  capLarge <- config "review_capacity" (ExistingLedger capLedger) maxLimits
  I.history I.Observe capLarge >>= putStrLn . ("capacity larger bound: " ++) . readSummary

  repairLedger <- newLedgerId
  repairConf <- config "review_repair" FirstUse defaultHttpLimits
  repairComp <- right (mkComponent "repair" [] [m1])
  repairPlan <- right (migrationPlan (repairComp :| []))
  let stopBeforeSql (E.RunEvent phase _ _ _ _ _ _) = when (phase == E.BeforeSql) (fail "review interruption")
  interrupted <- Run.up (Run.mutationContext repairConf access stopBeforeSql E.redactedDiagnostics) (Run.upOptions audit (Just (L.authorizeInitialization (configuredTargetKey repairConf) repairLedger audit))) repairPlan
  case interrupted of
    Left (R.RunFailure _ (R.RunReport _ _ _ _ (R.HistoryReport _ _ _ (Just position) _ before _ _) [R.MigrationSummary _ _ (Just attempt) [R.StepSummary _ _ _ (Just selected) _]] _ _) _) -> do
      quiet <- right (L.attestQuiescence (configuredTargetKey repairConf) audit)
      evidence <- right (Repair.recoveryEvidence bigAudit quiet [])
      request <- right (Repair.acceptStepRequest position attempt selected evidence)
      repairBound <- config "review_repair" (ExistingLedger repairLedger) defaultHttpLimits
      result <- Repair.repair (Run.mutationContext repairBound access E.quietEvents E.redactedDiagnostics) repairPlan request
      putStrLn ("large accepted repair request: " ++ summary result)
      observed <- I.history I.Observe repairBound >>= right
      let R.HistoryReport _ _ _ _ _ after _ _ = observed
      putStrLn ("repair ledger events before/after: " ++ show (length before, length after) ++ "; last=" ++ show (R.historyKind (R.body (last after))))
    _ -> fail "Expected interrupted fixture step"
