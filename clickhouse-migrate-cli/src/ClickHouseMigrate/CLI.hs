-- | Reusable commands around an application's compiled plan. The application
-- owns configuration, coordination, diagnostics, stdout and process exit policy.
-- 'handleCommand' returns synchronous failures with the last acknowledged report;
-- asynchronous exceptions propagate after the core's bounded cleanup.
module ClickHouseMigrate.CLI
  ( module ClickHouseMigrate.CLI.Types,
    module ClickHouseMigrate.CLI.Parser,
    module ClickHouseMigrate.CLI.Handler,
    renderJson,
    renderText,
  )
where

import ClickHouseMigrate.CLI.Handler
import ClickHouseMigrate.CLI.Parser
import ClickHouseMigrate.CLI.Render.Json (renderJson)
import ClickHouseMigrate.CLI.Render.Text (renderText)
import ClickHouseMigrate.CLI.Types
