# Scope commands and preserve acknowledged progress

Status: Accepted

Date: 2026-10-16

## Context

Application SQL and immutable history commit separately. A command may observe SQL
success and then lose the checkpoint response, or finish its durable work before
an observer or cleanup fails. Recovering from such states requires exact identities
and explicit evidence rather than another ordinary run.

## Decision

Expose configuration-only MutationContext and one scoped operation per up or
repair invocation. Acquire the caller's mandatory coordinator before opening the
dedicated transport, and hold it through bounded transport cleanup. Inspection
explicitly selects an unguarded observation or a caller-provided guard. It never
initializes history. Revalidate the complete supplied plan and global stored prefix
before application SQL, including dynamic ledger-namespace reservations.

Return typed domain reports independently of printing, serialization or process
exit. On synchronous failure retain the latest acknowledged history, exact pending
append receipt, SQL observations and separate secondary errors. Acknowledged SQL
in a report does not substitute for a durable step-success event. Checkpoint
updates following a known append acknowledgement are masked against cancellation;
asynchronous exceptions still escape after scoped cleanup rather than becoming a
normal RunFailure. Observers are fallible observations, never the audit store.
Their failure stops further SQL. An observer or failure-recording error cannot
replace an earlier SQL error. No raw exception text, SQL body or credentials enter
default reports. SQL diagnostics require a separate explicit opt-in sink.

Recovery requests bind the expected ledger position, current migration attempt,
and selected original step attempt where applicable. Re-read the complete history
inside a newly acquired scope and require target-bound external quiescence of all
predecessor requests. Refuse positively observed active query IDs as an additional
check; absence from system.processes is not quiescence evidence. Validate any
pending append receipts against this fresh projection.

Acknowledge a fresh recovery authorization before further work. Retry executes only
the named step with fresh attempt/query identities. Resume executes only the
never-started suffix and completes only the selected migration. Accept records an
operator attestation without SQL or continuation. Finalize records completion only
when all steps are resolved and submits no SQL. Ordinary up never consumes a
standing recovery authorization; interruption requires a fresh expected-state
request and fresh coordination.

## Consequences

The public domain report vocabulary supplies later adoption and CLI rendering
without exposing raw event append, transport or acquired guard capabilities.
Pending definitions remain compatible; unresolved history blocks ordinary up.
Accepted completion remains distinguishable from observed success after explicit
finalization. Commands cannot prove external coordination or operator evidence,
and a returned partial report is not guaranteed after asynchronous cancellation.
