# clickhouse-migrate

A Haskell migration toolkit for a directly pinned ClickHouse server. The initial
implementation is tracked in [MasterPlan 1](docs/masterplans/1-bootstrap-the-initial-clickhouse-migration-library.md).
Migration operations are not implemented yet.

The workspace contains `clickhouse-migrate` (core), `clickhouse-migrate-embed`
(compile-time definitions), `clickhouse-migrate-cli` (application-mounted commands),
and `clickhouse-migrate-test-support` (isolated server and fault fixtures).
The core dependency closure excludes the optional packages.

Enter the pinned GHC 9.12.4 environment with `nix develop`, then run:

```bash
just build
just check-packages
just test-unit
just sdist
just check-format
```

`nix flake check` builds all packages and checks formatting. CI is configured for the same
compiler and formatting gates on Linux and macOS. Linux execution is currently
deferred; only local macOS checks have run. Behavioral suites will use
`clickhouse-migrate-unit`, `clickhouse-migrate-embed-test`,
`clickhouse-migrate-cli-test`, and `clickhouse-migrate-integration`. No pass-only
tests are installed for the scaffold. `just test-integration` currently reports
that the isolated fixture has not been implemented.

The manual `internal-test-driver` core Cabal flag defaults to off. EP-4 will supply
the private executable used by the test-support integration suite; production
packages never expose private transport or ledger operations.

Seihou owns `flake.nix`, `flake.lock`, and `nix/*.nix`; project wiring lives in
`flake.module.nix`. Stage new flake files before Nix evaluation. Do not regenerate
the shared lock or edit generated pins. `seihou diff` checks
managed-file drift. The optional process-compose ClickHouse service is a local
convenience on default ports; builds do not start it. Qualification tests will
own isolated server processes and ports.
