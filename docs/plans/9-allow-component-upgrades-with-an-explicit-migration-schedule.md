---
id: 9
slug: allow-component-upgrades-with-an-explicit-migration-schedule
title: "Allow component upgrades with an explicit migration schedule"
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
      at: 2026-10-16T18:43:36Z
      mode: "implement"
      note: "Implement explicit application schedule and its native consumers"
---

# Allow component upgrades with an explicit migration schedule

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log and Outcomes & Retrospective current as implementation proceeds.

## Purpose / Big Picture


Resolve [REV-1/F1](../reviews/initial-library-review.md#rev-1f1--p1-earlier-components-cannot-evolve-after-later-components-run).
After A.one and B.one have run, an application must be able to append A.two from
library A and execute only that migration. An explicit application-owned schedule
records the complete execution order independently of the libraries' component
catalog. It preserves global history comparison instead of treating applied
migrations as an unordered set.

## Progress


- [x] M1 (2026-10-16; unit tests and unchanged independent checksum vectors): Validated schedule API represents A.one, B.one, A.two and preserves existing default-plan descriptors and checksums.
- [x] M2 (2026-10-16; native runner, adoption and interrupted ordinal-2 recovery): A public native upgrade applies only A.two, and inspection, recovery and adoption use the same schedule.
- [ ] M3: CLI/example consumers expose execution order correctly; negative regressions, public invariants and user/ADR contracts pass.

## Surprises & Discoveries


Native adoption and repair both consume the centralized definition schedule
without separate state-machine changes. The interleaved fixture confirms that
ordinal 2 retains component index 0.

## Decision Log


2026-10-16: Preserve the component catalog's stable order and every persisted
ordinal. Add an explicit complete schedule, retaining `migrationPlan` as the
existing component-concatenation convenience. Do not silently reorder an existing
plan based on its target's history. All component migrations must appear exactly
once in the explicit schedule.

2026-10-16: Component dependencies constrain initial component activation. The
application schedule explicitly states later upgrade prerequisites by ordering
those migrations. Do not invent an unversioned claim that every future migration
of A must precede every already-applied migration of B. Document that a library
requiring a particular later migration must communicate that requirement to the
application author; this change does not introduce a versioned dependency language.

## Outcomes & Retrospective


The explicit schedule API, descriptor mapping, CLI schedule output and application
example are implemented. Native A.one/B.one history accepts only appended A.two;
repetition is a no-op and changed prefixes fail before SQL. Adoption maps the real
prefix and interrupted recovery selects ordinal 2/component index 0. Independent
checksum vectors and public invariant checks pass. Final embedding rebuild
qualification and the post-fix verification record remain pending.

[ADR 0010](../adr/0010-separate-component-catalog-from-execution-schedule.md)
records the durable catalog/schedule and dependency-activation decisions.

## Context and Orientation


Work from the repository root. The four Cabal packages are core, optional embedding,
optional CLI and isolated test support. The core's
`clickhouse-migrate/src/ClickHouseMigrate/Definition.hs` builds private migrations
and components. `Plan.hs` validates component names, dependencies and order and
binds checksums to component/migration/step identity. Its current private
`MigrationPlan` in `Internal/Types.hs` contains only grouped component views.
`Internal/LedgerCodec.hs:definitions` flattens those groups and stores both a
component index and a global migration ordinal. An ordinal is the zero-based
position in the execution schedule. `Internal/Projection.hs` compares the stored
prefix with those descriptors. `Internal/Execution.hs:orderedMigrations` separately
flattens groups, and `Runner.hs` drops the completed count to select pending work.
Both flattening paths must change together.

`Internal/Reporting.hs` produces public reports by ordinal. `Repair.hs` locates the
selected migration at its persisted ordinal. `Internal/AdoptionValidation.hs`
constructs a batch from the beginning of the native definition order. A schedule
change must reach all of them; changing only the runner would mislabel history or
adopt the wrong migrations. `clickhouse-migrate-cli/src/ClickHouseMigrate/CLI/Handler.hs:planReport`
currently renders groups only. Its `Types.hs`, `Render/Json.hs`, `Render/Text.hs`
and test goldens need an explicit execution-order view. Embedding produces a
`MigrationComponent`; it should continue to do so without owning application order.

[ADR 0003](../adr/0003-bind-checksums-through-invariant-safe-definitions.md) requires
private executable values and unchanged identity-bound SQL checksums.
[ADR 0006](../adr/0006-freeze-immutable-ledger-and-explicit-coordination.md) requires
an immutable global prefix including dependencies and component indices.
[ADR 0007](../adr/0007-scope-commands-and-preserve-acknowledged-progress.md) requires
complete compatibility validation before SQL.
[ADR 0008](../adr/0008-adopt-reviewed-prefixes-with-explicit-evidence.md) requires
adoption to map the real native prefix. Preserve these protections; document the
new distinction between a component catalog and its explicit execution schedule.
The review diagnostic is `test/review-evidence/initial-library-review/Reproduce.hs`.

## Plan of Work


M1 adds a validated `migrationIdFromNames :: ComponentName -> MigrationName ->
MigrationId` in `Definition.hs`, plus `scheduledMigrationPlan :: NonEmpty
MigrationComponent -> NonEmpty MigrationId -> Either PlanError MigrationPlan`
and `inspectSchedule :: MigrationPlan -> NonEmpty MigrationView` in `Plan.hs`.
Provide a list-boundary variant if needed consistently with existing constructors.
The existing `migrationPlan` produces the same concatenated schedule as today,
and `inspectPlan` continues to inspect the component catalog. Private storage
holds both, or equivalent private validated references, with no public unchecked
constructor. Re-export the new safe API through `ClickHouseMigrate.hs`.

Validate the existing component graph and catalog order first. Resolve each
scheduled identity against that catalog, reject unknown/duplicate/missing entries,
and require each component's migration subsequence to equal its authored order.
When a component first appears, every declared dependency must have appeared
already. This rejects B.one before any A migration while allowing A.one, B.one,
A.two. The application owns the explicit placement of later upgrades. Add precise
`PlanErrorCode` values and structured paths/names in `Error.hs`; do not emit SQL.
Freeze baseline descriptors/checksums for ordinary plans and test the new order
through public inspection before touching native execution.

M2 centralizes the ordered migration view. Derive ledger ordinals from
`inspectSchedule`, but derive component indices/dependencies from the stable
catalog. Replace every independent component flattening used for execution,
preflight, reporting, recovery and adoption. Persisted descriptors for the existing
prefix A.one, B.one must remain byte-identical; A.two receives the next global
ordinal and A's original component index. Run the smallest native upgrade through
public `up`, check that A.one and B.one execute once total, then verify currentness
and a no-op repeat. Interrupt A.two and recover it by exact original step identity.
Test adoption of the schedule's prefix and subsequent execution of its suffix.
Do not change checksum-v1, ledger-v1 or migration identities to make the test pass.

M3 changes the CLI plan report to retain grouped authoring information and expose
an explicit ordered list of component/migration identities. Keep schemaVersion 1
fields stable and add a documented schedule field; update the Haskell report
constructor and every consumer/golden consistently. Text output must show execution
order rather than imply grouped order is executable. Update
`examples/two-components/app/app/Main.hs` and its README to own an explicit
schedule, demonstrating the second library version appending an earlier-component
migration. Update `docs/user/authoring.md`, `docs/user/cli.md`, affected contracts,
and the outdated global-grouping passages of `docs/initial-spec.md`, marking that
those design passages are superseded. Create a focused ADR explaining the choice
and link it from ADR 0006/0007/0008 as appropriate without erasing their history.
The repository's ADRs are plain Markdown, not an OKF ADR bundle; preserve that
convention unless a separately authorized migration changes it.

## Concrete Steps


Use the existing pinned GHC 9.12.4 development environment at the repository root.
Use Mori to locate any dependency API source before relying on it; this work needs
no new dependency or pin. Start with the public definition and unit tests, then
extend the existing native suites. Commands after the relevant edits are:

```bash
nix develop --builders ''
just test-unit
just check-public-invariants
just test-runner
just test-repair
just test-adoption
just test-cli
just test-embedding
just check-docs
```

Assertions live in `clickhouse-migrate/test/Main.hs`, including the independently
encoded `clickhouse-migrate/test/vectors/schedule-default-v1.json` descriptor
fixture. The public upgrade, adoption-prefix and interrupted recovery checks share
`clickhouse-migrate-test-support/test/RunnerIntegration.hs:scheduleUpgrade`.
Existing repair and adoption suites continue to verify their state machines.
The existing test recipes select owned disposable fixtures; use no persistent
database. CLI unit tests live in `clickhouse-migrate-cli/test/Main.hs`. Update the
public consumer fixture `clickhouse-migrate/test/public/Valid.hs` to compile the
new API while retaining all fourteen negative invariant cases.

Expected observable trace for the new native case is:

```text
initial schedule A.one B.one: applied
upgraded schedule A.one B.one A.two: only A.two applied
repeat upgraded schedule: no application SQL
verify require-current: success
```

## Validation and Acceptance


M1 must reject omitted migrations, unknown identities, duplicate schedule entries,
reversed migrations within a component, a dependent component introduced before
its dependency, dependency cycles and changed catalog order. Original grouped
plans and checksum vectors must retain exactly their previous encodings. Changing
only descriptions stays compatible. Explicit scheduling grants no authority to
change applied SQL, step boundaries, migration names, component indices,
dependencies or recorded execution order.

M2's public upgrade is the early producer/consumer gate. A changed prefix still
fails before application SQL. After an interrupted interleaved migration, repair
must select its actual schedule ordinal rather than an item from the old grouped
flattening. Adoption must map A.one, B.one when that is the declared prefix, even
though A contains another pending migration. Reports and CLI plan output must
agree on A.one, B.one, A.two. Run all listed suites and retain concise successful
outputs; passing compilation alone does not close this plan.

## Idempotence and Recovery


All native checks use newly owned fixture servers and temporary data roots. The
source change is additive; existing plans keep their original ordering. An
application upgrading an existing ledger must retain its previous schedule verbatim
and append new entries. Never rewrite events or recompute stored ordinals. If a
schedule fails compatibility, correct the supplied schedule and retry the read;
do not force execution. Test interruptions continue to require explicit recovery.

## Interfaces and Dependencies


There are no hard prerequisites among MasterPlan 2's children. EP-9 owns schedule
identity, the catalog/schedule distinction and schedule rendering. EP-10 in
`docs/plans/10-stream-complete-ledger-history-with-bounded-row-decoding.md` consumes
unchanged persisted events; EP-11 in
`docs/plans/11-validate-complete-recovery-events-before-mutation.md` must prepare
recovery against the selected schedule descriptor. Coordinate edits to
`Internal/Execution.hs`, reporting, CLI JSON and their contracts. This plan does
not weaken external coordinator promises or introduce implicit runtime scheduling.
