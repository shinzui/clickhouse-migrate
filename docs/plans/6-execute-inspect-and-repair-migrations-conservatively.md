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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T04:57:58Z
      verdict: "changes-requested"
      note: "Define runtime API and partial failure shape; scope retry-step and all-request quiescence."
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
      note: "Define command signatures, partial failures, cancellation and explicit repair scope."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T14:30:09Z
      mode: "implement"
      note: "Implement runner, plan-aware inspection and explicit recovery on the accepted native ledger protocol."
---

# Execute inspect and repair migrations conservatively

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


A caller can execute pending migrations, inspect compatible history and recover explicitly from interruption without replaying uncertain SQL. Reports preserve acknowledged progress, unresolved identities, operator attestations and primary/cleanup failures.

## Progress


- [x] M1 — Ordered up/status/verify/history operations pass normal runs and every crash boundary.
- [x] M2 — All four recovery operations and callback/access/cleanup failures preserve durable evidence and refuse stale or unquiesced actions.

M1/M2 accepted 2026-10-16 on native Apple Silicon / ClickHouse 26.8.28.14 LTS. Public up/status/history/verify and every repair builder compile and run without private test access. The required first lost-second-response case passed before expansion. Full acceptance enumerates 18 ordinary observer boundaries, seven ordinary dependent append acknowledgements (including initialization and both steps), all four interrupted recovery authorizations both after acknowledgement and with response loss, acceptance/finalization append loss and the accepted-step observer boundary. Observed SQL errors preserve their primary error through uncertain failure recording and throwing observers; lease/release/diagnostic faults retain acknowledged state. Modified SQL, dependencies/order, unknown stored definitions, corrupt physical rows, missing recurring ledgers and dynamic namespace reservations refuse mutation. Retry is step-only, resume is migration-only, accept/finalize submit no SQL, stale/fabricated attempt owners fail, and accepted evidence remains distinct.

An owned client process kill and asynchronous thread cancellation both leave a real blocked server mutation alive. Active query IDs refuse recovery even under deliberately false negative-test evidence, and the real host-local marker refuses successor entry after OS unlock. Externally established complete request/mutation drain then allows audited acceptance/finalization without replay. Cancellation is rethrown after cleanup.

