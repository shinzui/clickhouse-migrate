# Changelog for clickhouse-migrate-cli

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

- Reusable, composable administrative CLI for `clickhouse-migrate`
  (`ClickHouseMigrate.CLI`) with application-owned configuration, coordination,
  rendering and exit policy.
- Composable parsing and dispatch of guarded commands with explicit result
  contracts (`ClickHouseMigrate.CLI.Parser`, `ClickHouseMigrate.CLI.Handler`).
- Text and `schemaVersion` 1 JSON rendering
  (`ClickHouseMigrate.CLI.Render.Text`, `ClickHouseMigrate.CLI.Render.Json`).
- Bounded adoption input files (`ClickHouseMigrate.CLI.AdoptionFile`).
- Preserves partial evidence, explicit recovery, stdout/stderr separation and
  cancellation.
