# clickhouse-migrate-test-support

Owned native ClickHouse fixtures and controlled HTTP faults for qualification. This
optional package is not in the production core closure. It requires Python 3 and the
exact digest-checked Apple Silicon macOS server artifact in packaged matrix data;
it allocates temporary roots, owned process groups and loopback ports. Successful
fixtures remove only owned data; failures preserve diagnostics. No shared server is used.

The host-local development coordinator uses an OS file lock and persistent dirty
marker. All administrators must share the host/canonical root/target key. Later entry
requires explicit external quiescence even after normal release; lock release or an
empty process/history read is insufficient. It is not distributed fencing.

The default-off integration flag compiles public API suites, embedded captured
consumer data, CLI handlers and executable stream/cancellation checks. Transport
qualification also needs the separate default-off core internal-test-driver artifact.
Tests never run a server during normal Nix builds. Directly invoking a Cabal-built
suite requires `clickhouse_migrate_test_support_datadir` set to this package directory;
`cabal test` supplies it automatically and installed Nix artifacts use their data path.
The workspace's release matrix script runs all twelve required groups serially.
