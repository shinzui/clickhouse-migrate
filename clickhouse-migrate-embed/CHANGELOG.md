# Changelog for clickhouse-migrate-embed

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

- Compile-time embedding of ordered migration manifests
  (`ClickHouseMigrate.Embed`), reconstructed through the public
  `clickhouse-migrate` constructors.
- Manifest validation: duplicate-key rejection and path containment.
- Content-qualified rebuilds: declared inputs are fingerprinted so Cabal cannot
  skip recompilation when embedded SQL changes, including for incremental and
  source-free consumers built from source distributions.
