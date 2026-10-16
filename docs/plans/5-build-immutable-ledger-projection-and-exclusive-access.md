---
id: 5
slug: build-immutable-ledger-projection-and-exclusive-access
title: "Build immutable ledger projection and exclusive access"
kind: exec-plan
created_at: 2026-10-16T04:45:20Z
intention: "intention_01m51gc3zpezra0de7ctcp9r8w"
master_plan: "docs/masterplans/1-bootstrap-the-initial-clickhouse-migration-library.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-16T04:45:20Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T04:57:58Z
      verdict: "changes-requested"
      note: "Require quiescent ledger reconciliation and move initialization/evidence ownership before consumers."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T05:03:30Z
      verdict: "approved"
      note: "Revised plan addresses this review; ready for its declared implementation prerequisites and acceptance gates, not runtime qualification."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T05:03:30Z
      mode: "update"
      note: "Define early shared types and quiescent exact-event reconciliation for every unacknowledged submitted append."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T13:06:45Z
      mode: "implement"
      note: "Begin immutable event projection and guarded native ledger after accepted transport qualification."
---

# Build immutable ledger projection and exclusive access

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


History becomes an immutable, validated event log protected by caller-provided exclusive administrative access. An absent or corrupt ledger cannot silently replay old migrations, and an uncertain append blocks further action until guarded inspection resolves the exact event.

## Progress


- [x] (2026-10-16) M1 — Complete strict v1 event codec/projection covers initialization, execution, recovery and adoption; independent canonical JSON vector, corruption/duplicate/identity checks, global-prefix comparison and interrupted-state tests pass. Stable context names/checksums are retained on individual migration/step events.
- [ ] M2 — Guarded initialization, synchronous append/read and exact-event reconciliation pass real-server and concurrent-administrator tests.

Handoff 2026-10-16: Early direct native initialization + second-event append/read roundtrip passes, including quoted/newline audit data. Public initializeLedger/reconcileAppend and validated position/receipt tokens exist; receipt includes INSERT query ID. Host-local adapter and public bootstrap pass separate-process exclusion, typed acquisition timeout, persistent marker after clean/process-death release, UUID/position retention, and lease loss DURING socket admission preventing the next write. Transport regression passes explicit identity encoding and a profile that otherwise returns partial results. Native Nix core/test-support builds also pass, exercising the frozen codec against Aeson 2.2.4.1 (Cabal uses 2.3.2.0). Evidence: `/tmp/clickhouse-migrate-ep5-m1-unit-final.log`, `/tmp/clickhouse-migrate-ep5-ledger.log`, `/tmp/clickhouse-migrate-ep5-m1-exclusive.log`, `/tmp/clickhouse-migrate-ep5-m1-transport.log` and `/tmp/clickhouse-migrate-ep5-m1-nix.log`. Remaining M2 work: initialization/representative-event lost/error acknowledgements, delayed first-event arrival after an empty read with blocked successor, schema/corruption/binding faults, real guarded exact reconciliation, acknowledged server-kill/restart durability and complete Cabal/Nix acceptance. Do not start EP-6 until all pass.

## Surprises & Discoveries

2026-10-16: Direct admission initially failed because http-client advertises gzip even when decompression is disabled. The proxy had used uncompressed upstream responses. Explicit Accept-Encoding identity fixes direct reads; the transport suite now includes this path. Candidate Settings.cpp also permits partial results under break overflow modes, which could hide unresolved history behind a valid prefix. Machine reads force unlimited server read/result sizes and throwing read/result/timeout/sort modes, while retaining bounded full client responses.

2026-10-16: Metadata fsync is a per-query setting distinct from MergeTree part fsync. Internal requests force fsync_metadata=1 and preflight verifies its effective value. The candidate's exact normalized table definition exposes fsync_after_insert and fsync_part_directory; its profile is deliberately weakened in fixtures. Actual server-crash acceptance remains M2 work.


## Decision Log

2026-10-16: Freeze one complete event family now, including recovery/adoption, and compare stable per-event context against the active immutable definition. Canonical encoding plus exact physical column checks preserves duplicate evidence rather than selecting a timestamp winner. See [ledger v1](../contracts/ledger-v1.md) and [ADR 0006](../adr/0006-freeze-immutable-ledger-and-explicit-coordination.md).

2026-10-16: Public bootstrap is an early consumer for the coordinator adapter, so separate-process tests exercise actual guarded storage without exposing Guard/Transport/raw append. The development OS-lock marker survives every release; later entry requires explicit external quiescence evidence even after a clean client exit. Lease checks run immediately before HTTP writes as well as before store operations.


