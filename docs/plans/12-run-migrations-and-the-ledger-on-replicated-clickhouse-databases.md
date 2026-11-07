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
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-07T05:24:52Z
      verdict: "changes-requested"
      note: "Verified claims against the tree: replicated DDL result sets, uncoordinated timeouts, exact engine_full match, bind-time checksums and clusterAllReplicas grant block the design as written"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-07T05:24:52Z
      mode: "update"
      note: "Fixed review findings in place, inserted Milestone 2 to centralize server policy and data-drive the matrix, renumbered to eight milestones"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-07T14:47:03Z
      mode: "implement"
      note: "Implement exact patch qualification, centralized server policy and replicated fixture acceptance"
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

This plan has two goals. The first is replicated support: after it, an operator can point
clickhouse-migrate at a replicated cluster (two replicas in production, one replica on
staging) and run `up`, `status`, `history` and `verify` against migrations that create
`ReplicatedMergeTree`-family tables inside pre-existing `Replicated` databases. The ledger
lives in a `Replicated` database as a `ReplicatedMergeTree` table, every acknowledged write
is on every expected replica, and every read returns what was acknowledged no matter which
replica answers. Direct single-server targets keep their current behaviour, checksums and
ledger bytes. To see it working, run the new replicated qualification group
(`just test-replicated`) against an owned two-replica fixture. It applies a replicated
two-component example, stops one replica to show fail-closed behaviour, and shows that a
plain `MergeTree` migration fails loudly with Code 56 instead of half-working.

The second goal is to make the next ClickHouse-side change cheap. ClickHouse changes under
this library in three recurring ways: Altinity publishes a new patch build and the managed
clusters pick it up, a new table or database engine becomes required, and a new topology
appears. Today each of those ripples through hand-maintained copies: the version allowlist
in `ServerPolicy.hs`, the candidate matrix, the CI image pull, the compatibility guide,
the changelogs and the evidence files all name the same version separately; the request
settings, the probe query, the checksum policy bytes and the ledger's expected metadata
strings are literals in four different modules. Milestone 2 gathers every server-dependent
byte into one module, converts the private target configuration to a record so adding a
field is one edit, makes the candidate matrix drive which test groups run, adds a drift
check to `just check`, and adds a script that resolves a new build's digest, tag and
commit into a ready-to-paste matrix entry. After it, qualifying the next Altinity patch is
a runbook of a few commands plus one matrix run, and adding a topology is one new
constructor rather than a hunt through the codebase.

Milestone 1 stands alone and is urgent. On 2026-11-07 the TAN staging server reported
`26.3.60.10002.altinitystable` (production runs the same build), but the library admits
only `26.3.60.10001.altinitystable`. Until that patch is qualified, any Kansoku staging
rollout fails admission inside its ClickHouse migration Job after the Job has fenced
Kansoku traffic.


## Progress

- [x] Milestone 1, 2026-11-07: exact Altinity 10002 is admitted alongside both
  earlier patches. All 39 candidate/group cases pass for Nix and seven extracted
  sibling source archives; metadata, three unit suites and Haddocks also pass.
  Shared patch version `0.1.0.2`, CI pulls and dated evidence record the result.
  An earlier native pre-readiness SIGSEGV is retained as a failed attempt.
- [x] Milestone 2, 2026-11-07: ServerProfile owns the policy/metadata bytes and
  TargetConfig has named fields. Matrix groups drive both runners. `just check`
  passes with policy/documentation drift checks; a deliberately removed version
  fails by name, and the resolver reproduces immutable 10002 identities/groups.
  Direct request/ledger byte pins and the full direct groups pass unchanged.
- [x] Milestone 3 (prototype), 2026-11-07: an owned Keeper/two-replica fixture
  recorded 64 observations across all eight spike questions in
  `docs/release-evidence/2026-11-07-replicated-spike.json`. Empty `none` success and
  full-quorum writes support promotion; restricted-login membership uses local counts.
  Managed production observations remain part of the consumer handoff.
- [x] Milestone 4, 2026-11-07: validated replicated targets admit expected UUIDs,
  qualified versions, cluster macros, effective policy and local storage. Single-shard
  membership counts fail closed; unit probes and both container groups verify it.
- [x] Milestone 5, 2026-11-07: both formats bind before target selection; all 48
  vectors pass and v1 files are byte-identical. Fresh status uses configured v2
  pending digests; initialized history records its format and refuses foreign v1.
  Offline JSON keeps v1 fields and adds both digest sets; CLI compatibility passes.
- [x] Milestone 6, 2026-11-07: six replicated engines pass the lexical envelope,
  explicit paths/quoted forms remain excluded, and pending replicated database
  creation/policy overrides fail before bootstrap. Direct v1 acceptance is preserved.
- [x] Milestone 7, 2026-11-07: replicated ledgers initialize in pre-existing databases,
  validate structural metadata/replica health, append with full quorum, read across
  replicas and survive both restarts. Missing/Atomic/malformed/foreign-format cases
  and stopped-replica uncertainty/recovery pass in both owned image fixtures.
- [x] Milestone 8, 2026-11-07: `just check` and all 41 final release-matrix cases pass.
  Installed Nix artifacts additionally pass both replicated groups. Seven shared
  `0.1.1.0` source archives are generated; documentation, contracts and ADR 0015
  record the result. The consumer's managed staging/production-readiness gate remains
  external and unverified; no publication or managed cutover is claimed.


## Surprises & Discoveries

- Observation (final qualification, 2026-11-07): pending status/run reports need
  the configured topology's checksum format even before an initialized event exists.
  Inferring format only from history incorrectly showed v1 pending digests for an
  empty replicated ledger. The format is now passed explicitly into report building;
  the public CLI fixture compares fresh status digests with offline v2 plan digests.

- Observation (final qualification, 2026-11-07): HTTP readiness after process restart
  can precede a Replicated database leaving read-only mode. A follow-up SYNC DATABASE
  returned Code 159 during that window. `startReplica` now waits for all owned database and table replica
  `is_readonly` values to clear, within a bounded deadline;
  it never retries server startup. The schema parser also checks that both engine
  arguments actually begin with single quotes, since the shared lexer classifies
  both single-quoted and heredoc strings as literals.

- Observation (corrected spike, 2026-11-07): the non-key UPDATE reports Code 341
  with a stopped replica and catches up after restart. The initial mutation case
  attempted to update the sorting key and returned Code 420, so it was corrected
  before accepting the report. A metadata ALTER took about twelve seconds despite
  a five-second inactive-replica setting; coordination overhead means a client
  deadline can still produce uncertainty even with bounded server settings.

- Observation (spike, 2026-11-07): `none` gives empty acknowledged DDL responses,
  waits for the stopped replica and reports HTTP 408 / Code 159 at about 5.3 seconds.
  Quorum INSERT reports Code 319 after a missing-replica wait, yet its row becomes
  visible on both replicas after restart. `app` lacks READ ON REMOTE (Code 497),
  while local `system.clusters`, `system.replicas` and storage reads work.
  The server preserves `{uuid}`, `{shard}` and `{replica}` macros in `engine_full`;
  `system.replicas` reports their expanded values. Evidence is in
  `docs/release-evidence/2026-11-07-replicated-spike.json`.

- Observation (spike, 2026-11-07): a deliberately lagging replica can return stale
  rows with sequential consistency after a quorum-one INSERT; quorum one does not
  establish the last quorum part. Therefore sequential consistency alone is not a
  freshness guarantee. The supported policy always waits for the full replica count;
  the fixture must prove that every acknowledged write is already visible on both.

- Observation (infrastructure inspection, 2026-11-07):
  `mori://tan/tan-app-infrastructure` (project-relative
  `docs/runbooks/kansoku-staging-contract.md`, artifact-level URI pending) records
  staging's default disk as healthy writable Local storage. Its
  `pulumi/lib/tan-clickhouse-tenant.ts` grants narrow local system reads and no
  REMOTE privilege. Per-replica endpoints, production storage and actual default
  replica macros are not recorded there; those managed observations remain open.

- Observation (implementation, 2026-11-07): upstream publishes this build under
  `v26.3.60.10002-1.altinitystable`, not the tag predicted by the plan.
  `git ls-remote --tags` resolves it to `4d1d8cad81573563e3abece05c39fb4903fce73f`.
  The Docker tag and reported server version retain `26.3.60.10002.altinitystable`.
  The arm64 manifest is `sha256:7e72405bf85df6d163205ee2e56251ebc35daf6dc71142f58bdee7a461690ffb`.

