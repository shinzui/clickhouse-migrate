# clickhouse-migrate Initial Specification

## Status

Initial design specification, 2026-10-15. This document defines the intended
first releasable version; it does not claim that an implementation exists.

`clickhouse-migrate` is a Haskell migration toolkit for applications that own an
explicit, embedded ClickHouse migration plan. Libraries own named components;
applications compose them and provide connection configuration and exclusive
administrative access. The runner executes SQL in order, protects declared
history with checksums, and stops for explicit recovery when execution becomes
uncertain.

The design takes its composition and authoring conventions from
`mori://shinzui/pg-migrate/docs/initial-spec`. ClickHouse execution and ledger
semantics are defined independently. The packages must not require PostgreSQL
or depend on `pg-migrate` merely to reuse its public types.

The key words **must**, **must not**, **should**, and **may** are normative.
Conceptual Haskell signatures describe the intended API, not a verified driver
API. Wire encodings must be frozen and documented before the first release.

## 1. Product requirements

The first release must:

1. Let a Haskell library export its own named migration component.
2. Scope migration names to components and step names to migrations.
3. Support explicit component ordering and declared component dependencies.
4. Embed exact SQL bytes at compile time; deployed execution needs no SQL files.
5. Execute a migration as a non-empty, explicitly ordered list of SQL steps,
   with one statement per step.
6. Detect changes to recorded definitions using versioned SHA-256 checksums.
7. Record intent before SQL and successful completion after SQL, without
   claiming atomicity between those records and the SQL's effects.
8. Block ordinary execution after an interrupted, failed, or uncertain attempt.
9. Provide explicit, audited recovery without automatic SQL replay.
10. Require a caller-provided exclusive-access strategy for every operation
    that changes the ledger or application schema.
11. Provide typed plans, errors, events, reports, inspection, and reusable CLI
    integration without owning application logging or process exit policy.
12. Execute against one pinned ClickHouse server and a non-replicated ledger.
13. Adopt a verified mapping of legacy history without rerunning old SQL or
    presenting missing historical checksums as verified evidence.
14. Keep test infrastructure outside the production dependency closure.

The first practical adoption target is `mori://shinzui/kansoku`. Its existing
filename ledger and administrative SQL provide migration and recovery cases;
their storage format must not become the core model.

## 2. ClickHouse execution constraints

These constraints determine the design:

| Constraint | Required response |
| --- | --- |
| Schema creation is not transactional | Never promise atomic SQL-plus-ledger commit |
| A lost response leaves execution uncertain | Stop and require investigation before replay |
| Some operations launch background work | Define and enforce a local completion policy |
| A MergeTree sorting key is not a unique constraint | Do not use ledger insertion as a lock |
| History writes themselves can have uncertain outcomes | Use identifiable immutable events and fail closed |
| Multiple statements are not one transaction | Checkpoint explicit individual steps |
| Cluster DDL has separate submission and execution states | Exclude cluster execution from v1 |
| A process or client can stop while server work continues | Recovery must establish that prior work is quiescent |

The runner provides ordered execution, recorded evidence, and conservative
recovery. It does **not** provide exactly-once SQL execution, distributed
transactions, automatic rollback, or a proof of live schema equality.

ClickHouse's experimental transaction support is not a prerequisite and must
not be used to weaken these rules.

## 3. Explicit non-goals

Version 1 excludes:

- down migrations and automatic rollback;
- automatic retries, including retries hidden in a transport or proxy;
- automatic repair or automatic recognition of supposedly idempotent SQL;
- arbitrary Haskell or `IO` migration actions;
- runtime filesystem discovery, remote migration sources, and glob ordering;
- automatic SQL generation, schema diffing, or whole-schema snapshot equality;
- a general database-neutral migration framework;
- built-in Keeper, ZooKeeper, or PostgreSQL coordination;
- `ON CLUSTER`, replicated databases, replicated migration ledgers, and
  load-balanced or failover execution across servers;
- asynchronous/background migration scheduling and distributed backfills;
- client commands such as `SOURCE`, `INCLUDE`, or `\i`;
- migrations that manage the runner's own ledger;
- automatic pausing of application readers, writers, or ingestion queues.

`verify` means that the embedded plan and ledger are compatible. It must not be
described as live-schema drift detection. Application maintenance coordination
remains application-owned, including when a migration requires writers to stop.

## 4. Package boundaries and Haskell baseline

The intended package set is:

| Package | Responsibility |
| --- | --- |
| `clickhouse-migrate` | Definitions, pure validation, runner, ledger, inspection, repair, and generic history adoption |
| `clickhouse-migrate-embed` | Compile-time manifest validation and exact-byte embedding |
| `clickhouse-migrate-cli` | Reusable command parser, handlers, text rendering, and versioned JSON rendering |
| `clickhouse-migrate-test-support` | Isolated real-server fixtures, fault injection, and local test coordination |

