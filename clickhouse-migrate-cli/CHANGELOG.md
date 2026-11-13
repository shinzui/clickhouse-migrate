# Changelog for clickhouse-migrate-cli

## Unreleased

- Add per-invocation `handleCommandWithExternalDrain` for embedding applications, preserving the ordinary handler, parser and JSON v1.

## 0.2.0.0 — 2026-11-08

### Breaking Changes

- Extend the JSON v1 contract with both checksum formats in offline plans,
  the recorded checksum format in history/status, and replicated initialization
  fields and error codes.

### New Features

- Populate offline plans with v1 and v2 migration and step digests.
- Render replicated history and failures with structured evidence.

### Other Changes

- Retain legacy `PlanStep` and `PlanMigration` construction and matching arities;
  legacy manually constructed reports render unknown v2 digests as null.
- Require `clickhouse-migrate ==0.2.*` and update JSON golden fixtures.

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
