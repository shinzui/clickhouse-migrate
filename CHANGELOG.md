# Changelog

All published packages share a single version and are released together under
one `v<version>` tag. Per-package details live in each package's `CHANGELOG.md`.

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
