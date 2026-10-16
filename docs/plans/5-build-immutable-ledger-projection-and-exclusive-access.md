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
---

# Build immutable ledger projection and exclusive access

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


History becomes an immutable, validated event log protected by caller-provided exclusive administrative access. An absent or corrupt ledger cannot silently replay old migrations, and an uncertain append blocks further action until guarded inspection resolves the exact event.

## Progress


- [ ] M1 — A pure event projection rejects corrupt sequences and produces compatible-prefix or blocking states.
- [ ] M2 — Guarded initialization, synchronous append/read and exact-event reconciliation pass real-server and concurrent-administrator tests.

## Surprises & Discoveries




## Decision Log




## Outcomes & Retrospective




## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

No local ADR corpus or profiled ADR bundle exists at creation. Before implementation, follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. Create durable decisions in `docs/adr/` using the convention then present; do not introduce a new OKF profile incidentally. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/4-implement-direct-http-transport-and-isolated-fault-fixtures.md` must be Complete; its transport is required for trustworthy acknowledgement. The pure model from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md` is also a hard prerequisite, already satisfied transitively. This implements sections 9–10 and the history validation part of 11–12. Projection means deriving current state by folding events in sequence order. Exclusive access is a caller-owned bracket spanning the whole target, not a MergeTree key or a row in the ledger. No local ADR existed initially; read the checksum and transport ADRs from prerequisites.

## Plan of Work


M1 creates `clickhouse-migrate/src/ClickHouseMigrate/Ledger.hs`, `Internal/LedgerSchema.hs`, `Internal/LedgerCodec.hs`, and `Internal/Projection.hs`. Freeze the physical schema and versioned payload requirements in `docs/contracts/ledger-v1.md`. Use a separate validated/quoted database name, a local Atomic database and non-replicated MergeTree table, without TTL, replacing semantics or mutations. Define the complete v1 event family now, including recovery authorization and adoption start/entry/complete, so downstream plans consume one protocol. Every event preserves sequence, event/ledger/run/attempt identities, relevant component/migration/step definitions and checksums, query ID, diagnostic UTC time, actor/runner version and bounded versioned details.

Pure decoding/projection must reject gaps, unknown kinds/versions, missing fields, conflicting event IDs or sequence values, impossible transitions and conflicting terminal states. Collapse only exact duplicate events with the same identity and sequence; never use timestamps or merge order to select a winner. Store enough component dependency and global migration order evidence to compare the entire recorded prefix with the supplied plan. Unknown definitions, changed dependencies and inserting a component ahead of recorded work block mutation. Adopted/completed definitions both count toward the compatible prefix, while incomplete adoption and any unresolved migration block execution.

M2 implements `clickhouse-migrate/src/ClickHouseMigrate/ExclusiveAccess.hs` and `Internal/LedgerStore.hs`. The public provider brackets access, reports strategy/scope, bounds acquisition with a typed timeout and notifies lease loss; require it at every mutating API boundary. Supply an explicit application adapter for externally serialized jobs with caller-owned quiescence responsibility; never supply an implicit no-op. A development OS file-lock provider lives in test-support and is labelled host-local. It must exclude separate processes sharing a target and lock namespace.

Acquire access before reading history for mutation and hold it through client cleanup. Verify exact database/table engines, columns/types and required durability settings before writes. Initialize only with explicit target-bound first-use authorization; ordinary absence is an error. Compatible empty objects left by an interrupted initialization may be completed under the same authorization, while nonempty events lacking valid initialization fail. Bind target key and ledger UUID; an existing ledger's identity must match caller expectations. Allocate contiguous sequences under exclusive access, use safe typed parameter/data encoding, send each append once and await full acknowledgement. On uncertainty return exact event identity, stop, and expose later guarded reconciliation; do not automatically append duplicates or continue. Read-only inspection must not initialize storage.

Document and test fsync_after_insert and synchronous insert requirements for each candidate version in the matrix, validating effective settings rather than assuming requested values were accepted. State separately process/server crash durability and untested power-loss/storage failure. Write ledger/exclusivity ADRs before downstream runner expansion.

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


Consumes Transport/TargetKey/QueryId from `docs/plans/4-implement-direct-http-transport-and-isolated-fault-fixtures.md` and definition descriptors from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md`. Owns LedgerEvent, LedgerPosition, LedgerId, EventId, RunId, AttemptId, initialized ledger context, projected state, guarded append and exact-event reconciliation. A LedgerPosition carries enough identity to reject stale repair/adoption requests, including ledger identity and the exact last sequence/event. Owns recovery/adoption event wire shapes; later plans implement commands using them and coordinate schema changes here before release. `ExclusiveAccess` must run an operation only within an acquired scope and expose loss notification. No mutating API accepts an optional provider. Later runner and adoption plans may add transition tests but cannot invent separate storage protocols.
