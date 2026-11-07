module TargetCoercion where

import ClickHouseMigrate.Target
import Data.Coerce (coerce)

invalid :: () -> TargetConfig
invalid = coerce
