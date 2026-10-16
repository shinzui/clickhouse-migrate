# clickhouse-migrate

A Haskell migration toolkit for one directly pinned ClickHouse server. Libraries
own validated ordered components; applications compose a plan, supply administrative
coordination and mount reusable commands. SQL is embedded at compilation or supplied
as validated bytes. Runtime migration-file discovery and automatic uncertain replay
are deliberately absent.

The four independently packaged libraries are core `clickhouse-migrate`, optional
`clickhouse-migrate-embed`, optional `clickhouse-migrate-cli`, and isolated
`clickhouse-migrate-test-support`. The core library excludes the optional packages
and test harnesses. A [two-library executable example](examples/two-components/README.md)
demonstrates composition and application-owned configuration/output/exit policy.

The [user documentation](docs/user/README.md) collects guides and interface references.
Implementation audits live in the [review catalog](docs/reviews/index.md).
[MasterPlan 2](docs/masterplans/2-resolve-initial-library-correctness-architecture-and-api-review-findings.md)
tracks remediation of the three initial correctness, architecture and API findings.

Start with [authoring and composition](docs/user/authoring.md), [CLI integration](docs/user/cli.md),
[operations and recovery](docs/user/operations.md), and [legacy adoption](docs/user/adoption.md).
Versioned contracts cover [checksums](docs/user/contracts/checksum-v1.md),
[SQL envelopes](docs/user/contracts/sql-envelope-v1.md), [manifests](docs/user/contracts/manifest-v1.md),
[ledger](docs/user/contracts/ledger-v1.md), [adoption](docs/user/contracts/adoption-v1.md),
[JSON results](docs/user/contracts/json-v1.md) and [error codes](docs/user/error-codes.md).

Use the pinned native GHC 9.12.4 environment:

```bash
nix develop --builders ''
just build
just check-packages
just test-unit
just check-public-invariants
just check-docs
just test-embedding
just test-release-matrix
just check-production-closure
just haddock
just qualify-distributions
just check-format
nix flake check --builders ''
```

Documentation checks require `okf` 0.9.0.0 or later and `dhall`; see the
[documentation workflow](docs/user/README.md). CI provisions these tools explicitly.

Only the exact Apple Silicon macOS ClickHouse artifact in the
[compatibility matrix](docs/user/compatibility.md) is qualified. Linux builders and remote
CI execution are deferred. Test recipes own new server processes, credentials,
temporary roots and ports; they never use a persistent application database. The
optional process-compose service is a developer convenience, not qualification.
`just build` and embedding tests use the content-qualified wrapper to catch inputs
whose modification times were preserved.

The manual core `internal-test-driver` flag defaults off. The optional Nix
`integration-tests`, `internal-test-driver` and `example` outputs compile qualification
artifacts; default checks never start a server. Production boundary checks inspect
Cabal component and Nix metadata only. The HTTP stack transitively includes the
standard Haskell process library; no process/server fixture tool is installed in
the core output. See ADR 0009 for that distinction.

Seihou owns `flake.nix`, `flake.lock` and `nix/*.nix`; project extensions live in
`flake.module.nix`. Stage new files before evaluating a flake and use `seihou diff`
to check managed-file drift. Do not regenerate shared pins.

[Release evidence](docs/release-evidence.md) maps the initial specification to tests
and exclusions. [MasterPlan 1](docs/masterplans/1-bootstrap-the-initial-clickhouse-migration-library.md)
tracks local implementation and a separate external consumer cutover gate. Building
artifacts does not publish the project or complete that external gate.
