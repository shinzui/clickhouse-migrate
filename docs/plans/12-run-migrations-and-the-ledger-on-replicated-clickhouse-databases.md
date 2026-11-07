---
id: 12
slug: run-migrations-and-the-ledger-on-replicated-clickhouse-databases
title: "Run migrations and the ledger on replicated ClickHouse databases"
kind: exec-plan
created_at: 2026-11-07T04:59:35Z
intention: "intention_01m6t5w8fkegt8wavd4rx196ap"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T04:59:35Z
---

# Run migrations and the ledger on replicated ClickHouse databases

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today clickhouse-migrate can only migrate one directly addressed, single ClickHouse server
whose databases use the ordinary `Atomic` engine. The first production consumer,
`mori://shinzui/kansoku`, must run on the TAN production ClickHouse cluster `tan-production`
on Altinity.Cloud. That cluster has two replicas of one shard coordinated by ClickHouse
Keeper, sits behind one TLS endpoint that may route consecutive connections to different
replicas, and holds every application database as a `Replicated` database. Each
application login there carries a settings profile that fixes
`database_replicated_allow_only_replicated_engine = 1` as a constant, so inside those
databases ClickHouse refuses any table that does not use a replicated engine:

```text
Code: 56 ... Only tables with a Replicated engine or tables which do not store data on disk are allowed in a Replicated database.
```

The current library rejects exactly the SQL and topology production needs. Its SQL envelope
refuses every token beginning with `REPLICATED`. Its ledger insists on an `Atomic` ledger
database holding a plain `MergeTree` table. Its admission check accepts one expected server
UUID and an exact allowlist of server versions that no longer contains the version the TAN
clusters now run.

After this plan, an operator can point clickhouse-migrate at a replicated cluster (two
replicas in production, one replica on staging) and run `up`, `status`, `history` and
`verify` against migrations that create `ReplicatedMergeTree`-family tables inside
pre-existing `Replicated` databases. The ledger lives in a `Replicated` database as a
`ReplicatedMergeTree` table, every acknowledged write is on every expected replica, and
every read returns what was acknowledged no matter which replica answers. Direct
single-server targets keep their current behaviour, checksums and ledger bytes. To see it
working, run the new replicated qualification group (`just test-replicated`) against an
owned two-replica fixture. It applies a replicated two-component example, stops one replica
to show fail-closed behaviour, and shows that a plain `MergeTree` migration fails loudly
with Code 56 instead of half-working.

Milestone 1 stands alone and is urgent. On 2026-11-07 the TAN staging server reported
`26.3.60.10002.altinitystable` (production runs the same build), but the library admits
only `26.3.60.10001.altinitystable`. Until that patch is qualified, any Kansoku staging
rollout fails admission inside its ClickHouse migration Job after the Job has fenced
Kansoku traffic.


## Progress

- [ ] Milestone 1: `26.3.60.10002.altinitystable` is in the matrix and the runtime
  allowlist, all thirteen native groups pass for both artifact variants, and the dated
  release evidence and compatibility guide record it.
- [ ] Milestone 2 (prototype): an owned two-replica Keeper fixture exists, and the spike
  report records the observed engine metadata, DDL and insert completion, sequential reads,
  replica-set observation and Code 56 behaviour that fix the replicated completion policy.
- [ ] Milestone 3: a replicated target can be configured and admitted. Each connection is
  admitted only to an expected replica, the cluster membership is checked, and every request
  carries the replicated completion settings. Direct targets are unchanged.
- [ ] Milestone 4: replicated targets bind checksums under a separate `sha256-v2` replicated
  completion policy, while every `sha256-v1` vector and direct-target ledger stays
  byte-for-byte unchanged.
- [ ] Milestone 5: the SQL envelope accepts argument-free `Replicated*MergeTree` engines and
  still rejects `ON CLUSTER`, Keeper paths and other replicated or distributed forms. Plans
  with `CREATE DATABASE` are refused before submission on replicated targets.
- [ ] Milestone 6: the ledger initializes, appends and reads in a pre-existing `Replicated`
  database on the fixture, and survives a replica restart.
- [ ] Milestone 7: `just test-replicated` passes end to end on the two-replica fixture. The
  compatibility guide, contracts and an ADR describe the supported replicated topology, and
  a release candidate version is cut for the Kansoku handoff.


## Surprises & Discoveries

- Observation: TAN staging was upgraded underneath the qualified allowlist. Evidence from
  2026-11-02 in `mori://tan/tan-app-infrastructure` (`docs/qualification/kansoku-image.json`)
  records `26.3.60.10001.altinitystable`. A read-only probe on 2026-11-07 returned:

  ```text
  26.3.60.10002.altinitystable	chi-tan-staging-tan-staging-0-0-0	fc42b2c4-fa62-414b-a2f1-5f25f4143ea7
  ```

  The server UUID still matches the retained Kansoku input, so only the version blocks
  admission. The Kansoku Job script runs `maintenance begin` (which fences traffic) before
  `up`, so a refused admission leaves the fence in place until someone recovers it by hand.
  This is why Milestone 1 comes first and can ship by itself.

