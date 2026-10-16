---
id: 11
slug: validate-complete-recovery-events-before-mutation
title: "Validate complete recovery events before mutation"
kind: exec-plan
created_at: 2026-10-16T18:00:59Z
intention: "intention_01m52xysxcekwvcbwmaafphfvh"
master_plan: "docs/masterplans/2-resolve-initial-library-correctness-architecture-and-api-review-findings.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-16T18:00:59Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T18:52:04Z
      mode: "implement"
      note: "Prepare complete recovery envelopes before authorization and preserve original position on size rejection"
---

# Validate complete recovery events before mutation

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log and Outcomes & Retrospective current as implementation proceeds.

## Purpose / Big Picture


Resolve [REV-1/F3](../reviews/initial-library-review.md#rev-1f3--p2-accepted-recovery-input-fails-after-changing-history).
When recovery evidence cannot fit in its actual ledger event, return a specific
error before advancing history or submitting application SQL. An operator can then
supply smaller valid evidence against the same expected position. Preserve all
existing explicit recovery and acknowledgement rules.

## Progress


- [x] M1 (2026-10-16; exact 65,536/65,537-byte checks and combined native recovery): Full recovery envelopes are prepared and size-validated with typed failures before the first append, including authorization and accepted completion.
- [x] M2 (2026-10-16; native original-position rejection and replacement, events 3 to 3): The public native oversized-accept reproduction leaves position and attempt unchanged; valid replacement evidence succeeds against the original position.
- [x] M3 (2026-10-16; all recovery variants, byte boundaries, CLI goldens and uncertain-write regressions): All recovery variants, error renderers, boundary regressions and user/ADR contracts pass without weakening uncertain-write handling.

## Surprises & Discoveries


The baseline review accepted the public evidence/request constructors and ordinary
preflight, then observed `LedgerFailed InvalidEvent` after a new
`recovery-authorized` event. The defect is validation ordering, not permission to
roll back an already-recorded event. Actual prepared authorization and acceptance
are now projected together before submission. UTF-8, escaped references and
independently valid combined audits demonstrate why character counts are not an
event bound. Required sequence capacity is checked using Integer arithmetic to
avoid wrapping UInt64 before any authorization.

## Decision Log


2026-10-16: Validate complete serialized envelopes, including duplicated audit and
evidence fields, instead of summing input Text lengths. Reject the request with a
specific error; do not truncate, deduplicate or silently hash away operator evidence.

2026-10-16: Prepare deterministic recovery metadata after fresh guarded state
validation and before its first write. Reuse prepared metadata when appending so
validation and submission cannot serialize different IDs or contexts. SQL results
remain unknown until execution; conservatively validate their possible metadata
sizes without inventing successful outcomes.

## Outcomes & Retrospective


Actual authorization and deterministic acceptance/finalization metadata are
prepared, size-validated and projected before the first append. Retry/resume
conservatively bound their possible observation envelopes, and sequence capacity
uses overflow-safe arithmetic. Submission reuses frozen metadata through the
existing masked acknowledgement and receipt path.

The native public reproduction now rejects oversized acceptance with
RecoveryEventTooLarge RecoveryAcceptanceEvent and preserves events (3,3), the
position, current attempt and selected step. No SQL or recovery acknowledgement
callback occurs; smaller evidence accepts against the original token. Oversized
quiescence and combined audits reject authorization for all applicable actions.
Exact 65,536-byte events pass and 65,537-byte events reject; UTF-8 and JSON escapes
are counted. CLI JSON/text retain safe typed details. Existing interrupted
recovery, dependent append loss, cancellation and surviving-work regressions pass.

[ADR 0012](../adr/0012-prepare-recovery-metadata-before-authorization.md)
records preparation-before-authorization without weakening uncertainty. The same
replacement-evidence path passes against the MasterPlan's history above 16 MiB.

Final implementation-author verification is recorded in
[REV-2](../reviews/initial-library-remediation-verification.md).

## Context and Orientation


The defect descriptions below preserve the reviewed baseline from REV-1. The
accepted implementation is summarized in Outcomes & Retrospective and verified
in REV-2; these baseline descriptions do not describe the completed runtime.

Work from the repository root. `clickhouse-migrate/src/ClickHouseMigrate/Ledger.hs`
reexports validated audit/quiescence inputs from `Internal/LedgerValidation.hs`.
`auditContext` permits 32 references of up to 2,048 characters each; field validity
alone is not a wire-size proof. `Repair.hs:recoveryEvidence` checks references,
receipt count and target identity. Request constructors bind expected ledger
position, migration attempt and, where applicable, the exact step attempt.

`Repair.hs:repair` opens a scoped runtime, verifies current position/attempt and
receipts, checks predecessor queries, selects a recovery action, then calls
`Internal/Execution.hs:appendEvent` for `AuthorizeRecovery`. Only afterward does
AcceptStep construct `AcceptCompletion`, repeating audit references in its evidence.
`Internal/Preflight.hs` sizes Initialize and StartMigration sample envelopes but
not this recovery pair. `Internal/LedgerCodec.hs:validateEvent` caps each canonical
encoded event at 65,536 bytes. `Internal/LedgerStore.hs:append` validates the next
projection before sending it. Thus the second event fails locally only after the
first event has durably changed the position and active attempt.

The public reproduction in
`test/review-evidence/initial-library-review/Reproduce.hs` interrupts BeforeSql,
constructs an accept request with 24 references each containing 2,000 ASCII
characters, and uses a small independent quiescence audit. Authorization fits;
accepted-completion metadata duplicates those references and does not fit. The
result is `LedgerFailed InvalidEvent`, three events becoming four, and an unresolved
step. The captured `observations.txt` records that actual result.

[ADR 0001](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md) requires
separate SQL/ledger uncertainty. [ADR 0006](../adr/0006-freeze-immutable-ledger-and-explicit-coordination.md)
requires immutable events, exact positions and one submission per event.
[ADR 0007](../adr/0007-scope-commands-and-preserve-acknowledged-progress.md) requires
scoped recovery, original step identities, acknowledged snapshots and safe errors.
[ADR 0008](../adr/0008-adopt-reviewed-prefixes-with-explicit-evidence.md) already
establishes full batch validation before adoption mutation; apply the same principle
to recovery without copying adoption's state machine.

## Plan of Work


M1 adds a private preparation phase after repair has selected the action and
validated fresh guarded state, but before emitting any recovery-authorization write.
Build the actual AuthorizeRecovery envelope with its generated run/event/attempt
identities, timestamp, current definition context, expected position, outer audit
and quiescence audit. For AcceptStep also build the actual AcceptCompletion envelope
at the next sequence with its repeated evidence. For Finalize prepare the required
completion envelope. For RetryStep and Resume validate authorization plus ordinary
request-specific start/success/failure/completion metadata sizes conservatively
before SQL, using the existing definition preflight and explicit worst-case sizes
where the actual response is not yet known. Never predeclare a SQL outcome.

Use the one canonical encoder and `validateEvent`; introduce a named shared maximum
event-byte constant rather than duplicating 65,536 in a second serializer. Count
UTF-8 and JSON-escaped bytes, not Unicode characters. Validate event sequences and
contexts against the projected state for deterministic no-SQL batches. If sequence
capacity would be exceeded by such a batch, reject it before the first append as
well. Keep invalid user request metadata distinct from corrupt observed history.

Expose a safe typed error such as `RunError.RecoveryEventTooLarge RecoveryEventKind`
where `RecoveryEventKind` uses distinct constructors such as
`RecoveryAuthorizationEvent` or `RecoveryAcceptanceEvent`, identifying the required
control event without embedding audit text or SQL. Add a matching
request-constructor error only where that constructor can actually establish the
same bound without a target definition; do not claim that every runtime-dependent
bound is knowable in a smart constructor. A runtime rejection after read-only state
validation is acceptable, provided it occurs before every append and SQL request.

Introduce a private prepared-event value/helper in `Internal/Execution.hs` or
`Internal/RepairTypes.hs` so validated deterministic metadata is reused on the
append path. Keep event constructors hidden. Preserve exact append receipts,
fresh query IDs for actual requests, one submission, poisoning after uncertain
append, and masking when acknowledged progress updates. Existing callbacks retain
their meaning: RecoveryAuthorized occurs only after its acknowledgement. Do not
emit it for a preparation failure. No-op rollback logic is appropriate; no event
has been sent when a size rejection occurs.

M2 ports the diagnostic scenario into
`clickhouse-migrate-test-support/test/RepairIntegration.hs`. Read and save the
original ledger position, current migration attempt, event count and application
SQL count. Build the oversized request through public constructors; call `repair`;
assert the specific size error, zero recovery appends, unchanged position/attempt,
no SQL and no RecoveryAuthorized/StepAccepted callbacks. Then create smaller valid
evidence and perform the same acceptance against the original expected position.
It must succeed without first accepting a changed position caused by the rejected
request. Finalize separately if all steps are resolved, retaining existing scope.
This public consumer is the first native acceptance gate.

M3 covers oversized quiescence audit in authorization, combined outer/quiescence
audits that each fit separately, repeated accepted evidence, multibyte text, JSON
escapes, exact bound and bound+1, and safe ordinary small recovery requests.
Exercise resume, retry-step, accept-step and finalize. Re-run existing injected
failures after valid authorization and acceptance: once an event really is sent,
uncertain outcomes must still stop progress and require fresh explicit recovery.
Extend `Report.hs`, CLI `Render/Json.hs` and `Render/Text.hs`, their goldens and
`docs/user/error-codes.md` for the new safe size error. Update
`docs/user/operations.md`, `docs/user/contracts/ledger-v1.md` and
`docs/user/contracts/json-v1.md`. Record the preparation-before-write decision in a
local ADR linked from ADR 0007, preserving its existing explicit recovery contract.

## Concrete Steps


All commands run at the repository root in the pinned GHC 9.12.4 environment.
No new dependency or version change is needed. Use Mori before any dependency API
lookup and do not inspect the Nix store.

```bash
nix develop --builders ''
just test-unit
just check-public-invariants
just test-repair
just test-review-remediation
just test-failure-boundaries
just test-cli
just check-docs
```

Add pure size/preparation cases in `clickhouse-migrate/test/LedgerTests.hs` or a
new registered recovery unit module. Native state and callback assertions belong
in `clickhouse-migrate-test-support/test/RepairIntegration.hs` and
`RepairBoundaries.hs`. Keep UUID/sequence encodings and canonical
JSON fixtures compatible. Update every exhaustive error match and documentation
mapping in core and CLI; do not reduce exhaustive coverage with a catch-all.

Expected corrected public trace is:

```text
oversized accept request: RecoveryEventTooLarge RecoveryAcceptanceEvent
ledger events before/after: (3,3); position and active attempt unchanged
application SQL and recovery writes for rejected request: 0
smaller evidence against original position: accepted
```

## Validation and Acceptance


Use both pure encoded-byte boundary checks and the native before/after observation.
The outcome must be a domain error that explains which recovery event is too large,
not `InvalidEvent`, `UnexpectedRuntimeFailure` or a late partial repair. Evidence
must remain byte-for-byte intact on successful valid requests. Size checks must
account for the exact wrapper, run/attempt/context fields, timestamp and sequence
representation; a test that only mirrors input character limits is insufficient.

A rejected request must leave the ledger position, active attempt and selected
step state unchanged even when it follows a successful guarded read. Original
expected-position tokens must remain usable for a smaller replacement request.
Stale positions, wrong targets, conflicting receipts, outstanding predecessor
queries and inappropriate repair actions must still fail as before. Valid requests
retain normal callback order, durable receipts, cancellation semantics and all
existing interrupted-repair behavior. Test CLI JSON remains redacted and carries
the unchanged latest history snapshot plus the new typed primary error.

## Idempotence and Recovery


All native checks use owned disposable servers. No historical events are edited
or deleted. A local preparation rejection grants no authority to retry uncertain
SQL; it merely allows a new explicit request against the still-current position.
If a later valid append has an uncertain outcome, keep its receipt and follow the
existing reconciliation and quiescence process. Do not reuse its event identity or
sequence based only on an empty read.

## Interfaces and Dependencies


No other child is a hard prerequisite. EP-11 owns request-specific recovery
preparation, safe size errors and their CLI rendering. EP-9 in
`docs/plans/9-allow-component-upgrades-with-an-explicit-migration-schedule.md` may
change migration selection to an explicit schedule; consume the freshly selected
definition rather than reconstructing grouped order. EP-10 in
`docs/plans/10-stream-complete-ledger-history-with-bounded-row-decoding.md` may change
how the full projection is read; preparation still begins only after a complete
validated read. Coordinate `Internal/Execution.hs`, `Report.hs`, CLI JSON and
shared documentation. The MasterPlan's combined gate verifies rejection and valid
recovery on an interleaved plan with history above 16 MiB.
