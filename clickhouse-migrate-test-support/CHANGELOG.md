# Changelog for clickhouse-migrate-test-support

## 0.2.1.0 — 2026-11-14

### Other Changes

- Use Apple Container with exact digest/platform inspection, owned bind mounts
  and inspected replica addresses.
- Cover denied/own-user process observations, callback failure/cancellation,
  exact interrupted receipts and active-work refusal under explicit external
  authority.
- Qualify bounded read-only inspection and the direct Linux arm64 26.8.28.14
  LTS image.

## 0.2.0.0 — 2026-11-08

### New Features

- Add owned Linux arm64 OCI fixtures for exact Altinity
  `26.3.60.10001.altinitystable` and `26.3.60.10002.altinitystable` engines.
- Add Keeper/two-replica fixtures and qualify replicated CLI execution, ledger
  storage, restarts, membership rejection, uncertainty and audited recovery.
- Preserve fixture identity and stable endpoints across owned server restarts.

### Bug Fixes

- Wait for writable database and table replicas during restart readiness.

### Other Changes

- Declare candidate-specific matrix groups and share them across artifact variants.
- Require the 0.2 series of the core, CLI and embedding libraries.

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