- Observation: TAN staging was upgraded underneath the qualified allowlist. Evidence from
  2026-11-02 in `mori://tan/tan-app-infrastructure` (`docs/qualification/kansoku-image.json`)
  records `26.3.60.10001.altinitystable`. A read-only probe on 2026-11-07 returned:

  ```text
  26.3.60.10002.altinitystable	chi-tan-staging-tan-staging-0-0-0	fc42b2c4-fa62-414b-a2f1-5f25f4143ea7
  ```

  The server UUID still matches the retained Kansoku input, so only the version blocks
  admission. The Kansoku Job script (`pulumi/apps/kansoku/migrate-clickhouse.sh` in
  `mori://tan/tan-app-infrastructure`) runs `maintenance begin` (which fences traffic) before
  `up`, so a refused admission leaves the fence in place until someone recovers it by hand.
  This is why Milestone 1 comes first and can ship by itself.

- Observation: the checksum format binds the completion policy bytes
  `clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1`
  (`clickhouse-migrate/src/ClickHouseMigrate/Internal/Checksum.hs`). The ledger's
  initialized event also records `checksumFormat` and `policy`, and the codec rejects any
  other value (`clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerCodec.hs`, around
  lines 83 and 207). Waiting for every replica therefore cannot be added silently to v1.
  This shaped Milestone 5.

- Observation (review, 2026-11-07): a DDL statement inside a `Replicated` database answers
  with a result set, not an empty body. With ClickHouse's default
  `distributed_ddl_output_mode = 'throw'`, `CREATE`, `ALTER` and `DROP` in a `Replicated`
  database return one row per replica (`shard_num`, `replica_num`, `host_name`, `status`
  and so on), as `ON CLUSTER` statements do. The transport's `classify` in
  `clickhouse-migrate/src/ClickHouseMigrate/Internal/Http.hs` acknowledges a `Command` only
  when the body is whitespace:

  ```haskell
  | kind == Command = if BS.all (`elem` [9, 10, 13, 32]) body then AcknowledgedSuccess CommandAccepted else unexpected
  ```

  Without a fixed output mode every replicated DDL step would be classified
  `SubmissionUncertain UnexpectedResponse`. The replicated policy must therefore pin
  `distributed_ddl_output_mode`; the `none` mode keeps waiting for every replica, including
  inactive ones, raises on timeout and returns no rows. The `*_only_active` modes silently
  skip inactive replicas and are never acceptable here. Milestone 3 records the exact body.

- Observation (review, 2026-11-07): the server-side waits are far longer than the client
  deadline. `HttpLimits` defaults to a 30 second request deadline
  (`clickhouse-migrate/src/ClickHouseMigrate/Target.hs`, `defaultHttpLimits`), while
  ClickHouse's defaults are `distributed_ddl_task_timeout = 180` seconds,
  `replication_wait_for_inactive_replica_timeout = 120` seconds (used by `alter_sync = 2`
  and `mutations_sync = 2`) and `insert_quorum_timeout = 600000` milliseconds. With one
  replica stopped, every replicated write would surface as `SubmissionUncertain
  DeadlineExpired` after 30 seconds while the server kept waiting. The replicated request
  settings must bound each server-side wait below the request deadline so a missing replica
  produces a complete, classifiable server error. The DDL is also already in the database's
  Keeper log at that point and will apply when the replica returns, so "fail closed" means
  "recorded as failed with possible effects or uncertain, never as succeeded".

- Observation (review, 2026-11-07): the ledger shape check cannot compare a replicated
  table's `engine_full` as one fixed string. `shape` in
  `clickhouse-migrate/src/ClickHouseMigrate/Internal/LedgerStore.hs` requires `engine_full`
  and `create_table_query` to equal `Schema.expectedEngine` and `Schema.expectedCreate`
  exactly. For a `ReplicatedMergeTree` created without arguments the server records the
  configured `default_replica_path` and `default_replica_name` (upstream defaults
  `/clickhouse/tables/{uuid}/{shard}` and `{replica}`; operators and Altinity override
  them). Those arguments contain the table UUID and differ between the fixture and the
  managed clusters. Milestone 7 compares structure instead. The original Decision Log claim
  that the default path is `/clickhouse/{cluster}/tables/{shard}/{uuid}` was unverified and
  has been withdrawn; the spike reads the actual values from `system.server_settings`.

- Observation (review, 2026-11-07): checksums are fixed before the target is known.
  `bindComponent` in `clickhouse-migrate/src/ClickHouseMigrate/Plan.hs` computes one
  `StepChecksum` and one `MigrationChecksum` per view at bind time, and
  `LedgerCodec.definitions`, `Preflight`, `Execution.orderedMigrations` and the CLI's
  offline `plan --json` (`clickhouse-migrate-cli/src/ClickHouseMigrate/CLI/Render/Json.hs`,
  line 36) all read that single value. A replicated target cannot "compute checksums for
  its policy" later unless the bound views carry both formats. Milestone 5 computes both
  at bind time.

- Observation (review, 2026-11-07): observing every replica needs a grant the application
  login may not have. `clusterAllReplicas(...)` needs the `REMOTE` or `CLUSTER` privilege
  and the cluster's interserver credentials. The infrastructure already uses it, but with
  the `pulumi` administrative login and keyed by `hostName()`, not UUID
  (`pulumi/lib/clickhouse-replicated-database.ts` in `mori://tan/tan-app-infrastructure`,
  around line 116). Milestone 4 therefore carries a fallback membership check that any
  login can run.

- Observation (review, 2026-11-07): one qualified version is named in at least six
  hand-maintained places: `supportedVersions` in `ServerPolicy.hs`, the matrix, the image
  pull in `.github/workflows/ci.yml` (line 26), `docs/user/compatibility.md`, the root and
  package `CHANGELOG.md` files and the dated evidence. Nothing checks that they agree, and
  `requiredGroups` in the matrix is read by no script (both `scripts/test-release-matrix.py`
  and `scripts/test-candidate-matrix.py` hard-code the same thirteen-group list). This is
  the cost Milestone 2 removes.

- Observation (review, 2026-11-07): in `mori://shinzui/kansoku`, `db/clickhouse/migrations`
  contains 22 `ENGINE = AggregatingMergeTree` and 9 `ENGINE = ReplacingMergeTree`
  occurrences and no plain `MergeTree`; the earlier figures (44, 18 and 1) are not
  reproducible from that directory. The count does not change this plan, so the Context
  section now describes the engines without numbers.


## Decision Log

- Decision (implementation, 2026-11-07): preserve the CLI report constructors'
  existing arities with bundled bidirectional patterns; additive checksum storage
  retains both digests without breaking existing report construction or matching.
  `contextFor` keeps taking an already-selected Definition; adding a redundant
  format argument there would not alter context bytes. Legacy adoption stays v1
  and refuses replicated execution before writes rather than silently rehashing
  a reviewed mapping. The final policy guard is topology-specific: v2 binding extends v1 engine support,
  while pending replicated preflight reserves additional policy/wait identifiers.
  This preserves every previously valid direct-target definition.

- Decision (implementation, 2026-11-07): `replicatedTargetConfig` returns
  `Either TargetError TargetConfig`, since the planned pure return type cannot
  reject duplicate UUIDs. Reject replicated deadlines shorter than five seconds.
  Split the available server-wait budget across three waits, leaving a two-second
  response margin, because DDL and engine waits can run sequentially. The three minimum one-second waits plus response margin require five seconds.

- Decision (implementation, 2026-11-07): promote the fixture's completion policy:
  empty DDL success and full-quorum INSERT acknowledgment are supported. Use local
  single-shard membership counts and per-socket UUID admission for restricted
  logins, with local storage checks on admitted replicas. Active-query repair
  diagnostics remain local and do not replace external drain evidence.

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
  bytes. `sha256-v1` stays the only format for direct targets. The spike-confirmed policy bytes are
  `clickhouse-migrate/replicated-sync-v1;async_insert=0;mutations_sync=2;alter_sync=2;insert_quorum=all;insert_quorum_parallel=0;distributed_ddl_output_mode=none;select_sequential_consistency=1`,
  confirmed by Milestone 3. The server-side wait bounds
  (`distributed_ddl_task_timeout`, `replication_wait_for_inactive_replica_timeout`,
  `insert_quorum_timeout`) are derived from the target's `HttpLimits` and are not part of
  the bytes.
  Rationale: `docs/user/contracts/checksum-v1.md` says that changing the policy bytes
  requires a new checksum version. Waiting for every replica changes what "completed" means
  for a step, and the output mode decides whether DDL is acknowledged at all (see Surprises
  & Discoveries). Timeouts bound how long the client waits, not what completion means, so
  they belong with `HttpLimits`. Keeping v1 untouched preserves Kansoku's 565-row staging
  history and every published vector.
  Date: 2026-11-07 (revised 2026-11-07 after review)