- Observation: the checksum format binds the completion policy bytes
  `clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1`
  (`clickhouse-migrate/src/ClickHouseMigrate/Internal/Checksum.hs`). The ledger's
  initialized event also records `checksumFormat` and `policy`, and the codec rejects any
  other value (`clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerCodec.hs`, around
  lines 83 and 207). Waiting for every replica therefore cannot be added silently to v1.
  This shaped Milestone 4.


## Decision Log

- Decision: Qualify `26.3.60.10002.altinitystable` as a separate first milestone, keep
  `26.3.60.10001.altinitystable` admitted, and release that milestone by itself.
  Rationale: it unblocks the Kansoku staging rollout today without waiting for replicated
  support, and production runs the same build.
  Date: 2026-11-07

- Decision: Model a replicated target as a cluster name plus an exact, non-empty set of
  expected replica server UUIDs, not as one server. Admit each new connection only if its
  `serverUUID()` is in that set. Make every acknowledged write wait for all expected
  replicas, and make every read sequentially consistent, so correctness never depends on
  which replica the endpoint routes to.
  Rationale: the production endpoint may send consecutive connections to different
  replicas, and ADR 0005 already admits each new socket individually. A set-valued identity
  keeps that per-connection check, works whether or not Altinity.Cloud exposes per-replica
  host names, and gives the right quorum on staging (one replica) and production (two)
  without special cases.
  Date: 2026-11-07

- Decision: clickhouse-migrate never rewrites migration SQL. Consumers author
  replicated-engine SQL explicitly (for Kansoku, a separate replicated baseline), and the
  executed bytes stay the checksummed bytes.
  Rationale: ADR 0003 binds checksums to the exact SQL bytes. A rewrite at apply time would
  make the ledger attest SQL that never ran, and would turn the lexical envelope into a
  semantic transformer. The replicated databases on staging (recreated) and production
  (new) start with fresh ledgers, so no history has to carry across.
  Date: 2026-11-07

- Decision: Replicated targets use a new completion policy and a new checksum format,
  `sha256-v2`. It uses the v1 framing, with the version field `v2` and the replicated policy
  bytes. `sha256-v1` stays the only format for direct targets.
  Rationale: `docs/user/contracts/checksum-v1.md` says that changing the policy bytes
  requires a new checksum version. Waiting for every replica (`alter_sync=2`,
  `mutations_sync=2`, an insert quorum equal to the replica count) changes what "completed"
  means for a step. Keeping v1 untouched preserves Kansoku's 565-row staging history and
  every published vector.
  Date: 2026-11-07

- Decision: Keep rejecting `ON CLUSTER`, the `Replicated` database engine, `Distributed`,
  `remote` and explicit Keeper path or replica arguments. Refuse `CREATE DATABASE` steps on
  replicated targets before any submission.
  Rationale: inside a `Replicated` database, ClickHouse replicates table DDL through its own
  Keeper log, so `ON CLUSTER` is neither needed nor wanted. The server fills the default path
  `/clickhouse/{cluster}/tables/{shard}/{uuid}` and replica `{replica}`, and refuses
  different explicit paths. Databases are created by `mori://tan/tan-app-infrastructure` as
  `Replicated ON CLUSTER`; a database created by a migration would be `Atomic` and would hold
  data on only one replica.
  Date: 2026-11-07


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

clickhouse-migrate is a Haskell toolkit (GHC 9.12, Cabal and Nix) that applies ordered,
checksummed ClickHouse migrations and records each step in an append-only ledger. Its
packages are `clickhouse-migrate` (the core library), `clickhouse-migrate-embed`
(compile-time manifests), `clickhouse-migrate-cli` (a reusable command parser and handler
that applications mount), and `clickhouse-migrate-test-support` (owned server fixtures and
the native integration suites). The CLI's `up` applies pending migrations, `status` and
`history` read the ledger, and `verify` compares the ledger with the compiled plan. Repair
commands handle interrupted steps. Run `just` from the repository root to list recipes. The
development shell is `nix develop`.

Some terms used throughout this plan:

- A **Replicated database** is a ClickHouse database created with `ENGINE = Replicated(...)`
  on every node of a cluster. Its table DDL is written to a shared log in ClickHouse
  Keeper, a ZooKeeper-compatible coordination service, and replayed on every replica. A
  Replicated database does not replicate data by itself. Only tables using a
  `Replicated*MergeTree` engine (`ReplicatedMergeTree`, `ReplicatedReplacingMergeTree`,
  `ReplicatedAggregatingMergeTree` and so on) copy their data between replicas.
- A **replica** is one ClickHouse server in a shard. It has its own persisted
  `serverUUID()`, read from the `uuid` file in its data root.