These are intended new packages, not claims of existing Hackage releases. A
standalone executable that discovers migrations at runtime is not required.
Application-owned executables mount the CLI around their compiled plan.

The implementation must follow
`mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer,
`GHC2024`, shared Cabal settings, postpositive qualified imports, strict record
fields, unprefixed field names, and explicit deriving strategies. Use a
`ClickHouseMigrate.Prelude`; enable `PackageImports` only there. Embedded
multiline Haskell SQL uses `MultilineStrings`.

Validated public values have hidden constructors and structured smart
constructors. Pure validation must not read the environment or perform `IO`.
Runtime library functions must not print, load application configuration, or
exit the process. Optional packages must not enter the core dependency closure.

## 5. Identity and the plan model

The conceptual model is:

```haskell
data MigrationId = MigrationId
  { component :: !ComponentName
  , name :: !MigrationName
  }

data SqlStep = SqlStep
  { name :: !StepName
  , sql :: !ByteString
  }

data Migration = Migration
  { name :: !MigrationName
  , description :: !(Maybe Text)
  , steps :: !(NonEmpty SqlStep)
  , checksum :: !MigrationChecksum
  }

data MigrationComponent = MigrationComponent
  { name :: !ComponentName
  , dependencies :: !(Set ComponentName)
  , migrations :: !(NonEmpty Migration)
  }

newtype MigrationPlan = MigrationPlan (NonEmpty MigrationComponent)
```

All component, migration, and step names must match
`[a-z0-9][a-z0-9_-]{0,127}`. They are case-sensitive stable identifiers, not SQL
identifiers or paths. Descriptions are human metadata and do not affect identity.
Renaming a recorded item is a history change, not a cosmetic edit.

Smart constructors must validate:

- name syntax and uniqueness at the appropriate scope;
- non-empty components, migrations, and step lists;
- valid UTF-8 SQL with no NUL bytes or empty/comment-only statements;
- the supported statement envelope in section 7;
- duplicate components, missing dependencies, self-dependencies, and cycles;
- that every dependency occurs before its dependent in the supplied plan.

The application chooses component order. Validation must not silently
topologically sort it. Each component's migration order and each migration's
step order are exactly the supplied order. Names and timestamps do not imply
ordering. Components are not interleaved, and per-migration dependency edges are
outside v1.

Representative constructors are:

```haskell
sqlStep :: Text -> ByteString -> Either DefinitionError SqlStep

sqlMigration
  :: Text -> NonEmpty SqlStep -> Either DefinitionError Migration

migrationComponent
  :: Text -> Set Text -> NonEmpty Migration
  -> Either DefinitionError MigrationComponent

migrationPlan
  :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
