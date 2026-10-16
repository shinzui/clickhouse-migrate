module Main where

import ClickHouseMigrate.Ledger
import ClickHouseMigrate.Target

bad :: TargetConfig -> InitializationAuthorization -> QuiescenceEvidence -> IO (LedgerCommandResult LedgerPosition)
bad config authorization quiet = initializeLedger config authorization quiet

main :: IO ()
main = pure ()
