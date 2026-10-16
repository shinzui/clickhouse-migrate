---
type: Review
title: Verify initial library review remediations
description: All three initial library findings are resolved with public native regressions and unchanged persisted formats.
generated:
  by: process:codex
  at: "2026-10-16T19:21:27Z"
reviewId: REV-2
subject: mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate
subjectKind: component
reviewedSha: 1869d639a12662856747b81f3abe0377a0a7e47c
coverage: incremental
baseSha: 3a09f2189bd6fb0c91b5b515d916d219a2a31a15
previousReview: REV-1
reviewedAt: "2026-10-16T19:21:27Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-6.1-sol
effort: high
outcome: approved
dimensions:
  - correctness
  - design
  - test-coverage
  - documentation
  - operability
context: >-
  Implementation-author verification of the changes resolving REV-1/F1, F2 and F3,
  including affected optional CLI and embedding consumers. This is an incremental
  verification by the implementing agent, not an independent second-agent audit,
  release qualification or external consumer cutover.
---

# Verify initial library review remediations

The three findings in [REV-1](initial-library-review.md) are resolved at
`1869d639a12662856747b81f3abe0377a0a7e47c`. The historical review and its captured failing reproductions remain
unchanged. [MasterPlan 2](../masterplans/2-resolve-initial-library-correctness-architecture-and-api-review-findings.md)
and all three children have met their acceptance criteria. No unresolved finding
was identified in the repaired paths within this incremental scope.

## REV-1/F1: explicit component upgrades

The public schedule keeps catalog indices and dependencies separate from execution
ordinals. The native consumer applies A.one/B.one, appends only A.two, verifies
currentness and proves a repeat submits no SQL. A changed grouped prefix still
fails before SQL. Adoption maps A.one/B.one despite A.two being pending; interrupted
A.two recovers at ordinal 2/component index 0. CLI JSON/text expose the same order.

The [schedule fixture](../../clickhouse-migrate-test-support/test/RunnerIntegration.hs)
exercises the public producer/consumer path. The independently encoded
[default descriptor vector](../../clickhouse-migrate/test/vectors/schedule-default-v1.json),
24 checksum vectors and two adoption vectors retain their bytes. All fourteen
public representation/provider bypass fixtures reject. See
[ExecPlan 9](../plans/9-allow-component-upgrades-with-an-explicit-migration-schedule.md)
and [ADR 0010](../adr/0010-separate-component-catalog-from-execution-schedule.md).

## REV-1/F2: complete bounded-row history reads

The original 12-step large-audit reproduction now reads all 27 events with default
limits. The [combined native fixture](../../clickhouse-migrate-test-support/test/ReviewRemediation.hs)
returned 389 logical events from 18,655,399 response bytes; its largest row was
50,876 bytes. A 360-entry adoption batch produced a 17,906,595-byte history and
passed interrupted resume, committed identical reapplication and currentness
without SQL or duplicate entries. Native history rejects a new adoption request.
Status, history, pending execution and recovery work above the old 16 MiB ceiling.

Exact duplicates retain logical position. Truncated HTTP framing, trailing server
errors, oversized rows and late sequence/identity/duplicate conflicts discard the
whole observation and permit no successor write. Deadline and asynchronous
cancellation checks interrupt after response headers and half the body have been
flushed. Every byte split, UTF-8, escapes, CRLF, clean final rows, incomplete rows,
exact raw-row bounds and worst-case outer JSON expansion are covered by core tests.
Ordinary response limits and configured deadlines remain enforced; retained
projection/report memory still grows with history. See
[ExecPlan 10](../plans/10-stream-complete-ledger-history-with-bounded-row-decoding.md)
and [ADR 0011](../adr/0011-read-complete-history-with-bounded-rows.md).

## REV-1/F3: recovery validation before mutation

The [public native reproduction](../../clickhouse-migrate-test-support/test/RepairIntegration.hs)
now returns `RecoveryEventTooLarge RecoveryAcceptanceEvent` with events (3,3),
position, migration attempt and selected step unchanged. It sends no application
SQL or recovery append and emits no recovery acknowledgement callback. Smaller
replacement evidence succeeds against the original position, followed by explicit
finalization. The same sequence passes against the large interleaved history.

Oversized quiescence and combined audit contexts reject authorization. Retry,
resume, accept and finalize retain their existing scope and uncertainty semantics.
Canonical 65,536-byte recovery events pass; 65,537-byte events reject. UTF-8,
JSON escapes and required sequence capacity are checked before authorization.
Prepared deterministic metadata is reused for submission. Six CLI JSON fixtures
include schedule order and safe size rejection; text uses the same safe detail.
See [ExecPlan 11](../plans/11-validate-complete-recovery-events-before-mutation.md)
and [ADR 0012](../adr/0012-prepare-recovery-metadata-before-authorization.md).

## Validation and scope

Full builds of the core, embedding, CLI, test support and mounted example passed.
All three unit suites, public invariants/vectors, eleven embedding rebuild cases,
source-free execution and strict documentation/review/format checks passed. Native
groups `remediation`, `transport`, `ledger`, `runner`, `repair`, `adoption`,
`boundaries`, `survivors`, `cli` and `example` passed on owned disposable
ClickHouse 26.8.28.14 servers. Existing lost-acknowledgement, callback, cleanup,
restart, delayed-event and surviving-server-work cases preserve blocking uncertainty
and explicit recovery. Qualification used the content-aware embedding wrapper with
all five owning manifests, then the resulting native artifacts.

The repository recipes reproduce the principal checks:

```bash
nix develop --builders ''
just test-unit check-public-invariants test-review-remediation
just test-transport test-ledger test-runner test-repair test-adoption
just test-failure-boundaries test-cli test-embedding test-example
just check-docs check-reviews check-format
```

This verification does not claim constant heap usage, unlimited request duration,
a new platform/server release matrix, power-loss durability or an independent
security audit. Publication and MasterPlan 1's external consumer gate remain
outside this initiative.
