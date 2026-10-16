# Two independently owned components

`catalog` and `analytics` are separate libraries with their own embedded manifests.
Analytics depends on catalog; the application explicitly composes that order.
All three packages are private workspace demonstrations, not publication targets.
The executable demonstrates the reusable CLI, not a production coordinator.

From the repository root:

```bash
nix develop --builders '' -c just build
nix develop --builders '' -c cabal run clickhouse-migrate-example -- plan --json
nix develop --builders '' -c just test-example
```

Offline plan requires no server, environment or source files at runtime. Cabal may
print build messages; for machine output invoke the executable returned by
`cabal list-bin clickhouse-migrate-example` directly. Every remote command requires
application-selected `CHM_TARGET`, `CHM_ENDPOINT`, `CHM_SERVER_ID`,
`CHM_LEDGER_DATABASE` and `CHM_PASSWORD`. `CHM_USER` defaults to default. Set
`CHM_LEDGER_ID` to the retained native UUID for recurring operations; absent means
FirstUse binding, which grants no initialization authority. Credentials never enter
the endpoint URI. Environment loading belongs solely to this example executable.

Mutations and guarded reads also require `CHM_LOCK_ROOT`. This uses the test-support
**host-local development adapter**: every administrator must share this host, canonical
root and complete target key. It leaves a persistent quiescence marker after normal
release and process death. Later entry requires explicit external evidence; the
lock's release cannot prove server drain. For production, mount the parser/handler
in your own executable with an appropriate externally serialized provider.

After independently retaining a UUID and verifying the expected direct target:

```text
clickhouse-migrate-example --progress up --json --expect-target YOUR_TARGET \
  --actor YOUR_ACTOR --reason 'approved fresh initialization' \
  --initialize-ledger RETAINED_UUID
```

Persist CHM_LEDGER_ID. Before any subsequent mutating entry, independently exclude
all administrators and establish complete predecessor quiescence, then supply
`--quiescent --evidence REFERENCE` with actor/reason/target. Do not infer drain from
timeout, OS lock release or an empty process/ledger read. The second successful up
executes no application SQL. `status --json`, `history --json` and
`verify --require-current --json` use observations without initializing history.

For repair, take fresh guarded history and use the exact position, current attempt
and (for a selected step) its original owner attempt/name/query ID. See
[CLI inputs](../../docs/user/cli.md) and [recovery](../../docs/user/operations.md).
For legacy adoption, retain all source rows and a reviewed complete mapping in the
explicit input file, then `adopt plan`, `adopt apply` or `adopt resume` with the same
source identity and mapping. An interrupted batch needs fresh expected state.
Adoption executes no application SQL. It cannot prove actual effects from names.

The native `cli` group exercises all repair/adoption handlers, response loss, stale
state, delayed ledger receipts and cancellation. The `example` group starts this
executable as a subprocess against a new owned server, verifies fresh/no-op runs
and stream separation, then terminates a process with a controlled in-flight INSERT.
No shared developer database is touched. Recovery requires controlled external drain.
`--progress` writes safe events to stderr; `--sql-diagnostics` is explicit authored
SQL disclosure to stderr. Default JSON/text exclude SQL and credentials. Synchronous
failures return complete safe JSON; async cancellation/termination may return none.

The application owns an explicit schedule: catalog.0001, analytics.0001. If a
second catalog release adds 0002, keep those two entries and append catalog.0002
to the schedule. Keep its authored catalog migration list as 0001, 0002. Use
`migrationIdFromNames` and `scheduledMigrationPlanFromList` as in `app/app/Main.hs`;
embedding continues to export only each library's component. Do not regenerate
execution order by flattening components after upgrading a library.