- Decision: Keep rejecting `ON CLUSTER`, the `Replicated` database engine, `Distributed`,
  `remote` and explicit Keeper path or replica arguments. Refuse `CREATE DATABASE` steps on
  replicated targets before any submission.
  Rationale: inside a `Replicated` database, ClickHouse replicates table DDL through its own
  Keeper log, so `ON CLUSTER` is neither needed nor wanted. The server fills the Keeper path
  and replica name from its configured `default_replica_path` and `default_replica_name`
  (the spike records the exact values), and refuses different explicit arguments unless
  `database_replicated_allow_replicated_engine_arguments` permits them. Databases are
  created by `mori://tan/tan-app-infrastructure` as `Replicated ON CLUSTER`; a database
  created by a migration would be `Atomic` and would hold data on only one replica.
  Date: 2026-11-07

- Decision: Bound views carry both checksum formats. `bindComponent` computes the v1 and
  v2 digests for every step and migration; the topology selects which one the runner,
  ledger codec and reports use. Existing accessors keep returning v1; new accessors take a
  `ChecksumFormat`. The offline `plan --json` keeps its v1 `checksumFormat`,
  `completionPolicy` and per-item `checksum` fields unchanged and adds an additive
  `checksums` object keyed by format name.
  Rationale: the plan is bound before any target exists, and two SHA-256 digests per step
  cost nothing. Computing both keeps `MigrationPlan` target-independent, so one embedded
  manifest serves a direct staging target and a replicated production target.
  Date: 2026-11-07

- Decision: The replicated ledger shape check is structural, not an exact `engine_full`
  string. It requires engine name `ReplicatedMergeTree`, exactly two string-literal engine
  arguments whose text is not inspected, the exact column list, `sorting_key = sequence`,
  empty partition and sampling keys, and the exact `SETTINGS` clause; it additionally reads
  `system.replicas` for the table and requires `is_readonly = 0` and `total_replicas` equal
  to the configured replica count. Direct targets keep the exact-string comparison.
  Rationale: the server-filled Keeper arguments contain the table UUID and depend on
  server configuration, so no fixed string can match both the fixture and Altinity.Cloud.
  Everything that the ledger relies on is still compared exactly.
  Date: 2026-11-07

- Decision: Centralize server-dependent policy before building replicated support
  (Milestone 2). One private module, `ClickHouseMigrate.Internal.ServerProfile`, owns the
  probe query, the per-request settings, the completion policy bytes, the checksum format
  and the ledger expectation as functions of the topology; `TargetConfig` becomes a record;
  the matrix declares each candidate's test groups; `just check` runs a drift check between
  the allowlist, the matrix and the CI image pulls; `scripts/qualify-candidate.py` resolves
  a new build into a matrix entry.
  Rationale: Milestone 1 shows the cost of a version change, and Milestones 4 to 7 would
  otherwise add topology conditionals to four modules. Doing the refactor first makes the
  later milestones additive and makes the next ClickHouse change a data edit plus a matrix
  run. Direct-target bytes are pinned by tests so the refactor is observable as a no-op.
  Date: 2026-11-07

- Decision: No new CLI command for admission probing. `status --json` already performs full
  admission on a fresh connection before reading anything and sends no application or
  ledger writes, so it is the documented pre-fence probe; the Kansoku Job should run it
  before `maintenance begin`.
  Rationale: a `check-target` command would duplicate `status` and extend the JSON v1
  contract for no new information.
  Date: 2026-11-07

- Decision: The two-replica fixture runs ClickHouse Keeper in its own container, and the
  `replicated` integration group uses only the public API and the mounted CLI (no private
  test driver). The group is declared only for container candidates in the matrix.
  Rationale: embedding Keeper in replica one would make stopping replica one stop
  coordination as well, so stop/start tests would not be symmetric. Public outcomes
  (`TargetFailed`, `SqlFailed`, `LedgerRequestFailed` with their transport codes) already
  expose the evidence the group needs. The native macOS candidate cannot run a Docker
  network, and the matrix script's rule is "never skip silently", so the matrix must say
  which groups each candidate owns.
  Date: 2026-11-07

- Revision note (2026-11-07): A review against the working tree found five material gaps
  (replicated DDL result sets, uncoordinated timeouts, exact-string engine comparison,
  bind-time checksums and the `clusterAllReplicas` grant) and several omissions (CI image
  pull, changelogs, the OKF user-documentation profile, the preflight error's type, the
  fourteen positional `TargetConfig` matches). This revision fixes them in place, inserts
  Milestone 2 so later milestones become additive, and renumbers the prototype and the
  replicated milestones to 3 through 8. The user asked for the plan to make future
  ClickHouse changes easier to support; Milestone 2 and the data-driven matrix are that
  expansion and can be struck if only replicated support is wanted.


## Outcomes & Retrospective

All eight local implementation milestones are complete. The independent exact-patch
boundary is commit `0d4f889` (shared version `0.1.0.2`), with 39 passing cases in
each of the Nix and extracted-source variants. The feature candidate is shared
version `0.1.1.0`; `just check`, all 41 matrix cases and two installed-Nix replicated
groups pass. The seven candidate archives include the new assets, and all v1 vector
files remain byte-identical. Full evidence and archive/artifact identities are in
`docs/release-evidence/2026-11-07-replicated.md` and its JSON receipt.

Durable decisions are distilled into ADR 0015, with links from ADRs 0005 and 0014:
replica-set admission, restricted-login count fallback, full quorum, DDL output mode,
server/client waits, independent checksum format, explicit engine SQL, structural
ledger validation and centralized server policy. The prototype exposed real server
outcomes and prevented treating quorum timeouts as non-submission. Final checks
also fixed Boolean probe spelling, replica readiness, strict string metadata,
topology-specific pending hashes and preservation of all direct v1 definitions.

Production readiness remains the consumer's gate: a replicated baseline, precreated
Replicated databases, scoped system metadata grants, independently verified inventory,
cluster-wide coordination/drain and a successful managed staging run. The referenced
infrastructure tree establishes staging Local storage and narrow grants but does not
record all production observations. No managed server was changed, no downstream
repository was edited and no Hackage upload or release tag was made.


## Context and Orientation

The detailed inventory below records the starting tree. The completed local feature
uses shared version `0.1.1.0`, named TargetConfig fields and ServerProfile policy;
checksum v2, SQL envelope v2 and replicated fixture files are described in the
milestones and final outcomes. The independent patch boundary is commit `0d4f889`
(shared version `0.1.0.2`).

clickhouse-migrate is a Haskell toolkit (GHC 9.12, Cabal and Nix) that applies ordered,
checksummed ClickHouse migrations and records each step in an append-only ledger. Its
packages are `clickhouse-migrate` (the core library), `clickhouse-migrate-embed`
(compile-time manifests), `clickhouse-migrate-cli` (a reusable command parser and handler
that applications mount), and `clickhouse-migrate-test-support` (owned server fixtures and
the native integration suites). The CLI's `up` applies pending migrations, `status` and
`history` read the ledger, and `verify` compares the ledger with the compiled plan. Repair
commands handle interrupted steps. Run `just` from the repository root to list recipes. The
development shell is `nix develop`. All four packages are at version `0.1.0.1`, with mutual
bounds `==0.1.*`.

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
  have the data. With `insert_quorum_parallel = 0` only one quorum insert per table may be
  in flight, which is fine here because the ledger has one writer under exclusive access
  and application steps run one at a time. **Sequential consistency**
  (`select_sequential_consistency = 1`) makes a read on any replica return only data
  committed with a quorum, failing if the replica is behind; it applies only to
  non-parallel quorum inserts.
- `alter_sync` and `mutations_sync` control how many replicas an ALTER or mutation waits
  for: `1` waits for the local replica and `2` waits for all of them, up to
  `replication_wait_for_inactive_replica_timeout`.
- `distributed_ddl_output_mode` decides what a replicated DDL statement returns and
  whether it waits for inactive replicas; `distributed_ddl_task_timeout` bounds that wait.
- The **completion policy** is the fixed set of request settings the transport forces on
  every POST. Its exact bytes are part of every checksum.
- The **topology** is the shape of the target: today one direct server; after this plan,
  either that or one replicated cluster with an exact replica set.

The parts of the code this plan changes are listed below. Paths are relative to the
repository root.

