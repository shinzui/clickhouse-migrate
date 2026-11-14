# Changelog for clickhouse-migrate-embed

## 0.2.1.0 — 2026-11-14

### Other Changes

- Release alongside the 0.2.1.0 core; no changes to this package.

## 0.2.0.0 — 2026-11-08

### Other Changes

- Release with the 0.2 core API and require `clickhouse-migrate ==0.2.*`.
- Qualify embedded replicated manifests and SQL through the shared build driver
  and the replicated examples.

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
