module Coercion where

import ClickHouseMigrate
import Data.Coerce (coerce)
import Data.Text (Text)

forge :: Text -> ComponentName
forge = coerce
