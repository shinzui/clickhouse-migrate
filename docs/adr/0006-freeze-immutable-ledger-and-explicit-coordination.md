# Freeze immutable ledger and explicit coordination

Status: Accepted

Date: 2026-10-16

## Context

The ledger must retain intent and uncertainty independently of application effects.
MergeTree ordering keys do not guarantee uniqueness, and an HTTP timeout or an
empty history read cannot prove an outstanding INSERT will not commit later.
Process-local exclusion and automatic OS-lock release cannot fence server work.

The protocol must cover recovery and adoption before downstream commands grow,
and must retain dependency/order evidence alongside SQL checksums. Public clients
must be able to integrate coordination and bootstrap without gaining raw append
or transport access.

## Decision

Freeze [ledger v1](../user/contracts/ledger-v1.md): one dedicated Atomic database and
local append-only MergeTree table, with strict canonical event JSON and physical
sequence/UUID cross-checks. Include initialization, execution, recovery and adoption
in one versioned protocol. Individual migration/step events retain stable identity
and checksum context, validated against their immutable definition. Global ordered
prefix comparison includes component dependencies and positions.

Fold only contiguous validated history. Collapse identical duplicates defensively;
never resolve conflicts by timestamps or storage merge order. Unfinished migration
attempts and adoption batches block ordinary execution. Accepted completion remains
separate from observed success. Recovery authorization binds the exact observed
position and old/new attempt IDs, and does not become standing resume permission.

Require a caller-owned explicit coordinator at every mutating public boundary,
acquired before preflight and held through transport cleanup. Check its live scope
immediately before socket writes, including writes after connection admission.
Lease loss cannot fence bytes already sent. The provider and quiescence assertion
remain external operational promises that Haskell types cannot prove.

First-use permission binds target and a retained client-generated ledger UUID.
Compatible empty bootstrap objects can resume only with explicit permission and
externally established quiescence. Existing-ledger binding never accepts a newly
discovered UUID silently. Public position and pending-append receipt tokens have
validated CLI roundtrips but grant no authority. A receipt retains event identity,
sequence, digest and the ledger INSERT's diagnostic query ID. Reconciliation is
read-only and never reinserts or resumes work.

Every event is submitted once. Any unacknowledged submitted append stops the store,
including an observed error response. Preserve primary observations and cleanup
errors separately; rethrow asynchronous cancellation after cleanup. Verify the
exact schema and effective metadata/part fsync settings. Select the default
storage policy explicitly and verify all its disks are healthy writable Local
disks; Atomic/MergeTree names alone do not qualify remote storage. Prevent server partial-
result modes from presenting a truncated history as a complete valid prefix.

## Consequences

Public commands initially expose narrow initialization and exact-event reconciliation;
execution/recovery/adoption consume the private store through their state machines.
No persisted-event constructor, append operation or live guard escapes publicly.

The test-support OS-lock provider is deliberately host-local and conservative. A
separate persistent marker survives normal release and process death; a subsequent
administrator needs explicit target-bound quiescence evidence. Every administrator
must share the same host, canonical lock root and target key. This is development
coordination, not a distributed lease/fencing implementation.

Native qualification includes separate-process exclusion, initialization/event
acknowledgement loss, late intent/completion/adoption events after NotObserved,
and an acknowledged owned-server SIGKILL/restart. Read-only diagnosis can remain
inside a caller-owned serialized job while a prior request is outstanding; that
job must admit no mutating successor until all predecessor requests drain.
The host-local marker is more conservative and requires explicit evidence even
for later entry after client exit. Fsync configuration/process-kill tests
do not establish power-loss or storage-failure durability.

Execution order now follows [ADR 0010](0010-separate-component-catalog-from-execution-schedule.md),
which preserves the catalog and immutable global prefix.

[ADR 0011](0011-read-complete-history-with-bounded-rows.md) removes the aggregate
response ceiling while retaining full-history validation and bounded raw rows.