The **admission and transport** layer is in `clickhouse-migrate/src/ClickHouseMigrate/Internal/ServerPolicy.hs`
and `clickhouse-migrate/src/ClickHouseMigrate/Internal/Http.hs`. `supportedVersions` holds
the exact allowlist `["26.8.28.14", "26.3.60.10001.altinitystable"]`. `identityQuery` reads
`serverUUID()`, `version()`, `hostName()` and the effective `async_insert`, `mutations_sync`
and `alter_sync`. `validateOutcome` rejects a UUID other than the single configured
`ServerId`, an unlisted version, or a completion policy other than 0/1/1.
`withTransportChecked` runs that probe on every newly opened socket before it enters the
pool, and is the only entry point used by `Ledger.hs`, `Inspection.hs` and
`Internal/Execution.hs`. `makeRequest` in `Http.hs` adds `async_insert=0`,
`mutations_sync=1`, `alter_sync=1`, `fsync_metadata=1`, `wait_end_of_query=1` and JSON
output to every POST, plus throwing overflow modes for reads. `classify` in the same file
acknowledges a `Command` only when the response body is empty apart from whitespace.

**Target configuration** is in `clickhouse-migrate/src/ClickHouseMigrate/Target.hs`, with the
private record in `clickhouse-migrate/src/ClickHouseMigrate/Internal/TargetTypes.hs`.
`TargetConfig` is a seven-field positional constructor, matched positionally in fourteen
places: `Target.hs` (two accessors), `Internal/ServerPolicy.hs`, `Internal/Preflight.hs`,
`Internal/LedgerStore.hs` (five), `Internal/Execution.hs` (three), `Ledger.hs` (two),
`Inspection.hs`, `Repair.hs` and `Adoption.hs`.
`targetConfig :: TargetKey -> DirectEndpoint -> ServerId -> LedgerNamespace -> LedgerBinding -> Credentials -> HttpLimits -> TargetConfig`
is the only public constructor. `HttpLimits` holds the request deadline and the response
byte bound; the default deadline is 30 seconds.

The **SQL envelope** is in `clickhouse-migrate/src/ClickHouseMigrate/Internal/SqlEnvelope.hs`.
It is a lexical, comment- and literal-aware token check run when a step is defined.
`checkEnvelope` rejects protected settings, any `ON CLUSTER` pair, and, through `forbidden`,
any word or quoted identifier starting with `REPLICATED`, plus `DISTRIBUTED`, `REMOTE` and
others listed in `forbiddenWords`. `accepted` then allows only certain command families
(CREATE TABLE/VIEW/MATERIALIZED VIEW/DATABASE, ALTER TABLE actions, DROP, TRUNCATE,
EXCHANGE, RENAME, INSERT ... SELECT/VALUES). The contract is
`docs/user/contracts/sql-envelope-v1.md`. The unit tests in
`clickhouse-migrate/test/Main.hs` (around line 83) already list
`CREATE TABLE app.t ENGINE=ReplicatedMergeTree ORDER BY tuple()` as unsupported.

**Checksums** are in `clickhouse-migrate/src/ClickHouseMigrate/Internal/Checksum.hs`
(`completionPolicyV1`, `encodeStepV1`, `encodeMigrationV1`), surfaced through
`clickhouse-migrate/src/ClickHouseMigrate/Plan.hs` (`ChecksumV1`, `checksumFormatName`,
`completionPolicy`). `bindComponent` in `Plan.hs` computes one digest per step and per
migration when a component is bound, before any target exists. `LedgerCodec.definitions`
turns bound views into ledger `Definition` values using those digests, and `Preflight`,
`Execution.orderedMigrations` and the CLI's `plan`, `status` and `history` renderings read
them. The contract and independent vectors are in `docs/user/contracts/checksum-v1.md`; the
vectors in `clickhouse-migrate/test/vectors/checksum-v1.tsv` are generated once by
`scripts/checksum-reference.py`, and `just check-public-invariants` runs that script with
`--check` to prove the checked-in vectors still match.

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

**Preflight** in `clickhouse-migrate/src/ClickHouseMigrate/Internal/Preflight.hs` runs before
any submission and returns `R.RunError` values from
`clickhouse-migrate/src/ClickHouseMigrate/Report.hs`; the existing SQL-shaped refusal is
`LedgerNamespaceInSql !StepReference`. **Repair** in
`clickhouse-migrate/src/ClickHouseMigrate/Repair.hs` (around line 194) checks for active
queries with `system.processes`, which only shows queries on the replica that answers.

**Error rendering**: every new error constructor must be named in `docs/user/error-codes.md`
and rendered by `clickhouse-migrate-cli/src/ClickHouseMigrate/CLI/Render/Json.hs` and
`.../Render/Text.hs`; the transport code mapping is at `Json.hs` line 162.

**Test support** lives in `clickhouse-migrate-test-support`. The candidate matrix
`clickhouse-migrate-test-support/test/data/clickhouse-matrix.json` (also linked as
`test/compatibility/clickhouse-matrix.json`) lists each exact server artifact. The Altinity
entry pins the Linux arm64 manifest digest of `docker.io/altinity/clickhouse-server`. Its
`qualification.requiredGroups` field is descriptive only: `scripts/test-release-matrix.py`
and `scripts/test-candidate-matrix.py` each hard-code the same thirteen-group list, and
`integrationMain` in `clickhouse-migrate-test-support/test/Main.hs` hard-codes which groups
need the private test driver (`CLICKHOUSE_MIGRATE_TEST_DRIVER`) and dispatches on the
group name. `clickhouse-migrate-test-support/test/scripts/native_fixture.py` starts one owned
server, either a native binary or a container through an explicitly selected Docker context
(`CLICKHOUSE_MIGRATE_DOCKER_CONTEXT`). It writes `config.xml` and a deliberately weak
`users.xml` so the transport must override settings, and speaks a line-delimited JSON
protocol on stdin/stdout (`query`, `restart`, `proxy-*`, `stop`). The Haskell side drives it
through `clickhouse-migrate-test-support/src/ClickHouseMigrate/TestSupport/Server.hs`
(`withCandidateServer`, `queryServer`, `restartCandidateServer`) and
`.../TestSupport/Internal/Fixture.hs`, which locates the script and matrix through the
package's `data-files`. Suites are selected with `--test-options=<group>` in `justfile`
recipes such as `test-transport`, `test-ledger`, `test-runner` and `test-adoption`.
`just test-release-matrix` runs all thirteen groups for every candidate and artifact variant.
`.github/workflows/ci.yml` starts an isolated Colima context and pre-pulls the exact Altinity
digest (line 26) before running the matrix.

**User documentation** under `docs/user/` is a strictly validated OKF bundle
(`just check-docs` runs `okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce`).
Every file carries frontmatter with `type`, `title`, `description`, `docId`, `tags` and
`generated`; stable handles `DOC-1` through `DOC-13` are allocated. A new document needs
the next handle from `okf id next docs/user --profile mori/user-documentation-profile.dhall DOC`,
an entry in `docs/user/contracts/index.md` (for contracts) and a dated entry in
`docs/user/log.md`. `docs/adr/` is not an OKF bundle: ADRs are plain files numbered
`NNNN-slug.md` with `Status:` and `Date:` lines. Follow that convention.

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

Outside this repository, the handoff that motivated the plan was written by the TAN
infrastructure owner on 2026-11-07 while bringing production ClickHouse into
`mori://tan/tan-infrastructure/plans/6-bring-the-production-clickhouse-cluster-on-altinity-cloud-into-the-repository`
(the local registry checkout of that project holds plans 1 to 5 only, so this reference
resolves once the registry is refreshed; `pulumi/lib/foundation.ts` in
`mori://tan/tan-app-infrastructure` cites the same plan). Production is
`ClickHouseClusters.production` in `mori://tan/tan-app-infrastructure`
(`pulumi/lib/foundation.ts`): host `tan-production.topagentnetwork-5os8y.altinity.cloud`,
native TLS 9440, HTTPS 8443, cluster name `tan-production`. Staging (`tan-staging`) is one
replica on the same build. The infrastructure creates application databases with
`CREATE DATABASE IF NOT EXISTS <name> ON CLUSTER '<cluster>' ENGINE = Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')`
and verifies them with `clusterAllReplicas('<cluster>', system.databases)` under the
administrative login (`pulumi/lib/clickhouse-replicated-database.ts`). The Kansoku-side
work is out of scope here and is listed under Interfaces and Dependencies. It covers a
replicated migration baseline that converts its `AggregatingMergeTree` and
`ReplacingMergeTree` tables, and removing `CREATE DATABASE IF NOT EXISTS analytics` from
its migrations 0001–0003.


## Plan of Work

