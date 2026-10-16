module Generic where

import ClickHouseMigrate
import GHC.Generics (Generic, Rep, to)

forge :: Rep MigrationPlan x -> MigrationPlan
forge = to