```

There is no `Transactional` mode. Every migration follows the same conservative
execution protocol, regardless of whether a particular statement is atomic
inside ClickHouse.

## 6. Definition checksums and history compatibility

Checksum format v1 must use SHA-256 with domain-separated, unambiguously
length-prefixed binary inputs. Concatenating SQL strings with an informal
separator is prohibited. Public documentation must publish byte-level test
vectors before release.

The encoding must include:

- format/version discriminator;
- component and migration identity;
- ordered step identities and exact SQL bytes;
- the fixed v1 execution/completion policy identifier.

Each step also has its own checksum. A migration checksum covers every step,
including boundaries and order. Descriptions, source paths, timestamps, actor
names, and runner version are excluded. UTF-8 normalization, trimming,
newline conversion, comment removal, and semicolon rewriting are prohibited.

The ledger must preserve component dependency declarations and the accepted
global migration order as well as migration and step checksums. Dependency
changes for a component with recorded history are rejected in v1. Introducing
an independent component before existing applied work is also rejected.

For ordinary execution, the flattened sequence of completed migrations must be
an exact prefix of the declared plan. At most the next migration may contain an
unresolved attempt. New migrations may be appended only when this prefix rule
holds. In particular, extending an earlier component after a later component
has already run can violate the rule; authors must introduce a suitably ordered
new component or make a separately designed history transition.

Unknown recorded components or migrations, changed checksums, missing applied
definitions, reordered history, changed step boundaries, or incompatible
dependency declarations block mutation. There is no permissive
`ignore-unknown` mode in v1. A newer runner must not silently reinterpret an
unknown checksum format.

## 7. SQL steps and completion

### 7.1 Statement envelope

Each step contains one server SQL statement. Authors split multi-statement
scripts into explicit named steps. The runner must not split on semicolons.
Validation must distinguish separators from semicolons inside strings, quoted
identifiers, supported heredoc literals, and comments. One trailing semicolon
and trailing comments may be accepted, while preserving their exact bytes.

V1 supports ordinary local DDL, `INSERT ... SELECT`, and SQL `INSERT ... VALUES`
inside this envelope. Client-side data streams and `INSERT ... FORMAT` payloads
are excluded. The server remains authoritative for SQL syntax and semantics;
the envelope validator is not a general ClickHouse optimizer or safety analyzer.

The validator must reject transaction control, `USE`, session-mutating `SET`,
`ON CLUSTER`, and client directives. SQL must use qualified application object
names. It must not create replicated engines, invoke distributed/remote write
paths, or modify the ledger database. Restrictions that cannot be established
by the envelope lexer are explicit author obligations, documented and covered
by adoption review; the library must not claim full SQL safety validation.

### 7.2 Local completion policy

Every statement executes with an immutable v1 policy that disables asynchronous
inserts and waits for local mutation and ALTER completion. The transport must
apply `async_insert=0`, `mutations_sync=1`, and `alter_sync=1` where supported by
the tested server matrix. A step must not override these settings through a
query-level `SETTINGS` clause; the validator must reject overrides of protected
settings. Runtime configuration cannot weaken the policy.

These settings have operation-specific meanings. They are not a universal
background-work barrier. The supported statement contract requires completion
observable through the query response under this policy. Operations that merely
schedule detached work, such as starting an independent refresh or distributed
delivery job, are outside v1. Unknown or unsupported completion behavior must
fail validation/adoption review rather than be presented as completed work.

A successful step means that the supported statement completed on the pinned
server under this policy. It does not mean all replicas completed, that every
old part was physically removed, or that application correctness was proved.

The runner must fully consume and validate the transport response before
recording success. A timeout, truncated response, cancellation, or disconnect
does not prove that the statement failed or stopped executing.

## 8. Transport and target identity

The first transport is direct HTTP(S), with one statement per request. It keeps
the runner independent of an application's native analytics client. A native
TCP adapter may follow without changing plan, checksum, ledger, or recovery
contracts. Core consumers must not need driver-specific query builder types.

The HTTP implementation should use the maintained libraries owned by
`mori://snoyberg/http-client`, behind an internal transport boundary. No package
bounds or pins are selected by this document. Before choosing them, verify
current Hackage releases and upstream release tags; local corpus versions alone
are not release evidence.

The transport must:

- send SQL in a POST body and credentials outside the query URL;
- validate TLS certificates by default;
- disable redirects, automatic request replay, retry middleware, and endpoint
  failover; dependency retry behavior must be checked in source and fault tests;
- set `wait_end_of_query=1` and inspect the complete response, including
  ClickHouse exception headers and late body errors;
- never treat HTTP 200 alone as success;
- bound response and diagnostic sizes and fail on truncation;
- set an explicit query ID for every application and ledger request;
- return structured transport and ClickHouse error information;
- avoid reliance on temporary tables or persistent session state;
- provide deterministic cleanup of its dedicated client resources.

A run is bound to an explicit target key identifying the administrative server
and ledger database. The target key excludes credentials and is also used by
the exclusive-access strategy. Operators must use the same key for all aliases
of the same target. A recorded ledger UUID binds subsequent operations to the
initialized ledger. Routing to another server or ledger must fail; the library
cannot prove that an arbitrary proxy will preserve server affinity, so such
routing is unsupported.

Connection configuration, credential acquisition, timeout values, and secret
loading remain caller-owned. A timeout is a stop condition, never permission to
replay a request. Diagnostic query IDs help investigation but are not
idempotency keys, locks, or proof of execution outcome.

## 9. Exclusive administrative access

ClickHouse does not provide a PostgreSQL session advisory lock equivalent for
this runner. A `SELECT` followed by an `INSERT`, a MergeTree order key, a row in
`system.processes`, and an HTTP `session_id` must not be used as migration locks.

Every mutating entry point requires an explicit bracketed `ExclusiveAccess`
provider. It must acquire exclusivity before inspecting or initializing mutable
history and retain it through SQL execution, durable outcome recording, and
cleanup. Scope is the complete target, not an individual migration, component,
or database table. A process-local mutex is insufficient when different
processes can administer the target.

The provider is an application integration contract, not a built-in distributed
lock service. V1 must support an application provider backed by externally
serialized administrative execution. The application is responsible for
ensuring that its scheduler, deployment job, or coordinator actually excludes
all other migrators for the entire interval. The library supplies no implicit
no-op provider and the CLI must reject mutation without an explicit strategy.
The selected strategy and its scope must appear in reports.