The work runs in eight milestones. Milestone 1 is independent and ships first. Milestone 2
is a behaviour-preserving refactor that makes everything after it additive; it does not
depend on replication and can also ship alone. Milestone 3 is a bounded prototype whose
evidence fixes the exact settings and metadata rules that Milestones 4 to 7 encode;
Milestones 2 and 3 are independent of each other and may run in either order or in
parallel. Milestones 4 to 7 are additive behind the new replicated topology, so the
direct-target suites keep passing throughout. Milestone 8 proves the whole path and writes
the durable documentation.


### Milestone 1: qualify Altinity 26.3.60.10002.altinitystable

Repeat the ADR 0014 procedure for the new patch. Resolve the Linux arm64 manifest digest
behind the `26.3.60.10002.altinitystable` tag. On 2026-11-07 Docker Hub listed the
multi-arch index `sha256:53e81c410a22ab052a4d967adc2886b547c91e67370e2d02f5c2ea1177d4d3aa`.
The matrix stores the arm64 manifest digest, not the index digest, so resolve that with
`docker buildx imagetools inspect` and record both. Also resolve the release tag object and
source commit from `https://github.com/Altinity/ClickHouse` (`git ls-remote --tags` needs
no credentials). Add a matrix entry `altinity-linux-arm64-10002` next to the 10001 entry
with the same fields, and add `"26.3.60.10002.altinitystable"` to `supportedVersions` in
`ServerPolicy.hs`, keeping both coordinated as the comment requires. Add a second
`docker ... pull` line for the new digest to `.github/workflows/ci.yml`, next to the
existing one on line 26, so CI has the image before the matrix runs. Pre-pull the digest
into the isolated Docker context and run `just test-release-matrix`.
Record a dated evidence file `docs/release-evidence/<date>-altinity-10002.md` modelled on
`docs/release-evidence/2026-11-02-altinity.md`. Update `docs/user/compatibility.md` (and add
a `docs/user/log.md` entry, since it is in the OKF bundle), add a short paragraph to ADR
0014 naming the additional patch, and add the version to the root `CHANGELOG.md` and the
`clickhouse-migrate/CHANGELOG.md` entries for the new patch cohort. Bump the patch version
of all four packages (`0.1.0.1` to `0.1.0.2`); the `==0.1.*` mutual bounds need no change.

At the end, the release matrix passes for every candidate. A probe against an owned 10002
container is admitted, and an unlisted patch is still rejected with `UnsupportedServer`.
The Kansoku pin bump is done in `mori://shinzui/kansoku`; it is noted under Interfaces and
Dependencies.


### Milestone 2: centralize server-dependent policy and make the matrix drive the tests

This milestone changes no behaviour for direct targets, and proves it. It exists so that
the next version bump, engine or topology is a data edit plus a matrix run.

First, convert `TargetConfig` in `Internal/TargetTypes.hs` to a record with named fields
(`configKey`, `configEndpoint`, `configTopology`, `configNamespace`, `configBinding`,
`configCredentials`, `configLimits`) and replace the fourteen positional matches listed in
Context and Orientation with field accessors. Introduce
`data TargetTopology = DirectServer !ServerId` in the same module (the replicated
constructor arrives in Milestone 4), keep `targetConfig` building `DirectServer`, and add a
read-only accessor `configuredTopology :: TargetConfig -> TargetTopology` exported from
`ClickHouseMigrate.Target`, together with the `TargetTopology` type and its `DirectServer`
pattern. `check-public-invariants.py` must still reject constructing or coercing a
`TargetConfig` from outside.

