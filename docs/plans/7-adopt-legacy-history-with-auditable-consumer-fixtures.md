---
id: 7
slug: adopt-legacy-history-with-auditable-consumer-fixtures
title: "Adopt legacy history with auditable consumer fixtures"
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
      note: "Define absent-ledger expected state and fresh-ledger adoption scope; consume early evidence types."
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
      note: "Specify fresh-ledger adoption APIs, expected state, evidence and delayed-append recovery."
---

# Adopt legacy history with auditable consumer fixtures

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


An application can review and adopt a complete legacy prefix without running its SQL and without falsely claiming historical checksum verification. Interrupted adoption is resumable only with the identical source snapshot, mapping and definitions. Real consumer fixtures demonstrate both fresh replay and existing-history adoption.

## Progress


- [ ] M1 — Pure adoption planning validates the complete mapping and preserves evidence strength.
- [ ] M2 — Audited apply/resume and immutable consumer fixtures pass interruption, conflict and subsequent-migration tests.

## Surprises & Discoveries




## Decision Log


2026-10-15: Require independent fresh-replay and adoption tests. Filename-only legacy evidence cannot establish historical bytes or successful completion of a partially executed file; explicit operator attestation is retained permanently in native history.

## Outcomes & Retrospective




## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

At creation there was no local ADR corpus. The pre-implementation review added [Preserve uncertainty across runtime boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md): unsuccessful requests never authorize automatic replay, successor mutation requires all prior server work to be quiescent, shared ledger types are defined before runtime consumers, and test access must preserve public invariants. Follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. There is no profiled ADR bundle; preserve the plain Markdown convention. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisites: `docs/plans/6-execute-inspect-and-repair-migrations-conservatively.md` and `docs/plans/3-embed-ordered-manifests-with-incremental-rebuild-guarantees.md` must be Complete. They provide guarded history/reports and compiled consumer components. This implements spec section 15 and the adoption portion of section 19. The legacy source is caller-supplied evidence, not an automatic schema detector. Operator-attested means a named operator accepts a reviewed baseline; source-checksum verified additionally means a predecessor actually stored a checksum and historical bytes match its documented algorithm.

`mori://shinzui/kansoku` project-relative `db/clickhouse/migrate.sh` and `db/clickhouse/migrations/` identify the consumer artifacts (artifact-level URIs pending). The inspected script globs SQL files in filename order, uses clickhouse-client multiquery, and records filename/applied_at in analytics.schema_migrations without checksums. Some files therefore need deliberate named step boundaries. `mori://shinzui/rei/okf/adrs/concepts/ADR-11` demonstrates why importing history does not prove a fresh database can replay it. `mori://shinzui/kansoku/okf/adrs/concepts/ADR-2` separates writer ownership/recovery from administrative migration; maintenance coordination must include those writers when needed. No local ADR existed initially; use prerequisite history/recovery records.

## Plan of Work


M1 adds `clickhouse-migrate/src/ClickHouseMigrate/Adoption.hs` and private validation/digest encoding. Define AdoptionRequest containing explicit source identity, bounded source snapshot or digest, mapping digest, actor/reason, target initialization authorization, expected ledger state and per-entry evidence. Pure planning verifies the whole requested prefix, rejecting unknown source rows, duplicate mappings, holes, wrong order, changed definitions and existing native conflicts. Specify deterministic mapping/source digest encodings in `docs/contracts/adoption-v1.md`. Multiple legacy statements may map to one complete native migration only through an explicit reviewed mapping; no runtime SQL splitting or inference from IF NOT EXISTS. Current-file hashing protects the accepted baseline onward, never upgrades filename-only history to verified historical bytes.

M2 implements guarded apply/resume with the ledger schema already defined: validate everything before mutation, append/acknowledge adoption-start with its digest, identifiable entry events and adoption-complete. Incomplete batches block ordinary up. Resume requires identical source/mapping/definition digests plus fresh expected position; a fully committed identical request returns an inspection result without additional writes. Conflicts fail without deletes or compensating history. An uncertain append stops; inspect the exact event under access before deciding the next explicit action. Adoption never executes application SQL.

Add immutable consumer fixtures under `clickhouse-migrate-test-support/test/fixtures/kansoku/`, with a provenance file recording the canonical source project, source revision, exact source paths and digests, reviewed step split/mapping and evidence limits. Capture only checked-in SQL and synthetic filename/time history, no live data. Embed the native component through the embedding package in the integration test component, not the test-support production library. First prove one real multi-statement legacy file as a complete native migration, then cover the full captured history. Test both fresh execution and pre-existing effects plus adoption, followed by an appended native migration. If the captured history cannot replay fresh, record a consumer prerequisite and keep the release gate open; do not rewrite history to hide it.