- An **insert quorum** (`insert_quorum = N`) makes an INSERT succeed only after N replicas
  have the data. **Sequential consistency** (`select_sequential_consistency = 1`) makes a
  read on any replica return only data committed with a quorum, failing if the replica is
  behind.
- `alter_sync` and `mutations_sync` control how many replicas an ALTER or mutation waits
  for: `1` waits for the local replica and `2` waits for all of them.
- The **completion policy** is the fixed set of request settings the transport forces on
  every POST. Its exact bytes are part of every checksum.

The parts of the code this plan changes are listed below. Paths are relative to the
repository root.

The **admission and transport** layer is in `clickhouse-migrate/src/ClickHouseMigrate/Internal/ServerPolicy.hs`
and `clickhouse-migrate/src/ClickHouseMigrate/Internal/Http.hs`. `supportedVersions` holds
the exact allowlist `["26.8.28.14", "26.3.60.10001.altinitystable"]`. `identityQuery` reads
`serverUUID()`, `version()`, `hostName()` and the effective `async_insert`, `mutations_sync`
and `alter_sync`. `validateOutcome` rejects a UUID other than the single configured
`ServerId`, an unlisted version, or a completion policy other than 0/1/1.
`withTransportChecked` runs that probe on every newly opened socket before it enters the
pool. `makeRequest` in `Http.hs` adds `async_insert=0`, `mutations_sync=1`, `alter_sync=1`,
`fsync_metadata=1`, `wait_end_of_query=1` and JSON output to every POST, plus throwing
overflow modes for reads.

**Target configuration** is in `clickhouse-migrate/src/ClickHouseMigrate/Target.hs`, with the
private record in `clickhouse-migrate/src/ClickHouseMigrate/Internal/TargetTypes.hs`.
`targetConfig :: TargetKey -> DirectEndpoint -> ServerId -> LedgerNamespace -> LedgerBinding -> Credentials -> HttpLimits -> TargetConfig`
is the only public constructor.

The **SQL envelope** is in `clickhouse-migrate/src/ClickHouseMigrate/Internal/SqlEnvelope.hs`.
It is a lexical, comment- and literal-aware token check run when a step is defined.
`checkEnvelope` rejects protected settings, any `ON CLUSTER` pair, and, through `forbidden`,
any word or quoted identifier starting with `REPLICATED`, plus `DISTRIBUTED`, `REMOTE` and
others listed in `forbiddenWords`. `accepted` then allows only certain command families
(CREATE TABLE/VIEW/MATERIALIZED VIEW/DATABASE, ALTER TABLE actions, DROP, TRUNCATE,
EXCHANGE, RENAME, INSERT ... SELECT/VALUES). The contract is
`docs/user/contracts/sql-envelope-v1.md`.

**Checksums** are in `clickhouse-migrate/src/ClickHouseMigrate/Internal/Checksum.hs`
(`completionPolicyV1`), surfaced through `clickhouse-migrate/src/ClickHouseMigrate/Plan.hs`
(`ChecksumV1`, `checksumFormatName`, `completionPolicy`). The contract and independent
vectors are in `docs/user/contracts/checksum-v1.md`.

The **ledger** is in `clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerSchema.hs`
(DDL and expected metadata text) and `clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerStore.hs`
(shape validation, initialization, append, reconcile). `createDatabase` emits
`CREATE DATABASE IF NOT EXISTS <ns> ENGINE=Atomic`. `createTable` emits a plain
`MergeTree ORDER BY sequence` table with `fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'`.
`shape` requires database engine `Atomic` and the exact `expectedEngine` and
`expectedCreate` strings, and also checks `fsync_metadata` and that the `default` storage
policy is backed only by healthy writable Local disks (`checkLocalStorage`). The event codec
in `clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerCodec.hs` writes and requires
`checksumFormat = "sha256-v1"` and the v1 policy in the initialized event. The contract is
`docs/user/contracts/ledger-v1.md`.

**Repair** in `clickhouse-migrate/src/ClickHouseMigrate/Repair.hs` (around line 194) checks
for active queries with `system.processes`, which only shows queries on the replica that
answers.

**Test support** lives in `clickhouse-migrate-test-support`. The candidate matrix
`clickhouse-migrate-test-support/test/data/clickhouse-matrix.json` (also linked as
`test/compatibility/clickhouse-matrix.json`) lists each exact server artifact. The Altinity
entry pins the Linux arm64 manifest digest of `docker.io/altinity/clickhouse-server`.
`clickhouse-migrate-test-support/test/scripts/native_fixture.py` starts one owned server,
either a native binary or a container through an explicitly selected Docker context
(`CLICKHOUSE_MIGRATE_DOCKER_CONTEXT`). It writes `config.xml` and a deliberately weak
`users.xml` so the transport must override settings. The Haskell side drives it through
`clickhouse-migrate-test-support/src/ClickHouseMigrate/TestSupport/Server.hs`
(`withCandidateServer`, `queryServer`, `restartCandidateServer`) and
`.../TestSupport/Internal/Fixture.hs`. Suites are selected with
`--test-options=<group>` in `justfile` recipes such as `test-transport`, `test-ledger`,
`test-runner` and `test-adoption`. `just test-release-matrix` runs all thirteen groups for
every candidate and artifact variant (`scripts/test-release-matrix.py`).