Validation: `just test-integration` groups pass in the Cabal harness (the initial combined run's pre-readiness fixture exit was retained and its remaining groups passed serially). All eight groups pass against the Nix-built public harness and Nix core driver. All four public runner/repair/boundaries/survivors groups pass from extracted sibling source archives at `/tmp/clickhouse-migrate-ep6-sdist-dq8qfii1`; direct execution sets Cabal's generated data-directory override to the extracted package. Package metadata, unit tests, twelve public invariant negatives, 24 independent checksum vectors, format checks, Seihou drift and all six native flake checks pass. Logs: `/tmp/clickhouse-migrate-ep6-{cabal-all,serial-final,nix-qualification,pure-final,flake,format-check}.log`. No Linux/remote or release qualification is claimed.

## Surprises & Discoveries

2026-10-16: A migration's current attempt can change at recovery authorization before a new step query is submitted. A selected uncertain step must retain its original attempt owner; reports and validation preserve this distinction. Substituting the new migration attempt for the old step owner is rejected.

2026-10-16: Stopping merges makes a real mutations_sync=1 query remain active deterministically. Both terminating an owned public-API client process and asynchronous cancellation leave server mutation work alive. The host-local persistent marker refuses successor entry until explicit evidence; a deliberately false attestation/overlapping negative-test provider is still rejected while the recorded query is positively active. After independently observed effects and complete request/mutation drain, accept/finalize preserve evidence without replay.


## Decision Log

2026-10-16: Use configuration-only public command contexts, latest-acknowledged snapshots and separate transient SQL observations/secondary errors. Freeze this and the narrow repair scopes in [ADR 0007](../adr/0007-scope-commands-and-preserve-acknowledged-progress.md). Publish application-owned operational responsibilities in docs/operations.md. No new core dependency or wire-format change is needed.


## Outcomes & Retrospective

Complete. Scoped commands use the accepted ledger wire format and preserve uncertainty at every tested boundary. ADR 0007 and docs/operations.md carry durable integration/recovery responsibilities. The next child can consume typed reports and private scoped runtime support for adoption; it must validate the entire adoption request before any initialization/adoption append. The optional Nix integration-tests output qualifies public consumers with the actual Nix dependency closure and does not start servers inside default package builds.


## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

At creation there was no local ADR corpus. The pre-implementation review added [Preserve uncertainty across runtime boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md): unsuccessful requests never authorize automatic replay, successor mutation requires all prior server work to be quiescent, shared ledger types are defined before runtime consumers, and test access must preserve public invariants. Follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. There is no profiled ADR bundle; preserve the plain Markdown convention. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/5-build-immutable-ledger-projection-and-exclusive-access.md` must be Complete. It supplies immutable history, exclusive access and acknowledged transport. This implements specification sections 11–13 and 17. Ordinary execution never repairs implicitly. Quiescence means previous application/server work is no longer running; elapsed time, timeout or an absent process-list row does not prove it. A compatible ledger may still contain pending migrations; requiring current means none remain. No local ADR existed initially; read prerequisite ledger, completion and transport decisions.

## Plan of Work


M1 adds `clickhouse-migrate/src/ClickHouseMigrate/Runner.hs`, `Inspection.hs`, `Report.hs`, and `Event.hs`. `up` first validates the complete supplied plan, then acquires access and the dedicated transport, checks supported server/target/privileges/settings, initializes only with target-bound authorization, and validates the full history/prefix before the first application statement. For each pending migration acknowledge migration start; for each step acknowledge its start with a fresh query ID, submit its exact SQL once, consume the whole response and acknowledge step success. Acknowledge migration completion before advancing. Stop at any error/uncertain acknowledgement. Best-effort bounded failure recording must never cause replay or replace the primary error. Preserve successful earlier steps in partial reports.

`status`, `history` and `verify` read history in one query and never create objects. Unguarded reports say they are observations and identify access strategy/scope when guarded. Absent ledger is explicit and compatible with an unapplied plan for inspection, but is never implicit authorization to initialize. `verify` rejects incompatible or unresolved history; pending alone passes, while require-current fails. Report all identities/order/checksum/adoption evidence needed for later investigation, without SQL bodies or secrets.

M2 adds `clickhouse-migrate/src/ClickHouseMigrate/Repair.hs` using the original bound plan and ledger event definitions. Every repair includes exact expected ledger position/attempt, actor, reason, external evidence and typed quiescence assertion where required; re-read/revalidate inside acquired access. Resume starts the first never-started step only when no uncertain step remains. Retry-step durably authorizes a new attempt/query ID for the same bytes after evidence that retry is safe. Accept-step records an operator attestation without executing SQL or continuing later steps. Finalize records migration completion only when every step is successful or accepted. New attempts link to superseded identities. An authorization without a subsequent step-start remains blocking after a crash, requiring a fresh expected-state request.

Treat event sinks as observations, not audit storage. A throwing callback stops further SQL, preserves already acknowledged state and is reported as callback failure. Emit completion callbacks only after the corresponding acknowledgement. Scope access through deterministic transport cleanup; aggregate primary, failure-recording, callback and cleanup failures without swallowing asynchronous cancellation. Default diagnostics redact credentials, SQL and raw server message bodies; expose raw diagnostics only through explicit caller opt-in. Create `docs/operations.md` with recovery sequences and write runner/recovery ADRs.

Freeze the public operation shapes in M1 and compile an application consumer before adding the full failure matrix:

```haskell
up :: MutationContext -> UpOptions -> MigrationPlan
   -> IO (Either RunFailure RunReport)
status :: InspectionOptions -> TargetConfig -> MigrationPlan
       -> IO (Either InspectionFailure InspectionReport)
history :: InspectionOptions -> TargetConfig
        -> IO (Either InspectionFailure HistoryReport)
verify :: InspectionOptions -> TargetConfig -> VerifyOptions -> MigrationPlan
       -> IO (Either InspectionFailure VerificationReport)
repair :: MutationContext -> MigrationPlan -> RepairRequest
       -> IO (Either RunFailure RunReport)
```

MutationContext is validated caller configuration: target, mandatory ExclusiveAccess provider, event sink and diagnostic policy, with no live acquired resources. Each operation acquires/releases its own scope. InspectionOptions explicitly selects unguarded observation or an acquired provider; there is no implicit mutation-capable session. Pure `inspectPlan` is owned by the definition plan. RunFailure contains the primary typed error, the latest acknowledged RunReport and separate secondary recording/callback/cleanup errors. Reports distinguish observed failures, uncertain application submissions and uncertain ledger acknowledgements, carrying exact request/event identities for investigation. Secondary errors do not overwrite primary errors or completed work. History reports need no current plan so operators can inspect incompatible stored definitions.

RepairRequest is a validated operation-specific sum: resume/finalize name a migration attempt; retry/accept additionally name the exact step attempt. Every variant carries expected position and audit evidence, and any possible prior work requires typed quiescence evidence. Retry-step executes only its named step under a new authorized attempt; it does not run the remaining suffix or finalize implicitly. Resume runs the remaining never-started steps of that migration and records completion; it does not begin another migration. If no steps remain, use finalize. Accept-step and finalize submit no application SQL. Adoption uses the same failure/report envelope.

Treat asynchronous cancellation separately from synchronous RunFailure: perform bounded cleanup and rethrow cancellation. Do not promise that every cancelled call returns a report or emits a final JSON document. Best-effort failure recording is allowed only with retained access, no unreconciled preceding ledger append (including one with an observed server failure) and a known safe next sequence. After lease loss or uncertain append, submit no further writes, including failure recording. Require quiescence for prior ledger/initialization requests as well as application queries before recovery.

Compile a consumer that constructs an explicit provider, initializes once, persists the returned ledger ID, inspects history, roundtrips an expected-position token and builds each repair variant. Add tests proving retry-step leaves subsequent steps untouched, resume stops at the selected migration, synchronous failures retain progress, and cancellation is rethrown after cleanup.

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


Consumes LedgerPosition, attempts, event schema and guarded storage from `docs/plans/5-build-immutable-ledger-projection-and-exclusive-access.md`. Owns UpOptions, MutationContext, RunReport, RunFailure, InspectionOptions, InspectionReport, InspectionFailure, HistoryReport, VerificationReport, VerifyOptions, RepairRequest, RecoveryEvidence, typed events and stable core error categories. InitializationAuthorization, ExpectedLedgerState, AuditContext, QuiescenceEvidence and EvidenceLevel are consumed from the ledger plan. Public conceptual operations are `up`, `status`, `history`, `verify`, and `repair`, returning typed results without printing, configuration loading or process exit. Expose enough report structure for CLI rendering without driver-specific types. JSON wire encoding belongs to the later CLI plan; domain state/evidence semantics belong here. Adoption extends these reports through existing evidence states rather than a second report model.

Revision 2026-10-15 — Pre-implementation API/correctness review: Specify runtime signatures, partial failures, cancellation and operation-specific recovery scope.