A local OS file lock may be supplied for development and tests, but must be
labelled host-local. It is valid only when every migrator uses the same host and
lock namespace. PID files and expiring rows are not substitutes for OS locks.

A provider that can lose its lease must notify the runner. The runner then
stops issuing SQL and reports loss of exclusivity. This does not fence an
already submitted ClickHouse query. The provider must prevent a successor from
submitting work until the predecessor and its server queries are quiescent.
An expiring lease alone does not meet that contract. If quiescence cannot be
established, recovery remains blocked.

The runner may check outstanding recorded query IDs in `system.processes` as
additional evidence. An absent query is not proof of success or failure, and
the query log is not a replacement for the ledger. Application traffic fencing
is separate from migrator exclusivity and must be established by the caller
when a particular migration requires it.

## 10. Ledger v1

### 10.1 Storage and initialization

The default ledger database is `chmigrate`, configurable through a validated SQL
identifier. It must be separate from application objects. Fully qualified and
correctly quoted identifiers are mandatory for all internal SQL. Values use
typed parameters or a tested data encoder, never unescaped interpolation.

V1 uses a non-replicated `MergeTree` event table with no TTL, background mutation
protocol, or dependency on `FINAL`, `ReplacingMergeTree`, or eventual deduplication.
The database uses a supported local `Atomic` engine. The table's sorting key
only organizes storage; it is not a uniqueness guarantee.

Initialization runs under exclusive access. It creates the namespace and table,
validates their exact required shape, then writes an initialization event
containing ledger UUID, ledger schema version, target key, and checksum format.
An existing incompatible object is an error, not something to overwrite with
`CREATE IF NOT EXISTS`. A crash after creating compatible empty objects but
before initialization may be resumed under exclusivity. Non-empty events
without valid initialization must fail closed.

Creating a new ledger requires an explicit first-use authorization in run
options (`--initialize-ledger` at the CLI), including the expected target key.
Its absence is an error when no initialized ledger exists. This authorization
must not be a standing deployment default: a missing ledger on a previously
used target can indicate loss or misrouting, and must not silently trigger a
replay of the application plan. Legacy adoption supplies its own explicit
initialization authorization and must not execute pending SQL as a side effect.

V1 does not automatically upgrade an unknown ledger version. Newer versions
must define an explicit, separately tested upgrade protocol.

### 10.2 Immutable events

The event record must preserve at least:

| Field | Meaning |
| --- | --- |
| `sequence` | Contiguous ledger-global sequence allocated under exclusive access |
| `event_id` | Unique client-generated event identity |
| `ledger_id` | Identity of the initialized ledger |
| `run_id`, `attempt_id` | Administrative run and migration attempt identities |
| `kind` | Versioned event discriminator |
| `component`, `migration`, `step` | Relevant stable identities, absent when inapplicable |
| `definition` | Relevant checksums, dependency declaration, and ordering evidence |
| `query_id` | Exact server query identity, when applicable |
| `occurred_at` | UTC diagnostic timestamp; never the ordering authority |
| `actor`, `runner_version` | Administrative identity and implementation version |
| `details` | Versioned bounded payload for errors, recovery evidence, or adoption provenance |

Event kinds must cover initialization, migration start, step start, step
success, observed execution failure, migration completion, recovery, and history
adoption. The physical column and payload schema must be published before
release. Required fields and legal transitions are validated when reading.

History is derived by folding immutable events in sequence order. Existing
rows must not be updated or deleted to make a run appear clean. Repairs and
adoptions are new events. The projection must reject gaps, conflicting sequence
numbers, unknown kinds/versions, invalid identities, contradictory terminal
states, checksum conflicts, or impossible transitions.

Byte-identical duplicate events with the same `event_id` and sequence may be
collapsed defensively. Different content for one identity, or different event
identities for one sequence, is corruption. Runner-generated automatic append
retries remain prohibited. Timestamps and merge order must never choose a winner.

### 10.3 Write acknowledgement and durability

Every event must be submitted synchronously and acknowledged before the runner
proceeds to an operation that depends on it. In particular, application SQL
must never be sent until its step-start event is acknowledged.

If an append outcome is uncertain, the run stops. A later guarded inspection
can determine whether the exact event is present; the original run must not
blindly append another event or continue with SQL. The same rule applies to
initialization, completion, repair, and adoption events.

The ledger's durability settings must make acknowledged intent durable for the
documented failure model. V1 must configure and test synchronous inserts and
supported fsync settings for the ledger, including `fsync_after_insert=1` where
required by the selected server matrix. Startup must reject a configuration
that cannot provide the published guarantees. Power-loss durability must not
be claimed on the basis of process-kill tests alone. Storage loss, manual ledger
tampering, and restoring application data independently of history are outside
the execution guarantee and require reconciliation before further mutation.