The relevant ADRs are summarized here so this plan stands alone:

- [ADR 0003](../adr/0003-bind-checksums-through-invariant-safe-definitions.md) binds step
  and migration checksums to exact SQL bytes, context identity and the completion policy.
  The envelope is lexical and never proves SQL semantics.
- [ADR 0005](../adr/0005-admit-direct-connections-and-preserve-request-outcomes.md) admits
  every new socket by probing identity, exact version and effective settings on that
  socket. It distinguishes four request outcomes, never retries SQL, and treats direct
  endpoints and persisted UUIDs as operational constraints. It explicitly makes no claim of
  distributed affinity.
- [ADR 0006](../adr/0006-freeze-immutable-ledger-and-explicit-coordination.md) freezes the
  immutable ledger and requires explicit external coordination and drain before successor
  mutations.
- [ADR 0012](../adr/0012-prepare-recovery-metadata-before-authorization.md) covers recovery
  metadata, which the repair active-query check feeds.
- [ADR 0014](../adr/0014-qualify-exact-altinity-engine-with-owned-linux-fixtures.md) admits
  an exact Altinity patch only with an owned Linux arm64 OCI fixture and all thirteen
  groups. It keeps cloud endpoints, load balancers and replicated or distributed effects
  excluded "until separately qualified". This plan is that separate qualification.

This repository's ADRs are plain files under `docs/adr/` numbered `NNNN-slug.md`, with
`Status:` and `Date:` lines. Follow that convention.

Outside this repository, the handoff that motivated the plan was written by the TAN
infrastructure owner on 2026-11-07 while bringing production ClickHouse into
`mori://tan/tan-infrastructure/plans/6-bring-the-production-clickhouse-cluster-on-altinity-cloud-into-the-repository`.
Production is `ClickHouseClusters.production` in `mori://tan/tan-app-infrastructure`
(`pulumi/lib/foundation.ts`): host `tan-production.topagentnetwork-5os8y.altinity.cloud`,
native TLS 9440, HTTPS 8443, cluster name `tan-production`. Staging (`tan-staging`) is one
replica on the same build. The Kansoku-side work is out of scope here and is listed under
Interfaces and Dependencies. It covers a replicated migration baseline that converts its 44
`AggregatingMergeTree`, 18 `ReplacingMergeTree` and 1 `MergeTree` tables, and removing
`CREATE DATABASE` from its migrations 0001–0003.


## Plan of Work

The work runs in seven milestones. Milestone 1 is independent and ships first. Milestone 2
is a bounded prototype whose evidence fixes the exact settings and metadata strings that
Milestones 3–6 encode. Milestones 3–6 are additive behind the new replicated target kind,
so the direct-target suites keep passing throughout. Milestone 7 proves the whole path and
writes the durable documentation.


### Milestone 1: qualify Altinity 26.3.60.10002.altinitystable

Repeat the ADR 0014 procedure for the new patch. Resolve the Linux arm64 manifest digest
behind the `26.3.60.10002.altinitystable` tag. On 2026-11-07 Docker Hub listed the
multi-arch index `sha256:53e81c410a22ab052a4d967adc2886b547c91e67370e2d02f5c2ea1177d4d3aa`.
The matrix stores the arm64 manifest digest, not the index digest, so resolve that with
`docker buildx imagetools inspect` and record both. Also resolve the release tag object and
source commit from `https://github.com/Altinity/ClickHouse`. Add a matrix entry next to the
10001 entry with the same fields, and add `"26.3.60.10002.altinitystable"` to
`supportedVersions` in `ServerPolicy.hs`, keeping both coordinated as the comment requires.
Pre-pull the digest into the isolated Docker context and run `just test-release-matrix`.
Record a dated evidence file `docs/release-evidence/<date>-altinity-10002.md` modelled on
`docs/release-evidence/2026-11-02-altinity.md`. Update `docs/user/compatibility.md` and add
a short paragraph to ADR 0014 naming the additional patch. Bump the patch version of all
four packages (for example `0.1.0.1` to `0.1.0.2`) and their mutual bounds.

At the end, the release matrix passes for every candidate. A probe against an owned 10002
container is admitted, and an unlisted patch is still rejected with `UnsupportedServer`.
The Kansoku pin bump is done in `mori://shinzui/kansoku`; it is noted under Interfaces and
Dependencies.


### Milestone 2 (prototype): two-replica Keeper fixture and replicated spike

This milestone is labelled a prototype. Its fixture code is kept and promoted. Its spike
script and findings are kept as evidence, and its findings decide the exact bytes used
later.