## Outcomes & Retrospective




## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

At creation there was no local ADR corpus. The pre-implementation review added [Preserve uncertainty across runtime boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md): unsuccessful requests never authorize automatic replay, successor mutation requires all prior server work to be quiescent, shared ledger types are defined before runtime consumers, and test access must preserve public invariants. Follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. There is no profiled ADR bundle; preserve the plain Markdown convention. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/4-implement-direct-http-transport-and-isolated-fault-fixtures.md` must be Complete; its transport is required for trustworthy acknowledgement. The pure model from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md` is also a hard prerequisite, already satisfied transitively. This implements sections 9–10 and the history validation part of 11–12. Projection means deriving current state by folding events in sequence order. Exclusive access is a caller-owned bracket spanning the whole target, not a MergeTree key or a row in the ledger. No local ADR existed initially; read the checksum and transport ADRs from prerequisites.

## Plan of Work


M1 creates `clickhouse-migrate/src/ClickHouseMigrate/Ledger.hs`, `Internal/LedgerSchema.hs`, `Internal/LedgerCodec.hs`, and `Internal/Projection.hs`. Freeze the physical schema and versioned payload requirements in `docs/contracts/ledger-v1.md`. Use a separate validated/quoted database name, a local Atomic database and non-replicated MergeTree table, without TTL, replacing semantics or mutations. Define the complete v1 event family now, including recovery authorization and adoption start/entry/complete, so downstream plans consume one protocol. Every event preserves sequence, event/ledger/run/attempt identities, relevant component/migration/step definitions and checksums, query ID, diagnostic UTC time, actor/runner version and bounded versioned details.

Pure decoding/projection must reject gaps, unknown kinds/versions, missing fields, conflicting event IDs or sequence values, impossible transitions and conflicting terminal states. Collapse only exact duplicate events with the same identity and sequence; never use timestamps or merge order to select a winner. Store enough component dependency and global migration order evidence to compare the entire recorded prefix with the supplied plan. Unknown definitions, changed dependencies and inserting a component ahead of recorded work block mutation. Adopted/completed definitions both count toward the compatible prefix, while incomplete adoption and any unresolved migration block execution.

M2 implements `clickhouse-migrate/src/ClickHouseMigrate/ExclusiveAccess.hs` and `Internal/LedgerStore.hs`. The public provider brackets access, reports strategy/scope, bounds acquisition with a typed timeout and notifies lease loss; its contract excludes successor mutation until the predecessor can no longer submit and all its server requests, including ledger INSERTs and initialization DDL, are quiescent; require it at every mutating API boundary. Supply an explicit application adapter for externally serialized jobs with caller-owned quiescence responsibility; never supply an implicit no-op. A development OS file-lock provider lives in test-support and is labelled host-local. It must exclude separate processes sharing a target and lock namespace.

Acquire access before reading history for mutation and hold it through client cleanup. Verify exact database/table engines, columns/types and required durability settings before writes. Initialize only with explicit target-bound first-use authorization; ordinary absence is an error. Compatible empty objects left by an interrupted initialization may be completed under the same authorization, while nonempty events lacking valid initialization fail. Bind target key and ledger UUID; an existing ledger's identity must match caller expectations. Allocate contiguous sequences under exclusive access, use safe typed parameter/data encoding, send each append once and await full acknowledgement. For any submitted append without acknowledged success, including an observed server failure, return exact event identity, stop, and require later guarded reconciliation before another write. Preserve the transport failure category, but do not infer that the event is absent or that its sequence is reusable. Do not automatically append duplicates or continue. Read-only inspection must not initialize storage.

Document and test fsync_after_insert and synchronous insert requirements for each candidate version in the matrix, validating effective settings rather than assuming requested values were accepted. State separately process/server crash durability and untested power-loss/storage failure. Write ledger/exclusivity ADRs before downstream runner expansion.

This plan also defines the public InitializationAuthorization, ExpectedLedgerState, AuditContext, QuiescenceEvidence and EvidenceLevel used by later plans. ExpectedLedgerState distinguishes `ExpectAbsent TargetKey` from `ExpectPosition LedgerPosition`; absence is an observation, not initialization permission. InitializationAuthorization is separately bound to the target. Existing-ledger operations bind the expected LedgerId in target configuration; bootstrap is a distinct first-use choice and reports the newly generated ID for subsequent configuration. Never accept any discovered UUID silently as the caller's expected ledger. AuditContext validates nonempty actor/reason and bounded evidence references. EvidenceLevel distinguishes operator attestation from predecessor-checksum evidence; EP-7 owns validating source-specific evidence, not redefining the persisted discriminator.