Second, create `clickhouse-migrate/src/ClickHouseMigrate/Internal/ServerProfile.hs`. It
owns, as total functions of `TargetTopology` (and `RequestKind` where relevant): the
admission probe query (today's `identityQuery`), the admission validator for a probe row,
the list of query-string settings `makeRequest` appends, the completion policy bytes, the
`ChecksumFormat`, and the ledger expectation (database engine, table DDL and the shape
rule). `Http.hs`, `ServerPolicy.hs`, `LedgerSchema.hs` and `LedgerStore.hs` call into it
and contain no topology conditionals of their own. `supportedVersions` stays in
`ServerPolicy.hs`.

Third, pin the direct bytes. Add unit tests in `clickhouse-migrate/test/Main.hs` that the
`DirectServer` request setting list is exactly
`query_id, async_insert=0, mutations_sync=1, alter_sync=1, fsync_metadata=1, wait_end_of_query=1, default_format=JSONEachRow`
plus the eight read-only overflow settings for non-command kinds, that the policy bytes
are the v1 string, and that the ledger DDL and expected strings equal today's literals.
These tests are the proof that later milestones never move direct-target bytes.

Fourth, make the matrix authoritative for groups. Add a `groups` array to each matrix
entry (today: the same thirteen names for both entries), have
`scripts/test-release-matrix.py` and `scripts/test-candidate-matrix.py` read it instead of
their `GROUPS` constants, and move the "needs the private driver" property into one table
in `clickhouse-migrate-test-support/test/Main.hs` next to the dispatch, so a new group is
declared in exactly two places (the matrix and that table). Keep the existing
`qualification.requiredGroups` numbers as documentation of past runs.

Fifth, add `scripts/check-candidate-policy.py` and run it from the `check-public-invariants`
recipe. It parses `supportedVersions` out of `ServerPolicy.hs` with a regular expression,
loads the matrix, and fails unless the two version sets are equal, every `image` digest in
the matrix appears in a `docker ... pull` line of `.github/workflows/ci.yml`, and every
matrix version is named in `docs/user/compatibility.md`.

Sixth, add `scripts/qualify-candidate.py`. Given `--tag v26.3.60.10002-1.altinitystable`,
`--repo https://github.com/Altinity/ClickHouse` and
`--image docker.io/altinity/clickhouse-server:26.3.60.10002.altinitystable`, it resolves
the tag object and dereferenced commit with `git ls-remote`, resolves the index digest and
the `linux/arm64` manifest digest with `docker --context "$CLICKHOUSE_MIGRATE_DOCKER_CONTEXT" buildx imagetools inspect --raw`,
and prints a complete matrix entry (status `candidate`, empty `qualification`), the CI pull
line and a skeleton for the evidence file. It writes nothing unless `--write` is given, in
which case it appends the entry to the matrix. Running it for the 10002 tag must reproduce
the entry Milestone 1 added by hand, which is the script's acceptance test.

Finally, add a "Qualifying a new ClickHouse build" section to `docs/user/compatibility.md`
(with a `docs/user/log.md` entry) that lists the runbook: run `qualify-candidate.py`, add
the version to `supportedVersions`, let `check-candidate-policy.py` point at anything
missed, pre-pull, run `just test-release-matrix`, write the dated evidence, bump the patch
version.

At the end, `just check` passes with the new drift check; temporarily removing one version
from `supportedVersions` makes `python3 scripts/check-candidate-policy.py` exit non-zero
with the missing version named; `just test-transport`, `just test-completion-policy` and
`just test-ledger` pass unchanged; and `python3 scripts/qualify-candidate.py` for the 10002
tag reproduces the matrix's immutable identity fields and declared groups; status, release-date and historical qualification annotations remain evidence maintained by the qualifier.


### Milestone 3 (prototype): two-replica Keeper fixture and replicated spike

This milestone is labelled a prototype. Its fixture code is kept and promoted. Its spike
script and findings are kept as evidence, and its findings decide the exact bytes used
later.

Extend `clickhouse-migrate-test-support/test/scripts/native_fixture.py` with a replicated
variant that runs only in container mode. It creates a private Docker network and three
containers from the same pinned image: one running only `clickhouse keeper`, and two
replicas. Each replica's `config.xml` gains a `<zookeeper>` section pointing at the Keeper
container, a `<remote_servers>` cluster named `fixture` with one shard and both replicas,
and `<macros>` for `cluster`, `shard` and `replica`. Both servers get their own data root
and persisted UUID. Add a `users.xml` login `app` whose profile sets
`database_replicated_allow_only_replicated_engine` to 1 as a constant, as in production,
and keep the deliberately weak defaults for the other settings. Create `fixture_app` and
`fixture_ledger` as `ENGINE = Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')`
`ON CLUSTER fixture` with the administrative login, exactly as the infrastructure does.
Add fixture operations `query-replica`, `stop-replica` and `start-replica` to the JSON
protocol, and expose `withReplicatedCandidate`, `queryReplica`, `stopReplica` and
`startReplica` from `ClickHouseMigrate.TestSupport.Server`, along with a load-balanced
endpoint. That endpoint is a small round-robin TCP forwarder in the fixture script that
alternates replicas per connection, which is what the production endpoint may do. The
fixture removes its network and all three containers on exit, keeping the diagnostic root
on failure as today.

Write `scripts/replicated-spike.py`, which uses the fixture and records JSON answers to
these questions:

1. The exact `system.databases.engine`, and the `system.tables` `engine`, `engine_full`,
   `sorting_key` and `create_table_query` of a ledger-shaped table created as
   `ENGINE=ReplicatedMergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'`,
   on both replicas, together with `default_replica_path` and `default_replica_name` from
   `system.server_settings` and the table's `zookeeper_path`, `replica_name`,
   `total_replicas`, `active_replicas` and `is_readonly` from `system.replicas`. This fixes
   the structural shape rule of Milestone 7.
2. The exact HTTP status, headers and body returned by `CREATE TABLE`, `ALTER TABLE ... ADD COLUMN`
   and `DROP TABLE` inside `fixture_app` under each of `distributed_ddl_output_mode`
   `throw`, `none` and `null_status_on_timeout`, with both replicas running and with one
   stopped, using `distributed_ddl_task_timeout` set to 5 seconds. Record the server error
   code when a replica is missing (expected `159`, `TIMEOUT_EXCEEDED`) and whether the DDL
   applied on the stopped replica after it restarted (expected yes, through the Keeper
   log). Also record what `alter_sync=2` and `mutations_sync=2` return with one replica
   stopped and `replication_wait_for_inactive_replica_timeout` set to 5 seconds (expected
   `341`, `UNFINISHED`, with the change applied on the live replica).
3. Whether `insert_quorum=2, insert_quorum_parallel=0, insert_quorum_timeout=5000` fails
   when one replica is stopped, with which code (expected `285` or `319`), whether the row
   is visible on the live replica without sequential consistency, and whether the insert
   becomes visible to a sequentially consistent read after the stopped replica returns. That
   last case must be treated as uncertain, never as non-submission.
4. Whether `select_sequential_consistency=1` on the lagging replica fails rather than
   returning stale rows, and with which code.
5. Whether the `app` login can read `serverUUID()` from every replica with
   `clusterAllReplicas('fixture', system.one)` or another read-only query, which grants it
   needs, and what `system.clusters WHERE cluster = 'fixture'` and `system.replicas` show
   to a login without those grants. This decides how membership is observed in Milestone 4.
6. That a plain `MergeTree` table in `fixture_app` fails with Code 56 for `app`, that a
   Replicated engine with an explicit differing Keeper path is refused, and that the
   argument-free `ReplicatedReplacingMergeTree(ver)` form is accepted.
7. What `clusterAllReplicas('fixture', system.processes)` shows for a long-running query
   started through the other replica, and whether `app` may run it.
8. What `system.storage_policies` and `system.disks` report on each replica, so the ledger's
   `checkLocalStorage` rule is known to hold on the fixture.

Record the output as `docs/release-evidence/<date>-replicated-spike.json` with a short
companion Markdown note. Then confirm or correct the replicated policy bytes in the
Decision Log. The working assumption is `async_insert=0`, `mutations_sync=2`, `alter_sync=2`,
`insert_quorum=<replica count>`, `insert_quorum_parallel=0`, `distributed_ddl_output_mode=none`,
`select_sequential_consistency=1` on reads, `fsync_metadata=1`, `wait_end_of_query=1`, with
`distributed_ddl_task_timeout`, `replication_wait_for_inactive_replica_timeout` and
`insert_quorum_timeout` derived from the request deadline (deadline minus a two second
margin, divided across three waits and floored at one second, with a five-second
minimum replicated request deadline).

Separately, ask the TAN infrastructure owner four read-only questions about
`tan-production` and record the answers in Surprises & Discoveries: whether Altinity.Cloud
exposes per-replica host names; what `default_replica_path` and `default_replica_name` are;
whether the application login may run `clusterAllReplicas`; and what
`system.storage_policies` and `system.disks` report for the `default` policy, because the
ledger's `checkLocalStorage` refuses object-storage-backed defaults and this cannot be
learned from the fixture. The design does not depend on the first answer, but operators may
prefer to address one replica directly.

Promote the prototype if every question has a recorded, repeatable answer. Discard and
revisit the Decision Log if question 2 or 3 shows that no setting makes acknowledged DDL or
inserts wait for every replica, or that no output mode gives an empty acknowledged body
while still waiting for inactive replicas. In that case the replicated target cannot honour
ADR 0005's acknowledgement meaning and the topology must be reconsidered before continuing.


### Milestone 4: replicated target configuration and admission

Add the second constructor to `TargetTopology` in `Internal/TargetTypes.hs`:
`ReplicatedCluster !ClusterName !(NonEmpty ServerId)`. Keep `targetConfig` unchanged; it
builds `DirectServer`. Add `clusterName :: Text -> Either TargetError ClusterName` (same
character rules as `ledgerNamespace`, plus `-`, because the production name is
`tan-production`) and a new public constructor in `ClickHouseMigrate.Target`:

```haskell
replicatedTargetConfig
  :: TargetKey -> DirectEndpoint -> ClusterName -> NonEmpty ServerId
  -> LedgerNamespace -> LedgerBinding -> Credentials -> HttpLimits -> Either TargetError TargetConfig
```

It rejects duplicate UUIDs with a new `TargetError` constructor `DuplicateReplica`.
`configuredTopology` from Milestone 2 now returns either constructor.

In `ServerProfile.hs`, give the `ReplicatedCluster` case its own probe query, validator and
request settings. The probe additionally returns `getMacro('cluster')` and the effective
value of every replicated policy setting, and the validator accepts a socket only if its
`serverUUID()` is a member of the expected set, the macro equals the configured cluster
name, the version is allowlisted and every policy setting is effective. The request
settings are the replicated policy with `insert_quorum` equal to the set size,
`select_sequential_consistency=1` on non-command reads, and the three wait bounds derived
from `HttpLimits`. Direct targets keep today's exact query string, which the Milestone 2
unit tests pin.

At the start of every `withTransportChecked` scope on a replicated target, issue one
membership read and fail with a new `TransportErrorCode` `ReplicaSetMismatch` if it
disagrees with the configuration. If spike question 5 showed that the application login
can run `clusterAllReplicas('<cluster>', system.one)`, require the set of `serverUUID()`
values it returns to equal the configured set exactly. Otherwise require
`SELECT count() FROM system.clusters WHERE cluster = '<cluster>'` to equal the configured
set size, and rely on per-connection admission for identity; document which rule is in
force in `docs/user/compatibility.md`. The `ServerIdentity` returned to callers keeps the
admitted replica's UUID and host, so reports show which replica answered.

Make the repair active-query check in `Repair.hs` cover every replica on replicated targets
(the query chosen from spike question 7, or the local `system.processes` with a documented
caveat if `app` may not run it). The spike selected the local fallback; its result stays a diagnostic only, as today.

Document in `docs/user/operations.md` how an operator obtains the replica UUIDs to
configure: run `SELECT hostName(), toString(serverUUID()) FROM clusterAllReplicas('<cluster>', system.one)`
once with the administrative login, and record the UUIDs with the deployment
configuration. Also document that `status --json` is the pre-fence admission probe (see
the Decision Log).

At the end, unit tests cover the constructors and the admission validator, and a new
`replicated` integration group (public API only, declared in the matrix for the Altinity
entry) shows that admission succeeds through the round-robin endpoint, and is rejected with
`ServerIdentityMismatch` when one configured UUID is wrong, with `ReplicaSetMismatch` when a
replica is missing from the configured set, and with `CompletionPolicyMismatch` when the
login's profile lowers `alter_sync`. `just test-transport` and `just test-completion-policy`
still pass unchanged against direct targets.


### Milestone 5: replicated completion policy and `sha256-v2`

Introduce a private `CompletionPolicy` type with `LocalSyncV1` and `ReplicatedSyncV1`.
`completionPolicyV1` keeps its exact bytes. Add `completionPolicyReplicatedV1` with the
bytes fixed by Milestone 3, starting with `clickhouse-migrate/replicated-sync-v1;`. The
quorum count and the wait bounds are not part of the bytes: they are properties of the
target, not of the step's meaning. The policy says "all configured replicas".
Parameterize `encodeStepV1` and `encodeMigrationV1` in `Internal/Checksum.hs` by policy
and version tag (`v2` uses the v1 framing with `v2` in the domain and the replicated
policy field). Extend `ChecksumFormat` in `Plan.hs` with `ChecksumV2` and the name
`sha256-v2`, and `parseChecksumFormat` accordingly.

Make `bindComponent` compute both digests: `StepView` and `MigrationView` carry a v1 and a
v2 checksum. `stepChecksum` and `migrationChecksum` keep returning v1; add
`stepChecksumFor :: ChecksumFormat -> StepView -> StepChecksum` and
`migrationChecksumFor`. Give `LedgerCodec.definitions` and `contextFor` a `ChecksumFormat`
argument derived from the topology (`ServerProfile.checksumFormat`), and thread it through
`Preflight`, `Execution.orderedMigrations`, `Inspection` and `Repair` wherever definitions
are built or compared. Update `LedgerCodec` so the initialized event writes the format and
policy for the target's topology; decoding accepts exactly the pair that matches the
configured topology, so a direct target rejects a v2 ledger and a replicated target rejects
a v1 ledger, both as `UnsupportedLedgerVersion` or a more specific existing `LedgerError`
(decide and document which).

In the CLI, keep every existing `checksumFormat`, `completionPolicy` and `checksum` field
exactly as it is (v1 values) and add an additive `checksums` object keyed by format name
(`{"sha256-v1": "...", "sha256-v2": "..."}`) to each migration and step in the `plan`
report, and a top-level `checksumFormats` list. `status` and `history` report the format
the ledger actually recorded. Record the additions in `docs/user/contracts/json-v1.md` as
additive fields with a refreshed golden fixture.

Extend `scripts/checksum-reference.py` with a `v2` mode that uses the replicated policy
bytes and `v2` domain, generate `clickhouse-migrate/test/vectors/checksum-v2.tsv` once from
the same cases as v1, and make `--check` verify both files so
`just check-public-invariants` covers v2. Write `docs/user/contracts/checksum-v2.md`
(allocate `DOC-14` or the next free handle with `okf id next`, add it to
`docs/user/contracts/index.md` and `docs/user/log.md`), and leave `checksum-v1.md`
unchanged apart from a link to v2.

At the end, every existing checksum and ledger vector test passes unchanged. New vector
tests pass for v2, `just check-public-invariants` verifies both vector files, and a test
shows that one migration has different v1 and v2 checksums while `plan --json` still shows
the v1 value in the pre-existing fields.


### Milestone 6: replicated engines in the SQL envelope

In `SqlEnvelope.hs`, stop treating every `REPLICATED`-prefixed word as forbidden. Define
one constant `replicatedEngines` listing exactly `REPLICATEDMERGETREE`,
`REPLICATEDREPLACINGMERGETREE`, `REPLICATEDAGGREGATINGMERGETREE`,
`REPLICATEDSUMMINGMERGETREE`, `REPLICATEDCOLLAPSINGMERGETREE` and
`REPLICATEDVERSIONEDCOLLAPSINGMERGETREE`. Each is permitted only as the engine name
directly after `ENGINE` or `ENGINE =`, in a `CREATE TABLE` or `CREATE MATERIALIZED VIEW`
statement. When the engine name is followed by `(`, the first argument must not be a
string literal, so explicit Keeper paths and replica names are rejected. Every other
`REPLICATED`-prefixed word or quoted identifier stays forbidden. That includes the
`Replicated` database engine, `SYSTEM ... REPLICA` forms and quoted spellings. `ON CLUSTER`,
`DISTRIBUTED` and `REMOTE` stay forbidden. Export `replicatedEngines` so the documentation
test and the ledger module share the single list.

This is a lexical check like the rest of the envelope. Document it in a new
`docs/user/contracts/sql-envelope-v2.md` (next `DOC` handle, index and log entries): a
strict superset of v1, with v1 kept and marked superseded. Definitions already valid under
v1 stay valid, so no checksum moves.

In `Internal/Preflight.hs`, refuse a plan on a replicated target when any pending step is
`CREATE DATABASE`, before any submission. Use the envelope's token scan (as
`mentionsIdentifier` does) rather than a new parser, and add a `RunError` constructor
`DatabaseCreationOnReplicatedTarget !StepReference` beside `LedgerNamespaceInSql`, rendered
as `database-creation-on-replicated-target` under the Run family in
`docs/user/error-codes.md` and in both CLI renderers. Applied history is not re-checked.

