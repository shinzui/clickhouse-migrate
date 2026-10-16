module Deserialize where

import ClickHouseMigrate

forge :: String -> SqlStep
forge = read
