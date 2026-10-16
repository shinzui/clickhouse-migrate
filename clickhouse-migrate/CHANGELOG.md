# Changelog for clickhouse-migrate

## 0.1.0.0 — 2026-10-16

Initial release.

### New Features

- Validated, ordered migration definitions and plans built through public smart
  constructors, with exact SQL byte preservation and a constrained statement
  envelope (`ClickHouseMigrate.Definition`, `ClickHouseMigrate.Plan`).
- Checksum v1: context-aware SHA-256 over immutable plan views, verified against
  independent test vectors.
- Explicit component catalogs separated from an explicit execution schedule, so
  components can be upgraded under a declared migration order.
- Conservative direct HTTP transport to ClickHouse with validated, application-owned
  `TargetConfig` and no implicit credentials (`ClickHouseMigrate.Target`).
- Immutable ledger events with guarded bootstrap, qualified uncertain appends,
  guarded reconciliation and complete-history reads with bounded row decoding
  (`ClickHouseMigrate.Ledger`, `ClickHouseMigrate.Event`).
- Externally serialized exclusive administrative access
  (`ClickHouseMigrate.ExclusiveAccess`).
- Execution (`up`), status, history and verify with scoped evidence; uncertain
  work blocks ordinary `up` (`ClickHouseMigrate.Runner`,
  `ClickHouseMigrate.Inspection`, `ClickHouseMigrate.Report`).
- Evidence-guarded repair and recovery that validate complete recovery events
  before any mutation (`ClickHouseMigrate.Repair`).
- Source-neutral legacy history adoption preserving reviewed source evidence and
  native baselines (`ClickHouseMigrate.Adoption`).
- Asynchronous cancellation propagates after bounded cleanup.

Qualified against ClickHouse 26.8.28.14 LTS (official Apple Silicon macOS binary).
