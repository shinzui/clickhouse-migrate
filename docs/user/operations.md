---
type: Runbook
title: "Operating the Haskell API"
description: "Operate the Haskell API and recover uncertain work using explicit coordination and evidence."
docId: DOC-13
tags: ["operations", "recovery", "coordination"]
generated:
  by: human:nadeem
  at: 2026-10-16T15:34:07Z
---

# Operating the Haskell API

Construct a validated TargetConfig with a stable TargetKey, direct endpoint,
pinned server UUID, dedicated ledger namespace, credentials and bounded HTTP
limits. Install the exact supported server artifact from
[compatibility](compatibility.md). Target checks do not attest the installed binary
digest. Keep credentials in application configuration.

Provide an explicit ExclusiveAccess through `externallySerialized`. Its acquire
callback must exclude every administrator for the entire target. Its release
callback must admit no successor until this client cannot submit and all earlier
server work is quiescent, including application SQL, ledger INSERTs and bootstrap
DDL. The alive callback reports retained ownership. Lease loss cannot fence bytes
already submitted. Test support's host-local provider requires the same host,
canonical lock root and target key for all administrators; its persistent marker
requires explicit predecessor-quiescence evidence after any previous entry.

Build a MutationContext from target, provider, event sink and diagnostic policy.
It contains configuration, not an acquired session. Each `up` or `repair` acquires
and cleans up its own scope. Default reports and events contain safe identities,
checksums and error codes. The optional `sqlDiagnostics` sink receives authored SQL
and is responsible for its own secure handling. Observer exceptions stop work;
observers do not replace durable history.

For an intentional first use, generate and retain `newLedgerId`, configure FirstUse,
and pass `authorizeInitialization target ledger audit` in UpOptions. Retain that
UUID even if initialization fails. Compatible empty bootstrap objects may be
resumed only under the same explicit authorization after externally establishing
all prior requests are quiescent. After successful initialization persist the
returned ledger ID and use ExistingLedger for recurring commands. Recurring up
with no initialization authorization never creates a missing ledger.

`status Observe target plan` compares the supplied definitions with stored history;
`history Observe target` needs no plan and can investigate incompatible definitions.
Both are observations and create no objects. Select Guarded with the coordinator
for a serialized observation. `verify` rejects incompatible or unresolved history.
Pending migrations are compatible unless VerifyOptions requires current history.
Applied descriptions may change; ordered identities, dependencies and SQL checksums
must continue to match. See [ledger v1](contracts/ledger-v1.md) for exact tokens and
reconciliation rules.

For an interrupted run, retain RunFailure's primary error, acknowledged report,
query/attempt identities, pending append receipts and secondary errors. SQL
observations are local evidence; they do not create a durable success checkpoint.
Never blindly rerun an uncertain statement or infer failure from a timeout, client
exit, an empty process-list result or an empty ledger read. A server request can
outlive the client. Asynchronous cancellation is rethrown after bounded cleanup
and does not promise a returned report.

Establish quiescence externally while retaining exclusion. Investigate actual
effects and every pending ledger/bootstrap request. Reconcile exact append receipts
read-only when available; NotObserved alone proves no final outcome. Then obtain a
fresh guarded history and construct RecoveryEvidence from target-bound quiescence,
actor, reason and external references. Include outstanding receipts. Each repair
reacquires access and rejects stale positions, attempts and selected step identities;
a positive active-query observation also refuses recovery.

Choose the narrow operation supported by the evidence:

- `retryStepRequest` authorizes the same SQL bytes under a fresh attempt/query ID
  only after external evidence establishes retry safety. It executes that step
  alone, without the remaining suffix or migration completion.
- `resumeRequest` requires no uncertain step. It executes remaining never-started
  steps of the selected migration and completes it, without starting another.
- `acceptStepRequest` records operator-attested completion for the exact uncertain
  step. It submits no application SQL and does not continue or finalize.
- `finalizeRequest` records migration completion when every step is already
  observed successful or accepted. It submits no application SQL.

After any interrupted repair, inspect again and construct a fresh expected-state
request. Ordinary up never treats recovery authorization as standing permission.
Acceptance remains an operator attestation in later history; it never becomes an
observed SQL success. Verify before returning to ordinary up.

These are library workflows. Application-owned configuration, coordination,
logging, exception handling and process exit remain the caller's responsibility.

## Complete history reads

History uses one complete JSONEachRow SELECT with server partial-result modes
disabled. The HTTP byte limit bounds each raw row, excluding the LF delimiter
(and including CR in CRLF), rather than the total ledger response. Ordinary metadata
and command responses retain their total-body limit. Default limits and the 16 MiB
configuration cap are unchanged. Full HTTP framing and every row must validate
before any prefix is usable; late errors, oversized rows, corrupt suffixes,
truncation and cancellation stop dependent mutation. Configured deadlines still
apply to the whole request. Decoded events, projections and reports retain all
history, so total retained memory grows with history size.

## Recovery metadata preparation

After validating a fresh guarded position and selected attempt, recovery prepares
its complete authorization and deterministic acceptance/finalization events before
its first append. Size accounting uses canonical UTF-8/JSON bytes, including
repeated accepted references and the separate quiescence audit. Retry and resume
check conservative bounds for generated start, success, failure and completion
metadata; they do not predict SQL results. Required sequence capacity is checked
before authorization. Oversized events return `recovery-event-too-large` with a
safe event role, preserving the original position and attempt. Supply smaller
reviewed evidence in a new explicit request; successful requests retain evidence
verbatim. Once a valid event is submitted, existing uncertainty, receipts and
external quiescence rules still apply.