## 11. Execution state machine

The derived migration states are:

| State | Meaning | Ordinary `up` behavior |
| --- | --- | --- |
| Pending | No execution/adoption history | Eligible if next in plan |
| In progress | Start recorded without terminal completion | Block; do not infer that the previous runner died |
| Failed | An execution failure was observed | Block; effects may be partial |
| Applied | All steps resolved and migration completion recorded; accepted steps retain their attestation evidence | Verify definition, then skip |
| Adopted | Existing history accepted through audited adoption | Verify accepted definition and provenance, then skip |
| Invalid | Corrupt or incompatible history | Refuse mutation |

An incomplete attempt is blocking regardless of its age. `status` may explain
that it could be interrupted or still active; elapsed time does not authorize
recovery. Step state distinguishes never started, started with uncertain
outcome, and recorded successful completion.

`up` must perform these actions in order:

1. Validate the complete embedded plan without contacting the database.
2. Acquire exclusive access and open the dedicated transport context.
3. Verify supported server version, pinned target, ledger compatibility,
   privileges, and protected execution settings.
4. Initialize an absent ledger, or load and validate the existing ledger.
5. Compare all recorded definitions and order with the complete supplied plan.
   Refuse to execute if any history is unresolved or incompatible.
6. For the next pending migration, append and acknowledge migration start.
7. For each step, append and acknowledge step start with a fresh query ID,
   submit exactly that SQL once, consume its entire result, then append and
   acknowledge step success.
8. After every step has recorded success, append and acknowledge migration
   completion before advancing to another migration.
9. Return a report, close transport resources, and release exclusive access.

Step 4 requires the explicit initialization authorization in section 10.1 when
the ledger is absent. A normal recurring `up` run must fail on an absent ledger.

When SQL returns an error, stop immediately and attempt a bounded failure-event
append only if the transport can safely do so without replaying SQL. Report
both execution and recording errors. Failure to record an error leaves the
durable start event blocking; it must not erase the primary failure.

Cancellation and asynchronous Haskell exceptions require exception-safe resource
cleanup. Mask only the short local bookkeeping regions needed for correctness,
not an unbounded network operation. Preserve cancellation semantics after
best-effort recording. Client shutdown and cancellation requests are not proof
that server work stopped.

### Required crash behavior

| Interruption point | Required later behavior |
| --- | --- |
| Before migration start | Migration is pending |
| After migration start, before first step start | Block; recovery may begin the first step after quiescence checks |
| After step start, before SQL submission | Block conservatively; durable history cannot prove SQL was not sent |
| During SQL or after losing its response | Block; outcome is uncertain |
| After SQL success, before step-success acknowledgement | Block; do not replay automatically |
| After recorded step success | Preserve checkpoint; an unfinished migration still requires recovery |
| After all step successes, before migration completion | Finalize through repair without rerunning SQL |
| After migration completion acknowledgement | Verify and skip on the next run |

## 12. Inspection and verification

The core API must support pure plan inspection plus remote `status`, `verify`,
and `history` operations. Remote reads must not create a database or ledger.
An absent ledger is reported explicitly; it is compatible with an unapplied
plan, not evidence that a previously used target is safe to initialize.

Read-only inspection may operate without exclusive access, but its report must
identify that fact and describe the result as an observation. It should read
the event log in one query. A command requiring a stable administrative decision
must acquire the same exclusive-access strategy and revalidate inside it.

Reports preserve migration and step identities, checksums, attempt/query IDs,
execution timestamps, current states, order mismatches, and adoption evidence
level. No command may change applied checksums to match the executable.

`verify` succeeds only when the ledger is valid, all recorded definitions form
a compatible prefix, and no attempt is unresolved. Pending migrations alone
are compatible; the CLI must expose a separate `--require-current` check that
also fails when pending work exists. Help must distinguish these meanings.

## 13. Explicit recovery

Recovery uses the original embedded plan, exclusive access, exact expected
ledger position and attempt identity, a non-empty actor, a reason, and external
evidence. A stale repair request must fail before changing history or SQL.
Ordinary `up` never invokes repair implicitly.

The v1 operations are:

| Operation | Preconditions and effect |
| --- | --- |
| `resume` | No uncertain step remains; continue at the first never-started step, retaining recorded checkpoints |
| `retry-step` | Operator has established quiescence and made the uncertain/failed step safe to execute again; record authorization, then create a new step attempt with a new query ID |
| `accept-step` | Operator has independently established the intended step effects; record that attestation and resolve the step without executing SQL |
| `finalize` | Every step is successfully completed or explicitly accepted; append migration completion without executing SQL |