Extend `clickhouse-migrate-test-support/test/scripts/native_fixture.py` with a replicated
variant that runs only in container mode. It creates a private Docker network and two
containers from the same pinned image. The first container also runs the embedded
ClickHouse Keeper; a third Keeper-only container is acceptable if simpler. Each server's
`config.xml` gains a `<zookeeper>` section, a `<remote_servers>` cluster named `fixture`
with one shard and both replicas, and `<macros>` for `cluster`, `shard` and `replica`. Both
servers get their own data root and persisted UUID. Add a `users.xml` login `app` whose
profile sets `database_replicated_allow_only_replicated_engine` to 1 as a constant, as in
production, and keep the deliberately weak defaults. Create `fixture_app` and
`fixture_ledger` as `ENGINE = Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')`
`ON CLUSTER fixture` with the administrative login, as the infrastructure does. Expose
`withReplicatedCandidate`, a per-replica `queryReplica`, `stopReplica` and `startReplica`
from `ClickHouseMigrate.TestSupport.Server`, along with a load-balanced endpoint. That
endpoint can be a tiny round-robin TCP forwarder in the fixture script that alternates
replicas per connection, which is what the production endpoint may do.

Write `scripts/replicated-spike.py`, which uses the fixture and records JSON answers to
these questions:

1. The exact `system.databases.engine`, and the `system.tables` `engine`, `engine_full`,
   `sorting_key` and `create_table_query` of a ledger-shaped table created as
   `ENGINE=ReplicatedMergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'`.
   This is needed on both replicas, because the expanded default Keeper path text and
   whether the macros appear expanded fix `expectedEngine`.
2. Whether DDL inside a Replicated database run with the fixture's defaults returns before
   the other replica applies it. Also which of `distributed_ddl_task_timeout`,
   `distributed_ddl_output_mode`, `database_replicated_enforce_synchronous_settings` or
   `alter_sync=2` makes the initiator wait for every replica, and what a lagging or stopped
   replica produces (error code, and whether the DDL still applied).
3. Whether `insert_quorum=2, insert_quorum_parallel=0` fails when one replica is stopped,
   and whether a failed quorum insert can still become visible later. That second case must
   be treated as uncertain, never as non-submission.
4. Whether `select_sequential_consistency=1` on the lagging replica fails rather than
   returning stale rows.
5. Whether the `app` login can read `serverUUID()` from every replica with
   `clusterAllReplicas('fixture', system.one)` or another read-only query, and what
   `system.clusters` shows. This decides how membership is observed in Milestone 3.
6. That a plain `MergeTree` table in `fixture_app` fails with Code 56 for `app`, that a
   Replicated engine with an explicit differing Keeper path is refused, and that the
   argument-free `ReplicatedReplacingMergeTree(ver)` form is accepted.
7. What `clusterAllReplicas('fixture', system.processes)` shows for a long-running query
   started through the other replica.

Record the output as `docs/release-evidence/<date>-replicated-spike.json` with a short
companion Markdown note. Then write the chosen replicated policy into the Decision Log.
The working assumption is `async_insert=0`, `mutations_sync=2`, `alter_sync=2`,
`insert_quorum=<replica count>`, `insert_quorum_parallel=0`,
`select_sequential_consistency=1` on reads, `fsync_metadata=1`, `wait_end_of_query=1`, plus
the DDL-wait setting chosen from question 2.

Separately, ask the TAN infrastructure owner whether Altinity.Cloud exposes per-replica
host names for `tan-production`, and record the answer. The design does not depend on it,
but operators may prefer to address one replica directly.

Promote the prototype if every question has a recorded, repeatable answer. Discard and
revisit the Decision Log if question 2 or 3 shows that no setting makes acknowledged DDL or
inserts wait for every replica. In that case the replicated target cannot honour ADR 0005's
acknowledgement meaning and the topology must be reconsidered before continuing.


### Milestone 3: replicated target configuration and admission

Add a target topology to the private `TargetConfig` in `Internal/TargetTypes.hs`:
`DirectServer ServerId` for today's behaviour and
`ReplicatedCluster ClusterName (NonEmpty ServerId)`. Keep `targetConfig` unchanged; it
builds `DirectServer`. Add `clusterName :: Text -> Either TargetError ClusterName` (same
character rules as `ledgerNamespace`, plus `-`, because the production name is
`tan-production`) and a new public constructor in `ClickHouseMigrate.Target`:

```haskell
replicatedTargetConfig
  :: TargetKey -> DirectEndpoint -> ClusterName -> NonEmpty ServerId
  -> LedgerNamespace -> LedgerBinding -> Credentials -> HttpLimits -> TargetConfig
```

It rejects duplicate UUIDs with a new `TargetError` constructor `DuplicateReplica`. Add a
read-only accessor `configuredTopology`.

