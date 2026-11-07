# Changelog for clickhouse-migrate

## 0.1.1.0 — 2026-11-07

Add validated single-shard replicated targets, full-replica completion policy,
checksum v2 and replicated ledgers. Extend the lexical envelope for replicated
MergeTree engines and add owned Keeper/two-replica qualification. Preserve direct
request bytes and v1 vectors; centralize server policy and matrix qualification
tooling. CLI plan JSON adds both checksum formats, preserving v1 fields.


## 0.1.0.2 — 2026-11-07

Add exact Altinity `26.3.60.10002.altinitystable` engine qualification with an
owned Linux arm64 artifact; retain both previously qualified patches.


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
