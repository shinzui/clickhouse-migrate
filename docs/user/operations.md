---
type: Runbook
title: "Operating the Haskell API"
description: "Operate the Haskell API and recover uncertain work using explicit coordination and evidence."
docId: DOC-13
tags: ["operations", "recovery", "coordination"]
timestamp: 2026-11-14T01:47:31Z
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


## Replicated targets

Obtain and retain every server UUID with an administrative login:

```sql
SELECT hostName(), toString(serverUUID()) FROM clusterAllReplicas('<cluster>', system.one);
```

Construct a `ClusterName` with `clusterName`, then call `replicatedTargetConfig`
with the exact nonempty UUID list, endpoint, namespace, binding, credentials and
HTTP limits. It returns `Either TargetError TargetConfig`; duplicate UUIDs and
request deadlines under five seconds are refused. Supply a caller-owned coordinator
that serializes all administrators across the cluster and drains every prior
request before any successor mutation. The development host-local adapter is only
for administrators sharing one host and lock root.

Precreate every application and ledger database as `Replicated` on the cluster.
Application credentials need local system reads of cluster membership and ledger
replica health, plus disks/storage policy metadata. They do not require REMOTE.
Read `status --json` before fencing application traffic: it performs admission and
ledger reads without initialization. A refusal should be diagnosed before the
application enters maintenance.

The example mounts replicated SQL with `--replicated-example` and takes
`CHM_CLUSTER` and comma-separated `CHM_REPLICA_IDS` in place of `CHM_SERVER_ID`.
The core library never reads these environment variables itself.

A stopped replica makes new writes fail or become uncertain. DDL may already be
queued in Keeper and a timed-out insert may commit later. Restart, establish
external quiescence across every replica, inspect history and reconcile pending
receipts, then use explicit accept/finalize or retry/resume as appropriate. The
restricted login's active-query diagnostic is local to the admitted replica;
absence there is never proof of cluster-wide drain.

Legacy adoption currently binds v1 mapping checksums and is supported on direct targets. Replicated adoption refuses with `unsupported-ledger-version` before writes. Replicated installations start with a fresh native baseline.

Server waits can include coordination overhead: the spike observed a metadata ALTER error after about twelve seconds with a five-second inactive-replica wait. The HTTP deadline remains authoritative; if it expires before a complete response, preserve submission uncertainty and never infer non-submission or retry automatically.


## Explicit external drain with unavailable process diagnostics (unreleased)

The existing `recoveryEvidence` constructor remains strict: a failed process
observation refuses repair. A caller that independently established and retained
external drain under its exclusion may opt in with
`externalDrainRecoveryEvidence audit quiet receipts observationSink`. This is a
source-candidate API; published 0.2.0.0 does not include it.

The sink receives `NoRecordedQueries`, `NoVisibleRecordedQueries`,
`RecordedQueriesActive queryIds` or `ProcessObservationUnavailable`. Retain this
observation separately from the external authority. An empty restricted view or a
denied read is never drain evidence. Only a complete access-denied response (native
code 497) from the optional `system.processes` query is eligible for unavailable
status. Unknown transport failures, malformed rows, failed history/identity checks,
loss of exclusion and cancellation remain fatal. Any positively observed recorded
query still refuses recovery, under either constructor.

The observer runs before recovery authorization. A synchronous observer failure
stops the operation with the existing event-callback classification and phase
`RepairProcessObservation`; cancellation propagates after cleanup. No raw server
error, SQL or credential is delivered through this diagnostic callback. All exact
position, attempt, selected-step and pending-receipt checks remain in force.
Every later recovery call still needs current caller-established exclusion/drain;
this API does not turn an old observation into standing authorization.

## Constrained SELECT-only inspection

The unreleased source API `boundedObservation rows bytes` returns an explicit
observation option when both bounds are positive. Use it with `history`, `status`
or `verify` for a reader whose server policy forbids unlimited results, for example
`boundedObservation 10000 1048576`. No mutation context or guarded option accepts
these bounds. Ordinary `Observe` and all mutation/repair requests keep their
existing request settings. Result, read, timeout and sort overflow modes remain
`throw`: exceeding the bound fails the entire observation and never accepts a
truncated history. The server identity and storage checks, ledger validation,
response bounds and cleanup checks still run. This API is a source candidate,
not part of the published 0.2.0.0 release.