In `ServerPolicy.hs`, make `validateOutcome` accept a socket whose `serverUUID()` is a
member of the expected set. For replicated targets, extend the probe to also return the
`cluster` macro (`getMacro('cluster')`) and the effective values of each replicated policy
setting, and require them to match. At the start of every `withTransportChecked` scope,
issue one membership read (the query chosen from spike question 5). Require the set of
replica UUIDs it reports to equal the configured set exactly, and fail with a new
`TransportErrorCode` `ReplicaSetMismatch` otherwise. In `Http.hs`, have `makeRequest` take
the topology: direct targets keep today's exact query string, and replicated targets send
the replicated policy with `insert_quorum` equal to the set size and
`select_sequential_consistency=1` on non-command reads. The `ServerIdentity` returned to
callers keeps the admitted replica's UUID and host, so reports show which replica answered.

Make the repair active-query check in `Repair.hs` cover every replica on replicated targets
(the query chosen from spike question 7). Its result stays a diagnostic only, as today.

At the end, unit tests cover the constructors and the admission validator, and a new
`replicated` integration group on the fixture shows that admission succeeds through the
round-robin endpoint, and is rejected when one configured UUID is wrong, when a replica is
missing from the configured set, and when the login's profile lowers `alter_sync`.
`just test-transport` and `just test-completion-policy` still pass unchanged against
direct targets.


### Milestone 4: replicated completion policy and `sha256-v2`

Introduce a private `CompletionPolicy` type with `LocalSyncV1` and `ReplicatedSyncV1`.
`completionPolicyV1` keeps its exact bytes. Add `completionPolicyReplicatedV1` with the
bytes fixed by Milestone 2, starting with `clickhouse-migrate/replicated-sync-v1;`. The
quorum count is not part of the bytes: it is a property of the target, not of the step's
meaning. The policy says "all configured replicas". Parameterize the checksum functions in
`Internal/Checksum.hs` by policy and version tag. Extend `ChecksumFormat` in `Plan.hs` with
`ChecksumV2` and the name `sha256-v2`. The bound plan keeps its validated definitions, so
the runner computes checksums for the target's policy. Existing public accessors keep
returning the v1 values, and new accessors take a `ChecksumFormat`.

Update `LedgerCodec.hs` so the initialized event writes `sha256-v2` and the replicated
policy for replicated targets. Decoding must accept exactly the pair that matches the
configured topology: a direct target must reject a v2 ledger, and the reverse as well.
Write `docs/user/contracts/checksum-v2.md` with complete independent vectors computed the
same way as the v1 vectors, and leave `checksum-v1.md` unchanged apart from a link to v2.

At the end, every existing checksum and ledger vector test passes unchanged. New vector
tests pass for v2, and a test shows that one migration has different v1 and v2 checksums.


### Milestone 5: replicated engines in the SQL envelope

In `SqlEnvelope.hs`, stop treating every `REPLICATED`-prefixed word as forbidden. Permit
exactly these words: `REPLICATEDMERGETREE`, `REPLICATEDREPLACINGMERGETREE`,
`REPLICATEDAGGREGATINGMERGETREE`, `REPLICATEDSUMMINGMERGETREE`,
`REPLICATEDCOLLAPSINGMERGETREE` and `REPLICATEDVERSIONEDCOLLAPSINGMERGETREE`. Each is
permitted only as the engine name directly after `ENGINE` or `ENGINE =`, in a `CREATE TABLE`
or `CREATE MATERIALIZED VIEW` statement. When the engine name is followed by `(`, the first
argument must not be a string literal, so explicit Keeper paths and replica names are
rejected. Every other `REPLICATED`-prefixed word or quoted identifier stays forbidden. That
includes the `Replicated` database engine, `SYSTEM ... REPLICA` forms and quoted spellings.
`ON CLUSTER`, `DISTRIBUTED` and `REMOTE` stay forbidden.

This is a lexical check like the rest of the envelope. Document it in a new
`docs/user/contracts/sql-envelope-v2.md`: a strict superset of v1, with v1 kept and
marked superseded. Definitions already valid under v1 stay valid, so no checksum moves.

In `clickhouse-migrate/src/ClickHouseMigrate/Internal/Preflight.hs`, refuse a plan on a
replicated target when any pending step is `CREATE DATABASE`, before any submission. Use
`mentionsIdentifier`-style token reuse rather than a new parser, and add a new
`DefinitionErrorCode` or preflight error such as `DatabaseCreationOnReplicatedTarget`.
Applied history is not re-checked.

At the end, unit tests in `clickhouse-migrate/test/Main.hs` accept the argument-free forms
(including `ReplicatedReplacingMergeTree(updated_at)` with a non-literal argument and
`ENGINE=ReplicatedMergeTree` without spaces) and reject explicit paths, `ENGINE = Replicated`,
quoted `"ReplicatedMergeTree"` outside an engine position, `ON CLUSTER` and `Distributed`.
The embedded example manifests still build.


### Milestone 6: replicated ledger

