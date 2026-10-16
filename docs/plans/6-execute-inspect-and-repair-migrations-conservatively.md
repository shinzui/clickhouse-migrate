---
id: 6
slug: execute-inspect-and-repair-migrations-conservatively
title: "Execute inspect and repair migrations conservatively"
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

# Execute inspect and repair migrations conservatively

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


A caller can execute pending migrations, inspect compatible history and recover explicitly from interruption without replaying uncertain SQL. Reports preserve acknowledged progress, unresolved identities, operator attestations and primary/cleanup failures.

## Progress


- [ ] M1 — Ordered up/status/verify/history operations pass normal runs and every crash boundary.
- [ ] M2 — All four recovery operations and callback/access/cleanup failures preserve durable evidence and refuse stale or unquiesced actions.

## Surprises & Discoveries




## Decision Log




## Outcomes & Retrospective




## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

No local ADR corpus or profiled ADR bundle exists at creation. Before implementation, follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. Create durable decisions in `docs/adr/` using the convention then present; do not introduce a new OKF profile incidentally. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/5-build-immutable-ledger-projection-and-exclusive-access.md` must be Complete. It supplies immutable history, exclusive access and acknowledged transport. This implements specification sections 11–13 and 17. Ordinary execution never repairs implicitly. Quiescence means previous application/server work is no longer running; elapsed time, timeout or an absent process-list row does not prove it. A compatible ledger may still contain pending migrations; requiring current means none remain. No local ADR existed initially; read prerequisite ledger, completion and transport decisions.

## Plan of Work


M1 adds `clickhouse-migrate/src/ClickHouseMigrate/Runner.hs`, `Inspection.hs`, `Report.hs`, and `Event.hs`. `up` first validates the complete supplied plan, then acquires access and the dedicated transport, checks supported server/target/privileges/settings, initializes only with target-bound authorization, and validates the full history/prefix before the first application statement. For each pending migration acknowledge migration start; for each step acknowledge its start with a fresh query ID, submit its exact SQL once, consume the whole response and acknowledge step success. Acknowledge migration completion before advancing. Stop at any error/uncertain acknowledgement. Best-effort bounded failure recording must never cause replay or replace the primary error. Preserve successful earlier steps in partial reports.

`status`, `history` and `verify` read history in one query and never create objects. Unguarded reports say they are observations and identify access strategy/scope when guarded. Absent ledger is explicit and compatible with an unapplied plan for inspection, but is never implicit authorization to initialize. `verify` rejects incompatible or unresolved history; pending alone passes, while require-current fails. Report all identities/order/checksum/adoption evidence needed for later investigation, without SQL bodies or secrets.

M2 adds `clickhouse-migrate/src/ClickHouseMigrate/Repair.hs` using the original bound plan and ledger event definitions. Every repair includes exact expected ledger position/attempt, actor, reason, external evidence and typed quiescence assertion where required; re-read/revalidate inside acquired access. Resume starts the first never-started step only when no uncertain step remains. Retry-step durably authorizes a new attempt/query ID for the same bytes after evidence that retry is safe. Accept-step records an operator attestation without executing SQL or continuing later steps. Finalize records migration completion only when every step is successful or accepted. New attempts link to superseded identities. An authorization without a subsequent step-start remains blocking after a crash, requiring a fresh expected-state request.

Treat event sinks as observations, not audit storage. A throwing callback stops further SQL, preserves already acknowledged state and is reported as callback failure. Emit completion callbacks only after the corresponding acknowledgement. Scope access through deterministic transport cleanup; aggregate primary, failure-recording, callback and cleanup failures without swallowing asynchronous cancellation. Default diagnostics redact credentials, SQL and raw server message bodies; expose raw diagnostics only through explicit caller opt-in. Create `docs/operations.md` with recovery sequences and write runner/recovery ADRs.

## Concrete Steps


Add focused recipes using the owned integration harness and run:

```bash
nix develop -c just test-runner
nix develop -c just test-repair
nix develop -c just test-failure-boundaries
```

`test-failure-boundaries` must enumerate spec section 11 interruption points and every dependent ledger acknowledgement, rather than sample one random crash. Save the event trace, proxy submission counts and final projection for failed cases.

## Validation and Acceptance


A fresh authorized run executes each statement once; a second run submits no application SQL. Normal recurring execution against an absent ledger fails. Modified applied SQL, reordered definitions, unknown stored items, changed dependencies, corrupt history and unresolved work all block before application mutation. Inject interruption before migration start, after migration start, before/after step-start acknowledgement, during SQL, after effect/response loss, after SQL success before success acknowledgement, after recorded step success, before migration completion, and after completion acknowledgement. Restarted ordinary up never replays uncertain work.

Test every repair including stale-position rejection, active prior query refusal, accepted-versus-observed completion, retaining completed steps, and finalization with zero application submissions. Interrupt the repair authorization append and after acknowledgement before new step start. A fresh guard must be required afterward. Kill a client while its server query survives; recovery stays blocked until externally established quiescence. Callback and cleanup faults at each meaningful boundary must preserve the primary failure and acknowledged ledger state. The first M1 integration case is one two-step migration with lost second response followed by guarded inspection; expand to the full matrix only after it passes.

## Idempotence and Recovery


Builds and pure tests may be repeated. Integration tests must allocate their own temporary directories, ports and database names, track their server processes, and clean up only resources they created. Preserve failed-run evidence before cleanup. Never test against a persistent application database. A failed or uncertain mutating request is not safe to repeat: inspect its exact event and attempt under exclusive access, and use the explicit recovery protocol. Do not erase history, rewrite checksums or assume a timeout stopped server work.

## Interfaces and Dependencies


Consumes LedgerPosition, attempts, event schema and guarded storage from `docs/plans/5-build-immutable-ledger-projection-and-exclusive-access.md`. Owns UpOptions, InitializationAuthorization, RunReport, InspectionReport, VerifyOptions, RepairRequest, RecoveryEvidence, typed events and stable core error categories. Public conceptual operations are `up`, `status`, `history`, `verify`, and `repair`, returning typed results without printing, configuration loading or process exit. Expose enough report structure for CLI rendering without driver-specific types. JSON wire encoding belongs to the later CLI plan; domain state/evidence semantics belong here. Adoption extends these reports through existing evidence states rather than a second report model.
