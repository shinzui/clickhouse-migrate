-- | Observations cannot replace durable ledger audit history. A throwing sink
-- stops the operation. No default sink prints or retains SQL or credentials.
module ClickHouseMigrate.Event
  ( EventPhase (..),
    RunEvent (..),
    EventSink,
    quietEvents,
    DiagnosticPolicy,
    redactedDiagnostics,
    sqlDiagnostics,
    SqlDiagnostic (..),
  )
where

import ClickHouseMigrate.Internal.EventTypes

quietEvents :: EventSink
quietEvents _ = pure ()

redactedDiagnostics :: DiagnosticPolicy
redactedDiagnostics = DiagnosticPolicy Nothing

-- | Explicit opt-in delivery of authored SQL. The caller owns logging/storage.
-- Structured errors always retain safe codes rather than raw server messages.
sqlDiagnostics :: (SqlDiagnostic -> IO ()) -> DiagnosticPolicy
sqlDiagnostics = DiagnosticPolicy . Just
