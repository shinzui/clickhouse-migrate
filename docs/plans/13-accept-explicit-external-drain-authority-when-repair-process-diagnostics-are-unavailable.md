---
id: 13
slug: accept-explicit-external-drain-authority-when-repair-process-diagnostics-are-unavailable
title: "Accept explicit external drain authority when repair process diagnostics are unavailable"
kind: exec-plan
created_at: 2026-11-13T19:21:21Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-13T19:21:21Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T21:34:38Z
      mode: "implement"
      note: "Implement additive opt-in repair evidence and per-call CLI observer while preserving strict default and frozen JSON"
---

# Accept explicit external drain authority when repair process diagnostics are unavailable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Allow an embedding application with independently validated, retained external
exclusion/drain authority to repair migration history when its ClickHouse role
cannot read `system.processes`. Visible active recorded queries still prevent
repair. Diagnostic absence or denial never establishes drain. This is the scoped
upstream prerequisite of
`mori://shinzui/kansoku/plans/50-accept-portable-drain-evidence-without-cross-user-process-visibility`
and
`mori://shinzui/kansoku/masterplans/7-operate-kansoku-clickhouse-safely-across-deployment-platforms`.

## Progress

- [x] M1 (2026-11-13): Additive `externalDrainRecoveryEvidence`, typed observer states and per-invocation `handleCommandWithExternalDrain` preserve strict existing APIs and JSON v1. A real scoped-role embedding passes denied metadata retry and SDK resume, with observer failure/cancellation and stale-position refusal. Only complete native access-denied code 497 is optional; every other failure remains fatal.
- [ ] M2: Owned native repair covers denied/own-user observations, visible recorded work, stale positions, exact receipts and retained exclusion; qualification and source archives pass before adoption.

Source implementation is now in progress. No package version has been selected
or published. Kansoku still uses released 0.2.0.0; final upstream qualification,
delivery and downstream adoption remain open. The expanded native repair group
passes six denied/own-user operation flows and the existing interrupted-authorization
receipt cases using the explicit policy for fresh recovery.

## Surprises & Discoveries

`Repair.activeQueries` unconditionally calls `Store.readRows` through `callStore`.
A denied observation therefore aborts repair despite independently supplied
`RecoveryEvidence`. Its source already documents that absence is only diagnostic.

The Linux fixtures previously required a Docker/Colima context. They now use
Apple Container, exact inspected image digests/platforms, private bind mounts,
owned lifecycle handles and inspected replica/Keeper addresses. A first smoke
run exposed absent container-name DNS; it failed before bootstrap and retained
evidence. Using inspected addresses passes single-server restart and two-replica
bootstrap without DNS assumptions. CI configuration follows the same runtime;
remote execution remains unclaimed.

## Decision Log

2026-11-13: Use additive evidence and handler functions plus a required typed
observer, preserving existing public constructors and JSON v1. Do not add a
standalone flag that mistakes diagnostic denial for external authority.

2026-11-13: Keep strict recovery as the existing API default. A caller must choose
an explicit external-authority policy before an unavailable observation can be
nonfatal. Never convert an observation exception into an empty active-query list.

## Outcomes & Retrospective

Open. Retain the downstream acceptance evidence and exact qualified source/release
identity here when the library change is delivered.

## Context and Orientation

`clickhouse-migrate/src/ClickHouseMigrate/Repair.hs` defines `recoveryEvidence`,
request constructors, guarded repair and `activeQueries`. The internal
`Internal/RepairTypes.hs` holds the opaque evidence representation.
`Internal/Execution.hs` owns `callStore`, which converts store errors to run aborts.
`Internal/LedgerStore.hs` and its transport modules own guarded reads and error
classification. `Report.hs`, `Event.hs` and the CLI renderer own public diagnostic
reporting; the new policy must not change ledger event hashes or historical bytes.
Read the relevant checked-in user contracts and existing repair integration tests
before changing those surfaces. The plain Markdown ADR corpus includes
[uncertainty boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md)
and [owned CLI policy](../adr/0009-mount-cli-with-owned-policy-and-native-release-evidence.md);
these have been amended with the explicit opt-in and observer contract. There is
no profiled ADR bundle; user documentation has its own strict OKF profile.

Kansoku owns its versioned envelope, persistent PostgreSQL owner/predecessor
binding, expected UUID inventory and retained proof audit. This library does not
parse that application envelope, run deployment commands, sign platform receipts
or acquire cluster-admin credentials. The library continues checking exact native
ledger/server/position identities and the live exclusion capability.

## Plan of Work

For M1, add an explicit observation policy to recovery authorization through a new
public constructor or options API. Preserve `recoveryEvidence`'s current strict
behavior. Distinguish an observed active-query set, an observed empty set and
unavailable diagnostics as separate results. An externally authorized repair may
proceed only after all normal exclusion, target, ledger, position, attempt, step
and receipt checks pass. A nonempty observed set always refuses repair. Only a
failure of the optional process observation may become unavailable; failed ledger
reads, guard loss, malformed history, cancellation or identity errors remain fatal.
Record unavailability through a redacted public diagnostic/report surface so
consumers can retain it without pretending an observation succeeded. Check the
current JSON contract before choosing the report representation.

For M2, extend the existing native repair groups with app-scoped users whose
process access is denied or restricted to their own queries. Exercise one actual
embedding consumer before expanding operation variants. Cover resume, retry,
accept and finalize with existing exact pending-receipt reconciliation. Keep
visible recorded queries active long enough to prove refusal under either policy.
Qualify the actual dependency cohort on each claimed server artifact and run the
source/embedding gates. Check authoritative Hackage metadata and upstream release
tags before choosing versions or a downstream source pin. The downstream project
must adopt a real delivered artifact; no vendored patch substitutes for delivery.

## Concrete Steps

Run from this repository root:

```bash
rg -n 'activeQueries|recoveryEvidence|RecoveryEvidence' clickhouse-migrate
rg -n 'repair|PriorQueriesActive' clickhouse-migrate-test-support
nix develop -c just test-unit
nix develop -c just test-repair
nix develop -c just test-failure-boundaries
```

Inspect `justfile` for the full current qualification/source-archive commands and
run those for the final artifact. Expected native evidence has nonzero cases,
zero failures and no skipped required cases. Missing native prerequisites leave
M2 unaccepted rather than substituting deterministic tests.

## Validation and Acceptance

An owned embedding application obtains exclusion, retains external drain proof
and explicitly authorizes the unavailable-diagnostics policy. Denied process reads
are reported as unavailable and supported repairs complete without cross-user
visibility. The same denied read under the existing strict API refuses with a
clear diagnostic. An empty restricted view alone never authorizes a repair.
Observed recorded active work blocks both policies. Stale ledger position,
foreign server/ledger, unresolved/conflicting receipts and lost exclusion continue
to fail before recovery ledger writes. Cancellation is propagated. Original
ledger SQL, migration hashes and applied events stay unchanged.

## Idempotence and Recovery

Every failed or interrupted native attempt preserves its exact receipts and
requires fresh application-owned drain authority on resume. Owned fixtures stop
only processes/containers they created. Reruns use new owned data roots. Do not
publish or select a version merely to make downstream compilation pass.

## Interfaces and Dependencies

The proposed observation-policy type/API is new work, not an existing exported
symbol. `RecoveryEvidence` remains opaque. The existing strict constructor remains
source-compatible. New public reporting must preserve existing renderer contracts
or explicitly version the changed contract. Downstream consumption is owned by
`mori://shinzui/kansoku/plans/50-accept-portable-drain-evidence-without-cross-user-process-visibility`.
