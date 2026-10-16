# Changelog for clickhouse-migrate-test-support

## 0.1.0.0 — 2026-10-16

Initial release.

### New Features

- Isolated native ClickHouse server fixtures for consumers' tests
  (`ClickHouseMigrate.TestSupport.Server`).
- Fault-injection proxy (plain and TLS) with per-query and per-ledger-stage
  faults — dropped, truncated, delayed or redirected responses, late errors,
  closed connections and malformed history — plus request evidence that excludes
  SQL and credentials (`ClickHouseMigrate.TestSupport.FaultProxy`).
- Conservative host-local exclusive-access adapter for development and tests
  (`ClickHouseMigrate.TestSupport.ExclusiveAccess`); not distributed fencing.