A resumed or retried attempt must reference the attempt it supersedes. Steps
already completed are not replayed. Continuing later steps is a separately
visible action: `accept-step` does not silently run the rest of a migration.
Neither repair nor manual compensation may modify an applied definition's
checksum. Retrying different SQL requires a new, separately designed recovery
mechanism and is outside v1.

Recovery authorization is itself a durable event and is acknowledged before
any authorized SQL. A crash after authorization but before a new step-start
event remains blocking and requires a fresh expected-state repair request;
authorization is not a standing instruction for ordinary `up`. If a repair
append has an uncertain outcome, inspect the exact event under exclusive access
before deciding what remains. Never rerun a repair command blindly.

Recovery audit payloads must record actor, reason, expected state, affected step,
old and new attempt identities, evidence references, and the fact that an
operator attested safety/completion. Preserve the distinction between observed
query success and accepted completion in status and JSON reports.

If the original operation may still be running, repair must refuse execution
until the caller establishes quiescence. A user request to retry is not, by
itself, evidence that the prior server query has stopped. The CLI must require
an explicit quiescence acknowledgement and evidence text for uncertain work;
the API must require the equivalent typed assertion.

## 14. Compile-time manifest and embedding

Manifest format v1 must be an explicitly ordered UTF-8 document. A JSON
representation is sufficient; the exact schema is a versioned public contract.
A representative component manifest is:

```json
{
  "manifestVersion": 1,
  "component": "analytics",
  "dependencies": [],
  "migrations": [
    {
      "name": "0001-events",
      "description": "Create event storage and its reader view",
      "steps": [
        { "name": "create-events", "file": "0001/create-events.sql" },
        { "name": "create-reader", "file": "0001/create-reader.sql" }
      ]
    }
  ]
}
```

Paths resolve relative to the manifest, are package-local, and must not escape
the manifest tree through `..`, absolute paths, or symlinks. Duplicate keys,
unknown fields, missing files, duplicate identities, and invalid versions are
errors. Every referenced SQL file must satisfy the step envelope.

Embedding must register the manifest and every referenced SQL file as compiler
dependencies. Adding/removing/reordering an entry or changing SQL must reliably
recompile the generated value, including on GHC 9.12. The integration suite must
prove this through incremental rebuilds, not just clean builds. Any necessary
compiler plugin belongs to the embedding package and must be documented.

SQL is embedded verbatim. Manifest formatting and file relocation do not alter
the checksum when logical definitions and SQL bytes are unchanged. Runtime code
must not reopen the source tree or use environment variables to replace SQL.

## 15. Generic history adoption and the first consumer

History adoption is optional execution functionality with a source-neutral
model. Source-specific readers belong in adapters or consumer integration code,
not in the ordinary runner path. A maintained predecessor adapter is not
required merely to ship the core package.

An adoption request maps an explicit complete prefix of legacy migrations onto
the native plan and includes source identity, a bounded source snapshot or its
digest, mapping digest, actor, reason, and per-entry evidence level. Unknown
source rows, duplicate mappings, holes, incompatible order, and conflicting
existing native history must fail before appending adoption history.

V1 adoption into a fresh ledger must prevalidate the complete batch, append and
acknowledge one adoption-start event containing its digest, append identifiable
entry events, and finally append adoption-complete. Until completion is
recorded, ordinary migration execution is blocked. An interrupted adoption may
be explicitly resumed only against exactly the same source snapshot, mapping,
and embedded definitions. It must not execute application SQL, and it must not
silently delete partial evidence. A committed identical request is an idempotent
inspection result; a conflicting request fails.

The first consumer is `mori://shinzui/kansoku`. Its legacy runner is the
project-relative `db/clickhouse/migrate.sh`, and its ledger records filenames
and applied times without SQL checksums. Artifact-level URI coverage for this
script is pending; the canonical project URI and path identify it together.

Adoption must therefore distinguish:

- **Source-checksum verified:** a predecessor stored a checksum with a documented
  algorithm, and the relevant historical bytes match it.
- **Operator-attested:** a predecessor only recorded names; an operator accepts
  a reviewed mapping and the embedded definitions as the future baseline.

Kansoku's filename-only evidence falls into the second category. Computing a
SHA-256 over today's file does not prove what ran historically. The native
checksum protects the accepted definition from adoption onward, and reports
must retain this evidence limitation.

Splitting a legacy multi-statement file into native steps changes definition
boundaries. An explicit mapping must associate the old file with the complete
native migration and attest that all its effects are present. Neither a
filename row nor apparently idempotent SQL proves that a previously interrupted
legacy script completed.