In `LedgerSchema.hs`, add replicated variants. A replicated target never creates the
ledger database: if it is missing, `shape` reports a new `LedgerError`
`LedgerDatabaseMissing`, and if its engine is not `Replicated`, it reports
`InvalidLedgerSchema`. The table DDL is
`CREATE TABLE IF NOT EXISTS <ns>.events (...) ENGINE=ReplicatedMergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'`,
with no Keeper arguments, and `expectedEngine` and `expectedCreate` come from the strings
captured by spike question 1. Thread the topology through `shape`, `initialize`,
`appendOnce`, `load` and `reconcile` in `LedgerStore.hs`. Appends use the replicated
request settings, so an acknowledged append is on every configured replica. Reads are
sequentially consistent. Note that `ReplicatedMergeTree` deduplicates identical inserted
blocks by default; because no outcome is ever replayed, this does not change acknowledgement
semantics, and the plan records that it is not relied on. Run `checkLocalStorage` and the
`fsync_metadata` check through every replica if spike question 5 found a read-only
all-replicas query. Otherwise run them on each newly admitted replica, which still covers
every replica that is ever written through. Document whichever applies in
`docs/user/contracts/ledger-v1.md`, in a new "Replicated ledgers" section; the v1 event
encoding itself is unchanged.

At the end, `just test-ledger` passes unchanged for direct targets. The new replicated group
shows initialization in a pre-existing `Replicated` database, appends visible on both
replicas, a rejected `Atomic` or missing ledger database, rejected wrong engine text, and
acknowledged history intact after SIGKILL and restart of each replica in turn. It also
shows that an append while one replica is stopped fails without any acknowledgement and is
reported as uncertain or failed exactly as ADR 0005's outcomes require.


### Milestone 7: end-to-end qualification, documentation and release

Add a replicated variant of `examples/two-components`, with migrations using
`ReplicatedMergeTree` and `ReplicatedReplacingMergeTree(ver)` against `fixture_app`. Add
`just test-replicated`, which runs the `replicated` integration group and then drives the
mounted CLI through the round-robin endpoint: `up`, `status --json`, `history --json`,
`verify`. Re-running `up` must be a no-op. Stopping one replica must make `up` of a new
migration fail closed, with the ledger showing at most an uncertain attempt that repair
handles as today. A plain-`MergeTree` migration must fail with the server's Code 56
reported as an observed server failure. Add the group to `scripts/test-release-matrix.py`
for the Altinity candidate.

Write ADR `docs/adr/0015-qualify-replicated-targets-by-replica-set-and-quorum.md` recording
the topology, policy, checksum version, envelope and ledger decisions. Update ADR 0005 and
ADR 0014 to point to it. Rewrite the topology paragraph of `docs/user/compatibility.md`:
the supported operation becomes one directly addressed server, or one replicated cluster
with an exact replica set, Keeper-backed `Replicated` databases and the replicated policy.
Arbitrary cloud proxies, multi-shard clusters, `Distributed` tables and SQL rewriting stay
excluded, and owned fixture evidence is not managed-cloud certification. Update
`docs/user/operations.md` and `docs/user/authoring.md` with how to configure a replicated
target and author replicated migrations. Bump the minor version of all four packages (for
example to `0.1.1.0`); the API change is additive.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/clickhouse-migrate`
inside `nix develop` unless stated otherwise. The integration fixtures need an isolated
local Docker context that has pre-pulled the matrix digests:

```bash
export CLICKHOUSE_MIGRATE_DOCKER_CONTEXT=<isolated-local-context>
nix develop --builders '' -c just test-integration
```

For Milestone 1, resolve the new digest and run the matrix:

```bash
docker --context "$CLICKHOUSE_MIGRATE_DOCKER_CONTEXT" buildx imagetools inspect \
  docker.io/altinity/clickhouse-server:26.3.60.10002.altinitystable
docker --context "$CLICKHOUSE_MIGRATE_DOCKER_CONTEXT" pull \
  docker.io/altinity/clickhouse-server@sha256:<arm64-manifest-digest>
nix develop --builders '' -c just test-release-matrix
```

Expect every candidate, including the new `altinity-linux-arm64-10002` entry, to report all
thirteen groups passing for both artifact variants, with no skipped candidate.

For Milestone 2, run the spike after adding the replicated fixture:

```bash
python3 scripts/replicated-spike.py --report docs/release-evidence/<date>-replicated-spike.json
```

Expect a JSON document with one object per numbered question, each holding the exact
statement, the replica it ran on and the observed result or error code. A Code 56 refusal
looks like this:

```text
{"question": 6, "case": "plain-mergetree", "replica": "r1", "error": {"code": 56}}
```

For Milestones 3–6, iterate with the unit suite and the new group:

```bash
just test-unit
cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=replicated
just test-transport && just test-ledger && just test-runner
```

For Milestone 7:

```bash
just test-replicated
just check
just test-release-matrix
```

Commit at each milestone boundary with Conventional Commit messages and both trailers:

```text
feat(compatibility): qualify Altinity 26.3.60.10002.altinitystable