Document a cutover runbook in `docs/adoption.md`: stop old runner, establish target-wide exclusive administration and required writer maintenance, preserve legacy evidence, review the mapping, apply adoption, verify, and switch the administrative executable so two runners cannot operate. This plan prepares the adapter/fixtures/runbook in this repository. The actual consumer runner replacement is a separately tracked change to `mori://shinzui/kansoku`, gated on the CLI example from the final child; record its canonical change reference and acceptance evidence at initiative completion. Create the adoption-evidence ADR.

Keep v1 adoption limited to a fresh ledger: absent with explicit initialization authorization, or initialized with no execution/adoption history. An interrupted matching batch may resume; an already committed identical batch is inspection-only even if later native migrations have run. Reject a new adoption batch on mixed/native history or a different committed batch before any mutation. This makes the specification's fresh-ledger protocol explicit rather than inventing history-splicing semantics.

Use ExpectedLedgerState from the ledger plan to represent absence before initialization and a concrete LedgerPosition afterward. Pure planning operates on supplied evidence and an inspection snapshot without IO; apply always revalidates inside exclusive access. Initialization, if needed, occurs only after the whole batch is validated. An identical completed request is checked by batch identity/digests before stale-position rejection because it performs no mutation; every path that appends still requires a fresh expected position.

```haskell
planAdoption :: MigrationPlan -> InspectionReport -> AdoptionRequest
             -> Either AdoptionError AdoptionPlan
applyAdoption :: MutationContext -> MigrationPlan -> AdoptionPlan
              -> IO (Either RunFailure RunReport)
resumeAdoption :: MutationContext -> MigrationPlan -> AdoptionPlan
               -> IO (Either RunFailure RunReport)
```

AdoptionPlan is opaque and binds the expected state, target, full source/mapping/definition digests and audit evidence; rebuild it from a fresh inspection for explicit resume. Retain bounded source evidence or a durable resolvable evidence reference beside its digest: a digest alone is neither reviewable history nor proof of predecessor checksums. Use a versioned unambiguous encoding for mapping/snapshot hashes; identity includes the complete mapped prefix and evidence level. Reports use the existing evidence variants. Quiescence covers uncertain adoption and initialization appends; a missing entry in one read never licenses immediate resubmission. Test delayed entries arriving after an empty observation and prove there is no duplicate append or premature adoption-complete.

## Concrete Steps


Create these recipes and execute them with owned isolated servers:

```bash
nix develop -c just test-adoption
nix develop -c just test-consumer-fixtures
```

Outputs must distinguish source-checksum-verified and operator-attested evidence, report exact mapping digest and ledger position, and record application request count zero throughout apply/resume. The fresh fixture test must demonstrate actual application objects, not only ledger rows.

## Validation and Acceptance


Reject duplicate/holey/conflicting mappings before any adoption event. Show source-checksum verification only with an actual predecessor checksum/algorithm fixture; filename-only consumer rows always remain operator-attested. Interrupt start, entry and completion appends before/after acknowledgement; ordinary up remains blocked while incomplete. Identical explicit resume completes without application SQL; a different snapshot/mapping or stale expected state fails. Reapplying a committed identical request adds no rows. Compare the captured consumer's fresh schema behavior to the existing-effects adoption path and then execute exactly one new migration. Local fixture completion does not mark the separate consumer cutover gate complete.

## Idempotence and Recovery


Builds and pure tests may be repeated. Integration tests must allocate their own temporary directories, ports and database names, track their server processes, and clean up only resources they created. Preserve failed-run evidence before cleanup. Never test against a persistent application database. A failed or uncertain mutating request is not safe to repeat: inspect its exact event and attempt under exclusive access, and use the explicit recovery protocol. Do not erase history, rewrite checksums or assume a timeout stopped server work.

## Interfaces and Dependencies


Consumes typed reports/recovery/access from `docs/plans/6-execute-inspect-and-repair-migrations-conservatively.md`, event protocol from `docs/plans/5-build-immutable-ledger-projection-and-exclusive-access.md`, and component embedding from `docs/plans/3-embed-ordered-manifests-with-incremental-rebuild-guarantees.md`. Owns AdoptionRequest, AdoptionPlan, mapping/source digests and source-neutral planning/apply/resume APIs. Consumes EvidenceLevel, ExpectedLedgerState, InitializationAuthorization and audit/quiescence primitives from the ledger plan. The source reader and filename mapping live in fixtures/example adapter or consumer integration, never ordinary up. Ledger projection remains owned by `docs/plans/5-build-immutable-ledger-projection-and-exclusive-access.md` and must represent partial batches before this command logic is introduced. CLI exposes these APIs without adding a force or checksum-rewrite path.

Revision 2026-10-15 — Pre-implementation API/correctness review: Define fresh-ledger adoption, absent-state binding, idempotent inspection and delayed-append safety.