Public LedgerPosition is an opaque observed token with validated text decoding for CLI roundtrips; decoding is not authorization. Every mutator compares it inside the guard. Persisted LedgerEvent and raw store/append operations remain internal. Expose inspection and typed recovery requests, not a general public append API that bypasses the state machine. The provider integration accepts caller acquisition/release and loss signaling, but no live guard or transport handle escapes the command's scope. Document the limits of what Haskell types can enforce about an external coordinator.

Exact-event reconciliation is read-only and returns PresentIdentical, Conflicting or NotObserved together with the inspected position. NotObserved cannot establish that an outstanding INSERT failed. Require externally established quiescence of all prior requests and a fresh full-history read before sequence reuse, initialization resumption or any new repair/adoption event. A present event is folded into history, never reinserted; a conflict blocks; after proven quiescence an absent event leaves the last acknowledged projected state for an explicit operation to act on. Ordinary up remains blocked whenever that state contains an unresolved attempt. No reconciliation result silently resumes the interrupted operation.

The initialization fault matrix covers database creation, table creation and the first event independently. A compatible empty namespace can resume only after prior requests are quiescent and explicit first-use authorization is revalidated. If the first event is present, its UUID must be reconciled with the interrupted bootstrap evidence; if it conflicts, stop. Test a delayed first event arriving after an empty read and prove that a successor cannot install a different UUID or reuse its sequence. The same delayed-append case applies to step intent, completion and adoption. A host-local file lock alone is not proof of server quiescence after its owner crashes; the test adapter must require explicit recovery evidence for that case.

## Concrete Steps


Create the ledger unit and integration groups and recipes, then run:

```bash
nix develop -c cabal test clickhouse-migrate-unit --test-show-details=direct
nix develop -c just test-ledger
nix develop -c just test-exclusive-access
```

The integration output must identify each corruption/acknowledgement fault and whether any forbidden subsequent request was seen. Test two independent processes using the same host-local lock, not two threads behind one mutex.

## Validation and Acceptance


First prove a single initialization and append/read roundtrip through the real transport before implementing every event variant. Reject missing ledger without authorization, target/UUID mismatch, wrong engine/schema/version, sequence gaps and conflicts. Reopening after acknowledged initialization must preserve its UUID. Drop append acknowledgements for initialization and representative event kinds, restart inspection under access, and match the exact stored event without replay. Events containing quoting edge cases must roundtrip without SQL injection. A second administrator cannot enter while the first owns access; lease loss stops subsequent submissions and does not claim to fence an already submitted query. Kill/restart the owned server and process around acknowledged writes and retain evidence. Stable reads and mutation preflight must not rely on an earlier unguarded observation.

## Idempotence and Recovery


Builds and pure tests may be repeated. Integration tests must allocate their own temporary directories, ports and database names, track their server processes, and clean up only resources they created. Preserve failed-run evidence before cleanup. Never test against a persistent application database. A failed or uncertain mutating request is not safe to repeat: inspect its exact event and attempt under exclusive access, and use the explicit recovery protocol. Do not erase history, rewrite checksums or assume a timeout stopped server work.

## Interfaces and Dependencies


Consumes Transport/TargetKey/QueryId/LedgerId from `docs/plans/4-implement-direct-http-transport-and-isolated-fault-fixtures.md` and definition descriptors from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md`. Owns LedgerEvent, LedgerPosition, EventId, RunId, AttemptId, initialized ledger context, projected state, guarded append and exact-event reconciliation. A LedgerPosition carries enough identity to reject stale repair/adoption requests, including ledger identity and the exact last sequence/event. Owns InitializationAuthorization, ExpectedLedgerState, AuditContext, QuiescenceEvidence, EvidenceLevel and recovery/adoption event wire shapes; later plans implement commands using them and coordinate schema changes here before release. `ExclusiveAccess` must run an operation only within an acquired scope and expose loss notification. No mutating API accepts an optional provider. Later runner and adoption plans may add transition tests but cannot invent separate storage protocols.

Revision 2026-10-15 — Pre-implementation API/correctness review: Move shared authorization/evidence types to their first owner and require quiescent reconciliation.
