module Main where

import ClickHouseMigrate.Repair

bad :: RepairRequest
bad = ResumeRequest undefined undefined undefined

main :: IO ()
main = pure ()