The adoption procedure must document stopping the old runner, establishing
exclusive access and any required application maintenance window, reviewing the
mapping, adopting history, verifying the native ledger, and switching the
administrative executable. The old ledger should remain available as evidence.
Keeping both migration runners operational is unsupported.

## 16. CLI and application integration

The CLI package provides reusable `optparse-applicative` integration. It receives
the compiled plan, caller configuration, exclusive-access provider, event sink,
and command policy. The core runner must not read environment variables on the
CLI's behalf or choose application exit policy.

Required commands are:

- `plan`: render the embedded order and checksums offline;
- `status`: inspect pending, completed, adopted, and unresolved work;
- `history`: inspect attempts, query IDs, repairs, and adoption provenance;
- `verify [--require-current]`: check compatibility, optionally requiring no pending work;
- `up`: execute the entire pending suffix after guarded validation;
- `repair resume|retry-step|accept-step|finalize`: explicit recovery operations;
- `adopt plan|apply|resume`: review and apply an explicit history mapping.

All remote mutation commands require an exclusive-access strategy. Repair and
adoption require explicit expected-state and audit fields. The CLI must provide
reviewable text/JSON output for adoption planning before application. A generic
`force VERSION`, `mark-clean`, `reset`, or checksum-rewrite command is prohibited.

First-time `up --initialize-ledger` additionally authorizes initialization for
the supplied target key; normal recurring deployment commands omit this flag.

JSON output has `schemaVersion: 1` and stable machine-readable status/error codes.
Human text is not a machine interface. JSON mode must produce one complete
command-result document on stdout; progress events go to a separate caller
sink. Partial failures must preserve completed work and unresolved identities
in the report. Core functions return values; the consuming executable decides
how to map outcomes to exit codes.

## 17. Errors, events, and observability

Structured errors must distinguish at least:

- definition/manifest/plan errors;
- unsupported server or completion policy;
- connection, authentication, and permission failures;
- target or ledger identity mismatch;
- missing exclusive-access strategy, acquisition timeout, and lease loss;
- incompatible ledger shape/version and corrupt history;
- checksum/order/dependency mismatches and unknown stored definitions;
- blocked existing attempts and active or unquiesced prior work;
- SQL failure, SQL outcome unknown, and ledger append outcome unknown;
- execution failure combined with failure-recording or cleanup errors;
- stale repair request, insufficient recovery evidence, and invalid transitions;
- adoption source/mapping conflicts and incomplete adoption batches.

Errors must include relevant migration, step, attempt, and query identities, plus
safe underlying ClickHouse/transport diagnostics. Callback failures are not SQL
failures. If an event callback throws, the runner stops before further SQL,
preserves durable state, and reports the callback failure; an observational
callback cannot roll back a recorded success. Report cleanup errors alongside
the primary error rather than replacing it.

Events should cover access acquisition, validation, migration/step start and
completion, blocking conditions, repairs, adoption, and cleanup. Emit completion
events only after the corresponding ledger acknowledgement. A callback is not
the authoritative audit trail; the ledger is.

Default renderers must redact credentials and omit SQL bodies and sensitive
query parameters. Error messages may themselves contain SQL or data, so raw
diagnostics require explicit caller opt-in. Reports should expose SQL checksum,
step identity, and server error code without printing potentially sensitive SQL.

## 18. Compatibility and release policy

The first release supports direct, self-managed, single-server ClickHouse with
a local `Atomic` ledger database and non-replicated `MergeTree` ledger table.
ClickHouse Cloud and distributed deployments are outside the v1 support claim.

Before release, the project must publish an explicit server series and patch
matrix, selected from currently supported upstream stable/LTS releases, and
integration-test every claimed series. Verify upstream release tags and current
support policy at that time. Do not infer a minimum server version from an old
local corpus checkout. Unsupported series and prereleases must be rejected
before application mutation; newer untested patches must follow an explicit
documented compatibility policy rather than an implicit guarantee.

Release artifacts must document tested GHC/compiler versions, transport
dependency bounds, protected settings, ledger durability requirements, statement
limitations, exclusive-access assumptions, and the supported failure model.
Public API, ledger, manifest, checksum, and JSON formats have independently
identified versions. Breaking changes require migration guidance; a library
upgrade must not silently rewrite existing history.

## 19. Acceptance criteria

The first release is complete only when these behaviors are demonstrated:

### Pure model and embedding

- Reject invalid names, duplicate identities, empty/comment-only SQL, malformed
  UTF-8, dependency errors, cycles, and invalid explicit ordering.
- Preserve caller order and component-local naming with independent libraries.
- Exercise the SQL envelope with semicolons in strings/comments/heredocs,
  multiple statements, protected-setting overrides, and forbidden commands.