At the end, unit tests in `clickhouse-migrate/test/Main.hs` accept the argument-free forms
(including `ReplicatedReplacingMergeTree(updated_at)` with a non-literal argument and
`ENGINE=ReplicatedMergeTree` without spaces) and reject explicit paths, `ENGINE = Replicated`,
quoted `"ReplicatedMergeTree"` outside an engine position, `ON CLUSTER` and `Distributed`.
The existing unsupported-SQL list in that file moves its `ReplicatedMergeTree` case to the
accepted list. The embedded example manifests still build.


### Milestone 7: replicated ledger

In `ServerProfile.hs` and `LedgerSchema.hs`, add the replicated ledger expectation. A
replicated target never creates the ledger database: if it is missing, `shape` reports a
new `LedgerError` `LedgerDatabaseMissing`, and if its engine is not `Replicated`, it
reports `InvalidLedgerSchema`. The table DDL is
`CREATE TABLE IF NOT EXISTS <ns>.events (...) ENGINE=ReplicatedMergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'`,
with no Keeper arguments. The shape rule is the structural one from the Decision Log:
`engine = 'ReplicatedMergeTree'`; `engine_full` parses as the engine name, a parenthesised
list of exactly two single-quoted literals (not inspected), then exactly
` ORDER BY sequence SETTINGS fsync_after_insert = 1, fsync_part_directory = 1, storage_policy = 'default', index_granularity = 8192`;
the column list in `create_table_query` is exact; `sorting_key` and `primary_key` are
`sequence`; partition and sampling keys are empty; and `system.replicas` for the table
reports `is_readonly = 0` and `total_replicas` equal to the configured set size. Confirm
the exact spellings against spike question 1 before coding them. Thread the topology
through `shape`, `initialize`, `appendOnce`, `load` and `reconcile` in `LedgerStore.hs`
via the record accessors. Appends use the replicated request settings, so an acknowledged
append is on every configured replica; reads are sequentially consistent. Note that
`ReplicatedMergeTree` deduplicates identical inserted blocks by default; because no
outcome is ever replayed, this does not change acknowledgement semantics, and the plan
records that it is not relied on. Run `checkLocalStorage` and the `fsync_metadata` check
through every replica if spike question 5 found a read-only all-replicas query the login
may run; otherwise run them on each newly admitted replica, which still covers every
replica that is ever written through. Document whichever applies in
`docs/user/contracts/ledger-v1.md`, in a new "Replicated ledgers" section (with a
`docs/user/log.md` entry); the v1 event encoding itself is unchanged. Add
`LedgerDatabaseMissing` to `docs/user/error-codes.md` and both renderers.

At the end, `just test-ledger` passes unchanged for direct targets. The `replicated` group
shows initialization in a pre-existing `Replicated` database, appends visible on both
replicas through direct per-replica reads, a rejected `Atomic` or missing ledger database,
rejected wrong engine text, and acknowledged history intact after SIGKILL and restart of
each replica in turn. It also shows that an append while one replica is stopped returns a
complete server error within the request deadline, is recorded as failed or uncertain
exactly as ADR 0005's outcomes require, and is never reported as acknowledged.


### Milestone 8: end-to-end qualification, documentation and release

Add a replicated variant of `examples/two-components`, with migrations using
`ReplicatedMergeTree` and `ReplicatedReplacingMergeTree(ver)` against `fixture_app`. Add
`just test-replicated`, which runs the `replicated` integration group and then drives the
mounted CLI through the round-robin endpoint: `up`, `status --json`, `history --json`,
`verify`. Re-running `up` must be a no-op. Stopping one replica must make `up` of a new
migration exit non-zero within the request deadline with the step recorded as failed with
possible effects or as uncertain, never as succeeded; after the replica returns (and the
Keeper log has applied the DDL there), the existing recovery path resolves it. A
plain-`MergeTree` migration must fail with the server's Code 56 reported as an observed
server failure. Add `replicated` to the Altinity entry's `groups` in the matrix (not to the
native entry), so `just test-release-matrix` runs it for the container candidate only.