ExecPlan: docs/plans/12-run-migrations-and-the-ledger-on-replicated-clickhouse-databases.md
Intention: intention_01m6t5w8fkegt8wavd4rx196ap
```


## Validation and Acceptance

Milestone 1 is accepted when `just test-release-matrix` passes all candidates and groups,
the owned 10002 container is admitted, and an unlisted version is still rejected.

The replicated work is accepted when `just test-replicated` passes on the two-replica
fixture and shows all of the following:

- Through an endpoint that alternates replicas per connection, `up` applies the replicated
  example. `status --json` reports every migration applied with `checksumFormat` `sha256-v2`,
  and `verify` succeeds.
- Querying each replica directly for `fixture_app` tables and for `fixture_ledger.events`
  returns identical rows.
- With one replica stopped, `up` of a new migration exits non-zero without acknowledging
  the step, and after the replica returns, the existing recovery path resolves it.
- A plain `MergeTree` migration fails with the server's Code 56, reported as an observed
  server failure.
- A configured replica set that does not match the cluster is rejected before any
  application or ledger bytes are sent.

Every existing group, including `test-transport`, `test-ledger`, `test-runner`,
`test-repair`, `test-adoption` and `test-consumer-fixtures`, must still pass unchanged, and
the v1 checksum and ledger vectors must be byte-identical.

The real-cluster check is required acceptance for production readiness, but it is run by
the consumer. After Kansoku adopts the release and `mori://tan/tan-app-infrastructure`
recreates Kansoku's staging databases as `Replicated`, Kansoku's migrations and ledger run
cleanly against `tan-staging`. Record that evidence here when it arrives. Staging has one
replica, so it proves the engines, envelope, ledger and policy against the managed service,
but not two-replica quorum; that is covered by the fixture.


## Idempotence and Recovery

Every fixture is owned and temporary. Failed runs keep their diagnostic root and remove only
containers labelled `clickhouse-migrate.fixture=owned`, as today. The replicated fixture
must also remove its private Docker network and Keeper container. Re-running any `just`
recipe is safe.

Milestone 1 only adds an allowlist entry and evidence; reverting the commit restores the
previous behaviour. Milestones 3–6 are additive behind the replicated topology. Direct
targets keep their exact request bytes, checksums and ledger shape, which the unchanged
suites prove at every step. If Milestone 2 shows no setting can make acknowledged DDL or
inserts wait for every replica, stop after Milestone 2, record the finding, and revisit the
topology decision rather than weakening acknowledgement.

No step in this plan touches a shared or managed ClickHouse server. Dropping and recreating
Kansoku's staging databases is destructive (it loses 5 `analytics` rows and 565 ledger
rows). It belongs to the infrastructure owner, following the procedure used for
`notification_hub` in `mori://tan/tan-app-infrastructure` pull request #173, and only after
Kansoku has released a replicated baseline.


## Interfaces and Dependencies

New or changed public interfaces in `clickhouse-migrate`:

- In `ClickHouseMigrate.Target`: `ClusterName`, `clusterName`, `replicatedTargetConfig`,
  `configuredTopology`, a `TargetTopology` view, and the `TargetError` constructor
  `DuplicateReplica`.
- In `ClickHouseMigrate.Plan`: `ChecksumV2` and the name `sha256-v2`, plus checksum
  accessors that take a format.
- New error codes `ReplicaSetMismatch` (transport), `LedgerDatabaseMissing` (ledger) and
  `DatabaseCreationOnReplicatedTarget` (preflight). Each must be documented in
  `docs/user/error-codes.md` and rendered by `clickhouse-migrate-cli/src/ClickHouseMigrate/CLI/Render/Json.hs`
  and `.../Render/Text.hs`.
- `clickhouse-migrate-cli` does not parse target configuration. The mounting application
  builds `TargetConfig` (Kansoku does so in its `Kansoku.ClickHouseMigration.Config`), so the
  CLI needs only the new error renderings and replicated fields in its status and history
  JSON (`checksumFormat`, admitted replica). Record any `json-v1.md` additions as additive
  fields.

The external pins stay the same: `http-client` 0.7.19 (ADR 0005) and the exact images in
`clickhouse-migrate-test-support/test/data/clickhouse-matrix.json`.

Downstream work owned elsewhere depends on the releases from this plan:

- `mori://shinzui/kansoku` bumps its `cabal.project` `source-repository-package` pin, now
  `00afa9fa1038f2b90e7bc5f041ac1b56649b639f`. It needs the Milestone 1 release to unblock its
  staging rollout and the Milestone 7 release for production. For production it must
  author a replicated migration baseline with `Replicated*MergeTree` engines, drop
  `CREATE DATABASE` from its replicated path, and configure the replicated target with the
  cluster name and replica UUIDs.
- `mori://tan/tan-app-infrastructure` must recreate Kansoku's staging databases as
  `Replicated` (removing `existingAtomicDatabases` in `pulumi/apps/kansoku/bootstrap.ts`),
  choose the ClickHouse cluster by environment, and add `stacks/kansoku/production.yaml`.
  Production stays blocked until the staging run in Validation and Acceptance passes.
