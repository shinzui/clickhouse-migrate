---
id: 10
slug: stream-complete-ledger-history-with-bounded-row-decoding
title: "Stream complete ledger history with bounded row decoding"
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
      at: 2026-10-16T18:48:18Z
      mode: "implement"
      note: "Implement framed complete row stream and native large-history acceptance"
---

# Stream complete ledger history with bounded row decoding

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log and Outcomes & Retrospective current as implementation proceeds.

## Purpose / Big Picture


Resolve [REV-1/F2](../reviews/initial-library-review.md#rev-1f2--p1-successful-execution-can-outgrow-readable-history).
A valid ledger must remain readable after its serialized history exceeds 1 MiB or
16 MiB, without changing the public default HTTP limits. Read its JSON objects one
bounded row at a time and accept the result only after the complete response ends
successfully. This removes an accidental lifetime limit while preserving detection
of truncated or corrupt history.

## Progress


- [x] M1 (2026-10-16; all row byte splits and original native 27-event read): A private streamed-row transport passes split/chunk/late-error tests and the original large-audit history read with default limits.
- [x] M2 (2026-10-16; 18,655,408-byte native history and 17,906,583-byte adoption history): History above 16 MiB is usable through public inspection, execution, recovery and adoption; all rows remain subject to strict projection validation.
- [x] M3 (2026-10-16; native precise stream failures, deadlines/cancellation and transport/ledger/runtime regressions): Native truncation, cancellation and oversized-row cases preserve uncertainty and block dependent writes; contracts and focused regression suites pass.

## Surprises & Discoveries


The original 12-step reproduction now returns all 27 events. A public interleaved
run produces 389 distinct logical events and over 18.65 MB of response data, with
its largest raw row 50,876 bytes. An interrupted 360-entry adoption batch exceeds
17.9 MB and resumes without duplicate entries or application SQL. No private test
seeding was needed. Native fault selection must use numeric sequence maxima:
the SELECT's string alias can order physical rows lexicographically, while the
existing projection correctly sorts and validates numeric sequence values.

## Decision Log


2026-10-16: Stream a single complete ledger SELECT rather than issue multiple
paginated reads. A single result preserves the existing observation boundary and
cannot accidentally skip equal-sequence conflicts between pages. Do not replace
full validation with LIMIT, a suffix query or a cached projection.

2026-10-16: Bound raw row size and decoder buffering, not the sum of valid history
bytes. The returned objects, immutable projection and public history report still
retain all history and therefore use memory proportional to history size. This
plan makes no constant-memory or unlimited-duration claim; configured deadlines
and cancellation remain active.

## Outcomes & Retrospective


Complete streamed ledger reads work at default limits for the original 27-event
reproduction, a 389-event native history (18,655,399 response bytes; largest row
50,876 bytes), and an interrupted/committed 360-entry adoption batch (17,906,595
response bytes). Status, history, require-current verification, pending up,
recovery, adoption resume and identical committed adoption all pass. Exact physical
duplicates retain their logical position; late sequence/identity conflicts,
truncated framing, trailing errors and oversized rows reject the whole read and
permit no mutation. Deadlines and asynchronous cancellation retain their meanings, including
interruption after headers and half of a real response body have been flushed.

The private Rows boundary, complete projection, ordinary response limits and
persisted formats remain intact. [ADR 0011](../adr/0011-read-complete-history-with-bounded-rows.md)
records bounded raw rows and retained-history memory costs. The focused native
transport, ledger, runner, repair, adoption and failure-boundary groups pass. The
MasterPlan's final verification record remains a separate closing step.

## Context and Orientation


Work from the repository root. The core implementation is under
`clickhouse-migrate/src/ClickHouseMigrate`. `Internal/Transport.hs` has private
`RequestKind = Command | JsonRows`, `ResponsePayload = CommandAccepted | Rows
[Object]`, and four outcomes distinguishing positive non-submission, acknowledged
success, observed failure and uncertain submission. `Internal/Http.hs:submit`
currently uses `readBounded` to accumulate an entire response before `classify`.
`Target.hs:httpLimits` accepts at most 16,777,216 bytes and defaults to 1,048,576.
That is reasonable for small metadata/command responses but caps total ledger age.

`Internal/LedgerSchema.hs:readQuery` selects every physical row ordered by sequence
and event UUID. `Internal/LedgerStore.hs:load` sends that through `readRows`, decodes
every row and calls `Internal/Projection.hs:project`. The projection rejects gaps,
conflicting event IDs, conflicting sequence numbers, wrong ledger identity and
impossible transitions; it collapses only identical duplicates. An early row may
be a valid prefix even if a later row is corrupt, so no prefix is usable until the
whole read succeeds. `openStore`, read-only `history`, reconciliation, execution,
repair and adoption all rely on that completeness.

[ADR 0001](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md) requires
uncertainty across response boundaries. [ADR 0005](../adr/0005-admit-direct-connections-and-preserve-request-outcomes.md)
requires direct connection admission and no replay.
[ADR 0006](../adr/0006-freeze-immutable-ledger-and-explicit-coordination.md) requires
full immutable-history validation and disables server partial-result modes.
[ADR 0007](../adr/0007-scope-commands-and-preserve-acknowledged-progress.md) requires
preserving the last acknowledged report and cancellation semantics. This plan
changes transport buffering, not those claims. HTTP source was located through
`mori://snoyberg/http-client/packages/http-client`; consult Mori again before
changing any dependency interaction. No new dependency or package pin is proposed.

## Plan of Work


M1 introduces a private `JsonRowStream` request kind in `Internal/Transport.hs`.
Its successful payload remains `Rows [Object]` so callers receive the same domain
boundary. In `Internal/Http.hs`, implement incremental JSONEachRow decoding over
`HTTP.brRead`: retain an incomplete line, split complete newline-delimited rows,
validate UTF-8/JSON objects, accumulate decoded rows in order, and flush a valid
unterminated final row only at confirmed response EOF. Treat blank whitespace lines
consistently with existing JsonRows behavior. Measure the byte bound before JSON
unescaping; split UTF-8 and escape sequences across reads safely by decoding a
complete row. Accumulate efficiently without repeatedly concatenating the full
history. Bound each pending/complete raw row by configured maxBytes, including
newline policy consistently, and reject an oversized single row before unbounded
allocation. Default limits accommodate the worst JSON-escaped representation of
a valid 64 KiB ledger event plus its outer row envelope; verify that bound with a
fixture rather than assuming event size equals wire-row size.

Apply the exact same server settings as JsonRows: unlimited server read/result
counts and bytes, throwing overflow modes, JSONEachRow default format and full
completion policy. Command and ordinary JsonRows keep their existing total-body
bound. The new mode is private and used only by `LedgerStore.load` for its complete
ledger SELECT and by the initialization empty-history check if appropriate. Keep
schema/identity/storage-policy queries on bounded JsonRows.

Do not return an acknowledged `Rows` value before the entire HTTP body and its
framing complete. Preserve status, exception-header and ClickHouse error-body
classification. A trailing server error after valid rows must discard the rows and
produce failure, never a successful prefix. Malformed JSON, truncation, an
oversized row, timeout or interrupted framing likewise yield no usable rows or
projection. Read bounded error diagnostics for non-success responses; do not
accumulate arbitrary raw bodies. Keep the same no-retry manager and checks before
socket writes. Use one private decoder helper if necessary and register it in all
Cabal source/test component lists that compile core modules directly.

Add unit tests for every byte split of a representative row, multiple rows per
chunk, empty chunks/EOF, blank lines, a final row without newline, CRLF, escaped
newlines, multibyte characters, the exact row bound and bound+1. Tests must prove
no accidental acceptance of a partial last record. Then use the public API and the
original 12-step large-audit fixture: `up` succeeds and a default-limit `history`
now succeeds, returning every recorded event. This is the first native gate.

M2 adds a valid history whose actual serialized SELECT body exceeds 16 MiB. Use
bounded per-event evidence and many valid distinct events, not one oversized event
or invalid fabricated rows. The native test-support setup may batch-insert
prevalidated immutable test events to avoid thousands of fixture roundtrips; this
is private test seeding, not a public append API. Assert measured wire bytes exceed
16,777,216, verify each row is below the configured bound, and check exact event
counts/position after the read. Run public status, verify, a pending up and a
recovery/reconciliation case against this large history. Ensure the adoption
consumer still uses the complete read path and rejects non-fresh history; exercise
a large interrupted/committed adoption batch where it fits existing batch limits.
Retain all physical duplicates until the existing projection validates them.

M3 extends the real fault proxy in
`clickhouse-migrate-test-support/test/scripts/native_fixture.py` and its Haskell
adapter only as needed to truncate a large history response, append a late error,
delay a body or split rows. Add corruption after an otherwise-valid prefix: a late
sequence gap, identity conflict and nonidentical duplicate with equal sequence/ID
must all block mutation. Exact duplicates remain accepted. A failed read must not
initialize or append anything and must not expose a falsely-current inspection.
Check async cancellation and owned socket cleanup through existing tests. Update
`docs/user/contracts/ledger-v1.md`, `docs/user/operations.md` and `Target.hs` Haddocks
to distinguish ordinary response limits from ledger row limits and retained-memory
cost. Record the revised buffering decision in a local ADR and link ADR 0006.

## Concrete Steps


Use the repository's pinned GHC 9.12.4 environment and native Apple Silicon fixture.
All commands run from the repository root. Consult dependency source through Mori
before changing request/body-reader behavior; do not traverse the Nix store.

```bash
nix develop --builders ''
just test-unit
just test-review-remediation
just test-transport
just test-ledger
just test-runner
just test-repair
just test-adoption
just test-failure-boundaries
just check-public-invariants
just check-docs
```

Add pure decoder tests in `clickhouse-migrate/test/Main.hs` or a dedicated unit
module, and register it in the Cabal file. The large-history native cases and shared public consumers live in
`clickhouse-migrate-test-support/test/ReviewRemediation.hs`, selected by
`just test-review-remediation`. That group owns the original reproduction,
large native/adoption histories, pending execution, recovery and stream faults;
existing ledger, runner, repair and adoption groups supply the remaining regressions. The integration driver and test-support fault proxy remain
private. Test recipes own all processes and data roots.

Expected native evidence includes:

```text
history wire bytes > 16777216; every row <= configured maxBytes
history default limits: complete event count and final position match
large-history pending up: succeeds once
truncated/late-error/corrupt history: failure; mutation count unchanged
```

## Validation and Acceptance


Both default-limit and above-maximum cases are required. Merely increasing
`defaultHttpLimits`, raising the 16 MiB cap, dropping old events, reading a suffix,
or returning partial results does not satisfy this plan. Every public operation
that depends on `load` must retain complete-history semantics. Status and history
remain observations, not schema verification or proof that a predecessor request
cannot arrive later. Existing external quiescence requirements still govern writes.

Row-bound tests cover JSON expansion of control characters and large evidence
fields. Full-body acceptance tests distinguish clean EOF from HTTP truncation and
late errors after valid rows. Projection tests prove corruption at the end remains
visible and identical duplicates are not silently skipped by transport. Error and
cleanup reports must retain only safe structured diagnostics, never SQL or raw
response bodies. Run the listed focused suites; do not claim constant total heap
use based on the bounded decoder alone.

## Idempotence and Recovery


This changes no physical schema, persisted checksum, event encoding or ledger UUID.
Old valid histories remain readable. Fixture seeding is restricted to disposable
servers; no production rewrite or compaction is part of acceptance. On any failed
stream, discard the incomplete observation, close the owned transport and stop
mutation. A later explicit read may retry after appropriate coordination; never
retry a write or convert a missing suffix into evidence of non-submission.

## Interfaces and Dependencies


No other child is a hard prerequisite. EP-10 owns the private stream decoder,
request-kind extension, complete response classification and ledger load wiring.
The `TransportOutcome` public meaning and `Rows [Object]` boundary stay stable.
EP-9 in `docs/plans/9-allow-component-upgrades-with-an-explicit-migration-schedule.md`
may change which valid descriptors are expected, but EP-10 transports those events
verbatim. EP-11 in `docs/plans/11-validate-complete-recovery-events-before-mutation.md`
consumes the same fresh validated projection. Do not couple transport to ledger
constructors or let a generic row callback acquire write capability. Coordinate
shared fault fixtures and docs through MasterPlan 2's final combined acceptance.
