---
type: Review
title: Initial library correctness architecture and API review
description: Two architectural constraints and one recovery API defect were reproduced in the initial core library implementation.
generated:
  by: process:codex
  at: "2026-10-16T18:07:57Z"
reviewId: REV-1
subject: mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate
subjectKind: component
reviewedSha: 3a09f2189bd6fb0c91b5b515d916d219a2a31a15
coverage: full
reviewedAt: "2026-10-16T17:52:42Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-6-astra
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - design
  - test-coverage
  - operability
produced:
  - mori://shinzui/clickhouse-migrate/masterplans/2-resolve-initial-library-correctness-architecture-and-api-review-findings
  - mori://shinzui/clickhouse-migrate/plans/9-allow-component-upgrades-with-an-explicit-migration-schedule
  - mori://shinzui/clickhouse-migrate/plans/10-stream-complete-ledger-history-with-bounded-row-decoding
  - mori://shinzui/clickhouse-migrate/plans/11-validate-complete-recovery-events-before-mutation
context: >-
  Whole-core implementation audit, rather than a commit-range review, with optional
  embedding and CLI integration inspected as supporting context. Native tests and
  focused public-API reproductions ran on disposable ClickHouse fixtures. Release
  preparation was explicitly excluded. Concurrent documentation reorganization
  changed paths and one source comment, not the reviewed runtime behavior.
---

# Initial library correctness architecture and API review

The audit examined the core's validated public values, plan construction, direct
HTTP transport, immutable history projection, execution, inspection, recovery and
adoption. Optional embedding and CLI paths were sampled for their interaction with
those contracts; this record does not claim a separate exhaustive review of each
optional package. The reviewer identity and effort were recovered from this
session's turn metadata. The review preceded documentation commit
`398246b9f0aadc1eac84fa256113196bf29f3b10`; current documentation links below use its
new `docs/user` layout.

## REV-1/F1 — P1: earlier components cannot evolve after later components run

`ClickHouseMigrate.Internal.LedgerCodec.definitions` concatenates components and
assigns global ordinals. `ClickHouseMigrate.Internal.Reporting.inspectHistory`
compares persisted definitions with that sequence by position. Applying
`[A.one, B.one]` succeeds, but extending A with `A.two` produces
`[A.one, A.two, B.one]` and fails with `IncompatibleHistory`. Only the last
component can normally gain migrations. This follows the original global-prefix
specification, so it is an architectural constraint rather than a deviation from
that specification. It prevents independent library evolution.

Preserve immutable execution order while decoupling it from component grouping.
[ExecPlan 9](../plans/9-allow-component-upgrades-with-an-explicit-migration-schedule.md)
owns explicit application scheduling, stable identity and adapter consistency.
Source: [LedgerCodec.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerCodec.hs)
and [Reporting.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Internal/Reporting.hs).

## REV-1/F2 — P1: successful execution can outgrow readable history

`ClickHouseMigrate.Internal.LedgerStore.load` requests the entire ledger in one
response. `ClickHouseMigrate.Target.httpLimits` defaults to 1 MiB and permits at
most 16 MiB. Appends do not check aggregate history size. A 12-step migration with
24 valid audit references of 2,000 characters completed, after which a history read
using the same default configuration failed with `ResponseTooLarge`. Raising the
bound to 16 MiB restored this fixture; beyond that ceiling the public API has no
larger setting. Commands that first read history eventually become unusable.

Bound individual records and transport buffers while consuming and validating the
complete history. [ExecPlan 10](../plans/10-stream-complete-ledger-history-with-bounded-row-decoding.md)
owns the private streaming read path and complete-response acceptance. The current
reproduction proves the default-limit failure; the maximum ceiling is a source
finding, not a claim that the fixture exceeded 16 MiB.
Source: [LedgerStore.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerStore.hs),
[Http.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Internal/Http.hs) and
[Target.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Target.hs).

## REV-1/F3 — P2: accepted recovery input fails after changing history

`ClickHouseMigrate.Repair.repair` appends recovery authorization before constructing
the accepted-completion event. That event repeats audit references in its evidence,
so individually valid fields and successful ordinary preflight do not establish
that the complete event fits the 64 KiB codec limit. An accepted `acceptStepRequest`
using the same 24 references and small quiescence evidence returned
`LedgerFailed InvalidEvent` after history advanced from three events to four,
ending in `recovery-authorized`. The step remained unresolved.

Validate the full request-specific recovery event envelopes before the first
append, and return a specific size error without mutating history.
[ExecPlan 11](../plans/11-validate-complete-recovery-events-before-mutation.md) owns
that behavior and public error rendering. Source:
[Repair.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Repair.hs),
[Preflight.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Internal/Preflight.hs)
and [LedgerCodec.hs](../../clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerCodec.hs).

## Evidence and limits

All three unit suites, public invariant/checksum checks, and native runner and
repair suites passed. These findings therefore describe gaps in the existing
acceptance cases. The [diagnostic harness](../../test/review-evidence/initial-library-review/Reproduce.hs),
[actual observations](../../test/review-evidence/initial-library-review/observations.txt)
and [commands and scope](../../test/review-evidence/initial-library-review/checks.txt)
are retained in the repository rather than depending on temporary files.

Private capability boundaries, explicit recovery and preservation of uncertain
outcomes are strengths to retain. This was not an exhaustive security audit, a
performance benchmark or release qualification. No fix is claimed here. This
review remains a historical examination record; a later verification should be a
new review naming its own commit. Current remediation status belongs to
[MasterPlan 2](../masterplans/2-resolve-initial-library-correctness-architecture-and-api-review-findings.md).
