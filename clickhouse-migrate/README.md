# clickhouse-migrate

Validated ordered migration definitions, exact-byte checksum v1, conservative direct
HTTP execution, immutable ledger history, scoped inspection/recovery and source-neutral
legacy adoption. No runtime file discovery, implicit credentials, printing or process
exit. Optional embedding, CLI and server fixtures are separate packages.

Construct `MigrationPlan` with the public smart constructors; supply validated
`TargetConfig`, a mandatory externally serialized administrative provider, event sink
and diagnostic policy to `mutationContext`. `up` initializes only with a retained
explicit target/UUID authorization. Uncertain work blocks ordinary up. Status/history
never initialize; verify checks definition compatibility, optionally currency, not
schema equality. All repair/adoption operations require explicit evidence and fresh
expected state. Async cancellation propagates after bounded cleanup.

Qualified target: exact ClickHouse 26.8.28.14 LTS official Apple Silicon macOS binary,
direct self-managed Atomic/MergeTree on healthy writable Local storage. No Cloud,
proxy, distributed/replicated, Linux or power-loss claim. Runtime version probes do
not attest platform/digest. The workspace's docs/contracts and docs/operations.md
publish frozen formats, server artifact identity and coordination/recovery limits.
The standard Haskell process library is a transitive HTTP dependency; fixture tools,
optional packages and the opt-in internal driver are absent from production outputs.
