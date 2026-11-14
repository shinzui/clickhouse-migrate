# Changelog

All published packages share a single version and are released together under
one `v<version>` tag. Per-package details live in each package's `CHANGELOG.md`.

## Unreleased

- Add explicit bounded SELECT-only inspection for constrained reader roles; preserve strict defaults and refuse overflowing histories.

- Add explicit external-drain repair authority with required typed process diagnostics, preserving strict defaults and CLI JSON v1.
- Run owned Linux single-server and replicated qualification fixtures through Apple Container.

## 0.2.0.0 — 2026-11-08

### Breaking Changes

- Extend public checksum, target-error, transport-error, ledger-error, history
  and run-error variants for replicated targets; consumers with exhaustive
  matches must handle the new constructors.
- Introduce checksum v2, SQL envelope v2 and replicated ledger initialization
  and completion policies. Replicated targets require v2; direct targets retain
  v1 behavior. CLI JSON v1 gains checksum-format and replicated-event fields.

### New Features

- Admit validated single-shard replica sets and wait for every configured replica
  on acknowledged migration writes and ledger appends.
- Support replicated MergeTree engines and structurally validated replicated
  ledgers, with topology-specific preflight and guarded recovery.
- Report both checksum formats in offline CLI plans.
- Qualify exact Altinity `26.3.60.10001.altinitystable` and
  `26.3.60.10002.altinitystable` Linux arm64 artifacts alongside the existing
  native ClickHouse candidate; provide owned Keeper/two-replica fixtures.

### Bug Fixes

- Wait for writable database and table replicas during fixture restart readiness.

### Other Changes

- Centralize server policy and matrix qualification; add independent checksum v2
  vectors, replicated examples, contract documentation and retained qualification
  evidence.
- Consolidate the unpublished 0.1.0.1, 0.1.0.2 and 0.1.1.0 candidates into this
  release. Managed-cloud and production qualification remain application-owned.

## 0.1.0.0 — 2026-10-16

Initial release of `clickhouse-migrate`, `clickhouse-migrate-embed`,
`clickhouse-migrate-cli` and `clickhouse-migrate-test-support`.

### New Features

- **clickhouse-migrate**: validated ordered migration definitions and plans with
  exact-byte checksum v1; explicit component catalogs and execution schedules;
  conservative direct HTTP transport; immutable ledger with guarded bootstrap,
  uncertain-append qualification and bounded complete-history reads; scoped
  execution, inspection, verification, evidence-guarded repair/recovery and
  source-neutral legacy adoption.
- **clickhouse-migrate-embed**: compile-time embedding of ordered manifests with
  validation and content-qualified rebuilds.
- **clickhouse-migrate-cli**: reusable administrative CLI with guarded commands,
  explicit result contracts and text / `schemaVersion` 1 JSON rendering.
- **clickhouse-migrate-test-support**: isolated native server fixtures and a
  fault-injection proxy for consumers' tests.

Qualified against ClickHouse 26.8.28.14 LTS (official Apple Silicon macOS binary).