- Publish deterministic checksum vectors, including ambiguous concatenation
  cases, reordered steps, whitespace changes, and excluded descriptions/paths.
- Prove manifest and SQL changes trigger incremental recompilation.

### Real-server execution and fault behavior

- Run a fresh plan and verify that a second run executes no application SQL.
- Refuse a missing ledger on a normal recurring run, and require explicit
  target-bound authorization for first-time initialization.
- Reject modified applied SQL, reordered history, unknown definitions, corrupt
  event sequences, and incompatible ledger schemas before executing more SQL.
- Inject interruption at every boundary in section 11 and prove that no
  uncertain step is automatically replayed.
- Drop the SQL response after the server commits effects; demonstrate blocking
  recovery rather than assuming failure.
- Drop acknowledgements for intent, step success, migration completion, repair,
  and adoption writes; demonstrate conservative reconciliation.
- Test local ALTER/mutation completion and synchronous insert settings on every
  supported server series.
- Demonstrate late HTTP errors, truncated bodies, timeouts, redirects, and
  connection reuse failures cannot produce false success or hidden POST replay.
- Prove the chosen exclusive-access integration prevents two administrators
  from running concurrently, and that loss of access stops further submissions.
- Demonstrate an in-flight query survives client interruption and recovery
  remains blocked until quiescence is established.
- Validate real process/server crash recovery; state separately what storage
  durability has and has not been tested.

### Repair, adoption, and consumer adoption

- Demonstrate every repair operation, rejection of stale requests, retained
  checkpoints, and a repair interrupted during its own audit append.
- Finalize a migration with all successful steps without rerunning SQL.
- Adopt a filename-only source as operator-attested, with no false historical
  checksum claim and no application SQL execution.
- Reject duplicate/holey/conflicting mappings and recover an interrupted
  adoption only with the identical snapshot and mapping.
- Replace the existing runner in a separate change to `mori://shinzui/kansoku`,
  using its real migration history as an adoption acceptance fixture.
- Replay that consumer's fresh plan against an isolated server, then exercise
  adoption and a subsequent new migration against an existing-history fixture.

### Public contracts

- Document plan composition, authoring, CLI integration, target configuration,
  exclusive-access setup, maintenance coordination, recovery, and adoption.
- Provide an executable example using two library-owned components.
- Publish ledger/checksum/manifest/JSON schemas and structured error codes.
- Demonstrate redaction and callback/cleanup failure behavior.
- Confirm test-support tooling is absent from the production package closure.

## 20. Implementation sequencing

Implementation should proceed in these dependency-ordered slices:

1. Pure definitions, ordering validation, SQL envelope, checksums, and fixtures.
2. Manifest embedding with incremental rebuild verification.
3. Direct HTTP transport, pinned-target checks, and fault tests proving no replay.
4. Immutable ledger, exclusive-access boundary, projection, and crash protocol.
5. Runner, inspection, recovery, and versioned reports.
6. Generic adoption and the filename-ledger consumer integration.
7. Reusable CLI, documentation, supported-version matrix, and release checks.

These are implementation boundaries, not a request to extract a shared
framework from `pg-migrate`. Shared pure code may be considered later only when
both implementations demonstrate a stable common contract.

## 21. Evidence and related references

Design conventions:

- `mori://shinzui/pg-migrate/docs/initial-spec`
- `mori://shinzui/pg-migrate/docs/operations`
- `mori://shinzui/haskell-jitsurei/docs/core-standards`
- `mori://shinzui/kansoku` with project-relative `db/clickhouse/migrate.sh`
  and `db/clickhouse/migrations/` (artifact-level URIs pending).
- `mori://snoyberg/http-client/packages/http-client` for transport dependency
  source review; dependency versions remain an implementation-time decision.

ClickHouse behavior checked against official documentation on 2026-10-15:

- [Transactional support](https://clickhouse.com/docs/concepts/features/operations/insert/transactions):
  experimental transaction limitations and nontransactional table creation.
- [HTTP interface](https://clickhouse.com/docs/concepts/features/interfaces/http):
  one-statement requests, response buffering, query IDs, and late errors after
  an HTTP 200 response.
- [ALTER](https://clickhouse.com/docs/reference/statements/alter):
  operation-specific completion and the distinct `alter_sync` and
  `mutations_sync` settings.
- [Distributed DDL](https://clickhouse.com/docs/reference/statements/distributed-ddl):
  per-host queued execution that motivates excluding `ON CLUSTER` from v1.

These documents explain the design constraints. Actual compatibility and
durability claims require the release acceptance evidence in section 19.
