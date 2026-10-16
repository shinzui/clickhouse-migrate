module Main where

import ClickHouseMigrate.ExclusiveAccess
import ClickHouseMigrate.Ledger
import ClickHouseMigrate.Target

bad :: TargetConfig -> ExclusiveAccess -> InitializationAuthorization -> IO (LedgerCommandResult LedgerPosition)
bad config provider authorization = initializeLedger config provider authorization

main :: IO ()
main = pure ()
