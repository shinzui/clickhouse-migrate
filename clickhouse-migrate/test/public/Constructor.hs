module Constructor where

import ClickHouseMigrate

forge :: StepName -> SqlStep
forge name = SqlStep name mempty