Write ADR `docs/adr/0015-qualify-replicated-targets-by-replica-set-and-quorum.md` recording
the topology, policy, output mode, timeout, checksum version, envelope and ledger
decisions, and the centralized server profile from Milestone 2. Update ADR 0005 and ADR
0014 to point to it. Rewrite the topology paragraph of `docs/user/compatibility.md`: the
supported operation becomes one directly addressed server, or one replicated cluster with
an exact replica set, Keeper-backed `Replicated` databases and the replicated policy.
Arbitrary cloud proxies, multi-shard clusters, `Distributed` tables and SQL rewriting stay
excluded, and owned fixture evidence is not managed-cloud certification. Update
`docs/user/operations.md` and `docs/user/authoring.md` with how to configure a replicated
target and author replicated migrations, and `docs/user/contracts/json-v1.md` with the
additive `status` and `history` fields (recorded `checksumFormat`, admitted replica). Add
`docs/user/log.md` entries for every touched document and run `just check-docs`. Bump the
minor version of all four packages (for example to `0.1.1.0`); the API change is additive.


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
git ls-remote --tags https://github.com/Altinity/ClickHouse 'v26.3.60.10002-1.altinitystable*'
docker --context "$CLICKHOUSE_MIGRATE_DOCKER_CONTEXT" buildx imagetools inspect \
  docker.io/altinity/clickhouse-server:26.3.60.10002.altinitystable
docker --context "$CLICKHOUSE_MIGRATE_DOCKER_CONTEXT" pull \
  docker.io/altinity/clickhouse-server@sha256:<arm64-manifest-digest>
nix develop --builders '' -c just test-release-matrix
```

Expect every candidate, including the new `altinity-linux-arm64-10002` entry, to report all
thirteen groups passing for both artifact variants, with no skipped candidate.

For Milestone 2, prove the refactor is a no-op and the tooling works:

```bash
just test-unit
just check-public-invariants
python3 scripts/check-candidate-policy.py
python3 scripts/qualify-candidate.py --tag v26.3.60.10002-1.altinitystable \
  --repo https://github.com/Altinity/ClickHouse \
  --image docker.io/altinity/clickhouse-server:26.3.60.10002.altinitystable
just test-transport && just test-completion-policy && just test-ledger
```

Expect `check-candidate-policy.py` to print the agreed version set and exit 0, and
`qualify-candidate.py` to print a JSON entry whose `version`, `tag`, `commit` and `image`
equal the matrix's 10002 entry.

For Milestone 3, run the spike after adding the replicated fixture:

```bash
python3 scripts/replicated-spike.py --report docs/release-evidence/<date>-replicated-spike.json
```

Expect a JSON document with one object per numbered question, each holding the exact
statement, the replica it ran on, the request settings, and the observed HTTP status, body
or error code. A Code 56 refusal looks like this:

```text
{"question": 6, "case": "plain-mergetree", "replica": "r1", "error": {"code": 56}}
```

For Milestones 4–7, iterate with the unit suite and the new group (the `replicated` group
needs no private driver):

```bash
just test-unit
cabal test clickhouse-migrate-integration -fintegration --test-show-details=direct --test-options=replicated
just test-transport && just test-ledger && just test-runner
```

When adding a user document, allocate its handle and validate the bundle:

```bash
okf id next docs/user --profile mori/user-documentation-profile.dhall DOC
just check-docs
```

For Milestone 8:

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

Milestone 2 is accepted when `just check` passes with the drift check in place, removing a
version from `supportedVersions` makes the drift check fail by name, the direct-target byte
pins pass, the transport, completion and ledger groups pass unchanged, and
`qualify-candidate.py` reproduces the 10002 matrix entry.

The replicated work is accepted when `just test-replicated` passes on the two-replica
fixture and shows all of the following:

- Through an endpoint that alternates replicas per connection, `up` applies the replicated
  example. `status --json` reports every migration applied with `checksumFormat` `sha256-v2`,
  and `verify` succeeds.
- Querying each replica directly for `fixture_app` tables and for `fixture_ledger.events`
  returns identical rows.
- With one replica stopped, `up` of a new migration exits non-zero within the request
  deadline, the step is recorded as failed with possible effects or as uncertain and never
  as succeeded, and after the replica returns the existing recovery path resolves it.
- A plain `MergeTree` migration fails with the server's Code 56, reported as an observed
  server failure.
- A mismatched configured replica count, shard count or connected server UUID is
  rejected before application or ledger bytes. With restricted-login membership,
  UUIDs of unvisited replicas are operator-verified inventory; local counts cannot
  attest them. This is the fallback specified in Milestone 4, not a cluster-wide
  UUID attestation.

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
recipe is safe. `qualify-candidate.py` writes nothing without `--write`, and with it only
appends a matrix entry whose `id` is not already present.

Milestone 1 only adds an allowlist entry and evidence; reverting the commit restores the
previous behaviour. Milestone 2 is a refactor whose direct-target bytes are pinned by unit
tests and by the unchanged transport, completion and ledger groups; reverting it is a
single commit. Milestones 4–7 are additive behind the replicated topology. Direct targets
keep their exact request bytes, checksums and ledger shape, which the unchanged suites
prove at every step. If Milestone 3 shows no setting can make acknowledged DDL or inserts
wait for every replica with an empty acknowledged body, stop after Milestone 3, record the
finding, and revisit the topology decision rather than weakening acknowledgement.

No step in this plan touches a shared or managed ClickHouse server. The four questions to
the TAN infrastructure owner are read-only. Dropping and recreating Kansoku's staging
databases is destructive (it loses 5 `analytics` rows and 565 ledger rows). It belongs to
the infrastructure owner, following the procedure used for `notification_hub` in
`mori://tan/tan-app-infrastructure` pull request #173, and only after Kansoku has released a
replicated baseline.


## Interfaces and Dependencies

New or changed public interfaces in `clickhouse-migrate`:

- In `ClickHouseMigrate.Target`: `TargetTopology` (with `DirectServer` and
  `ReplicatedCluster` patterns), `configuredTopology`, `ClusterName`, `clusterName`,
  `replicatedTargetConfig`, and the `TargetError` constructor `DuplicateReplica`.
- In `ClickHouseMigrate.Plan`: `ChecksumV2` and the name `sha256-v2`, plus
  `stepChecksumFor` and `migrationChecksumFor` taking a `ChecksumFormat`.
- In `ClickHouseMigrate.Report`: the `RunError` constructor
  `DatabaseCreationOnReplicatedTarget !StepReference`.
- New error codes `ReplicaSetMismatch` (transport), `LedgerDatabaseMissing` (ledger) and
  `DatabaseCreationOnReplicatedTarget` (run). Each must be documented in
  `docs/user/error-codes.md` and rendered by `clickhouse-migrate-cli/src/ClickHouseMigrate/CLI/Render/Json.hs`
  and `.../Render/Text.hs`.
- `clickhouse-migrate-cli` does not parse target configuration. The mounting application
  builds `TargetConfig` (Kansoku does so in
  `kansoku-server/src/Kansoku/ClickHouseMigration/Config.hs`), so the CLI needs only the
  new error renderings and the additive JSON fields: `checksums` and `checksumFormats` on
  `plan`, and the recorded `checksumFormat` and admitted replica on `status` and `history`.
  Record all of them in `json-v1.md` as additive fields.

New repository tooling: `scripts/check-candidate-policy.py` (run by
`just check-public-invariants`), `scripts/qualify-candidate.py`, `scripts/replicated-spike.py`,
the `groups` field on every matrix entry, and the `just test-replicated` recipe.

The external pins stay the same: `http-client` 0.7.19 (ADR 0005) and the exact images in
`clickhouse-migrate-test-support/test/data/clickhouse-matrix.json`.

Downstream work owned elsewhere depends on the releases from this plan:

- `mori://shinzui/kansoku` pins `clickhouse-migrate ==0.1.0.1` through a
  `source-repository-package` at `00afa9fa1038f2b90e7bc5f041ac1b56649b639f` in
  `cabal.project`. It needs the Milestone 1 release (`0.1.0.2`) to unblock its staging
  rollout and the Milestone 8 release for production. For production it must author a
  replicated migration baseline with `Replicated*MergeTree` engines, drop
  `CREATE DATABASE IF NOT EXISTS analytics` from its replicated path, and configure the
  replicated target with the cluster name and replica UUIDs.
- The Kansoku migration Job (`pulumi/apps/kansoku/migrate-clickhouse.sh` in
  `mori://tan/tan-app-infrastructure`) should run `status --json` before
  `maintenance begin`, so an admission refusal such as `unsupported-server` is reported
  before traffic is fenced. This is a recommendation from this plan, not a library change.
- `mori://tan/tan-app-infrastructure` must recreate Kansoku's staging databases as
  `Replicated` (removing `existingAtomicDatabases` in `pulumi/apps/kansoku/bootstrap.ts`),
  choose the ClickHouse cluster by environment, and add `stacks/kansoku/production.yaml`.
  Production stays blocked until the staging run in Validation and Acceptance passes.
- The TAN infrastructure owner answers the four read-only questions in Milestone 3
  (per-replica host names, `default_replica_path` and `default_replica_name`, the
  application login's `clusterAllReplicas` grant, and the `default` storage policy's disks).
