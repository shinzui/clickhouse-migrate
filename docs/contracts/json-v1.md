# CLI command-result JSON v1

`ClickHouseMigrate.CLI.Render.Json.renderJson` returns UTF-8 bytes without a newline.
The application writes exactly one document and chooses its exit policy. The example
adds one newline, writes safe progress to stderr, and exits 0 for success or 1 for a
returned failure. No library prints, reads environment credentials or calls exit.
Async cancellation is rethrown after bounded cleanup; interruption/termination does
not guarantee a final document. A missing document never proves non-submission.

Every result has all five fields:

```json
{"schemaVersion":1,"command":"plan","status":"ok","result":{"kind":"plan","checksumFormat":"sha256-v1","completionPolicy":"clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1","components":[]},"error":null}
```

The empty components above illustrate the envelope only: a valid compiled plan is
nonempty. Commands are `plan`, `status`, `history`, `verify`, `up`, `repair.resume`,
`repair.retry-step`, `repair.accept-step`, `repair.finalize`, `adopt.plan`,
`adopt.apply`, `adopt.resume`. An application's rejected parser input may use `parse`.
Status is exactly `ok` or `error`; success has a non-null result and null error;
failure has null result and a non-null error. Output object key order is unspecified.
Arrays retain domain order. All fields listed below are present, including nullable
fields. UUIDs, hashes, position tokens, receipt tokens and query IDs are strings.
Ledger sequence numbers are decimal **strings**, preserving UInt64 precision.
Other indexes/counts are bounded JSON integers. No timestamps are reparsed or
normalized for display. Boolean observations are not claims of schema equality.

The executable reference encoders are `CLI/Render/Json.hs`; frozen independent
fixtures are [malformed](../../clickhouse-migrate-cli/test/golden/malformed.json),
[partial SQL failure](../../clickhouse-migrate-cli/test/golden/partial.json),
[delayed ledger acknowledgement](../../clickhouse-migrate-cli/test/golden/delayed-ledger.json)
and [operator acceptance](../../clickhouse-migrate-cli/test/golden/accepted.json).
They are synthetic display fixtures; native tests separately establish report semantics.
The encoders use exhaustive constructor matches with incomplete patterns as errors.

## Success variants

| `result.kind` | Additional fields |
| --- | --- |
| `plan` | `checksumFormat`, `completionPolicy`, `components` |
| `status` | `report`: inspection |
| `history` | `report`: history |
| `verification` | `compatible`: true, `current`: boolean, `report`: inspection |
| `run` | `report`: run |
| `adoption-plan` | `observation`: history, `batch`: adoption summary, `entries`: ordered `{definition,evidence}` |

A plan component is `{index,name,dependencies,migrations}`. A migration is
`{ordinal,name,description,checksum,steps}`; description is string or null. A step
is `{index,name,checksum}`. Component index, migration ordinal and step index are
zero-based. Ordinals span all components. Names/dependencies and exact bytes determine
checksums; descriptions are advisory. No SQL bodies or file paths are rendered.

A definition is `{ordinal,componentIndex,component,dependencies,migration,checksum,steps}`;
its steps are `{name,checksum}`. A step reference is
`{component,migration,step,migrationChecksum,stepChecksum}`.

A migration summary is `{definition,state,attempt,steps}`. Migration state is
`pending`, `in-progress`, `failed`, `applied`, `adopted` or `invalid`.
A step summary is `{name,checksum,state,attempt,evidence}`; step state is `pending`,
`uncertain`, `observed-success`, `observed-failure` or `accepted`. Attempt/evidence
are nullable. A selected step attempt is `{ownerAttempt,step,queryId}`. Its owner
can differ from the current migration attempt following recovery authorization.
An accepted step is explicitly weaker than observed success. Evidence is
`{level,references}`, where level is `operator-attestation` or
`predecessor-checksum`; the latter verifies retained predecessor bytes against an
actually stored source checksum, never a hash of today's compiled definitions.

History is `{target,server,ledger,position,access,events,migrations,unresolved}`.
Server is null or `{serverId,version,hostName}`. Ledger is `{kind}` for `unknown`,
`missing`, `uninitialized`, or `{kind:"initialized",ledgerId}`. Position is null or
an opaque `chm1:` token. Access is `{mode:"unguarded-observation"}` or
`{mode:"guarded-observation",provider:{strategy,scope}}`. Inspection is
`{observation,migrations,issues}`; it compares the compiled full prefix. Issues are
`{code:"definition-changed",index,expected,actual}` (nullable definitions),
`{code:"unresolved-attempt",attempt}` or `{code:"incomplete-adoption",batch}`.
An unguarded observation can race another administrator.

Run is `{runId,target,access,acquired,history,migrations,observations,initializedLedgerId}`.
Here access is the provider description `{strategy,scope}`; acquired is boolean.
Observations are `{step,queryId,evidence}`: evidence is
`{outcome:"acknowledged-success"}` or `{outcome,transport}` with outcome one of
`positive-non-submission`, `observed-server-failure`, `submission-uncertain`.
Local SQL acknowledgement and a durable step completion are separate evidence.
InitializedLedgerId is nullable; retain it along with the original authorization
UUID even if initialization was interrupted.

## Immutable history events

Each event is `{sequence,eventId,ledgerId,runId,attempt,occurredAt,audit,runnerVersion,context,kind,body}`.
Audit is `{actor,reason,references}`. Context is null or
`{component,migration,checksum,step}`, with step null or `{name,checksum}`.
The ledger contract defines the actual immutable versioned event bytes; this is
its safe display projection, not an append/import API.

| kind | body |
| --- | --- |
| `initialized` | `{target}` |
| `migration-started` | `{definition}` |
| `step-started`, `step-succeeded` | `{step,queryId}` (step index) |
| `execution-failed` | `{step,queryId,code,httpStatus,serverCode}` (nullable step/query/httpStatus/serverCode; code is a string) |
| `migration-completed` | `{}` |
| `recovery-authorized` | `{action,expected,previousAttempt,nextAttempt,target,quiescence}` |
| `step-accepted` | `{step,evidence}` |
| `adoption-started` | adoption summary |
| `adoption-entry` | `{definition,evidence}` |
| `adoption-completed` | `{mappingDigest}` |

Recovery action is `{kind:"resume"}`, `{kind:"finalize"}`, or
`{kind:"retry-step"|"accept-step",step}`. Quiescence is an audit assertion, not
independently established fencing. Adoption summary is
`{source,snapshotDigest,mappingDigest,definitionsDigest,count}`.

## Failure envelope

Error is `{category,primary,secondary,report}`. Category is `command`, `run`,
`inspection` or `adoption`. Primary always has a stable `code`; see
[error codes](../error-codes.md). Command errors have only code. An adoption planner
rejection retains its observed history in report. Run failure retains the full run
report, including the latest acknowledged durable position and local observations;
inspection failure retains history or null if none was safely obtained. Neither
failure nor cleanup invalidates or erases completed work.

Primary detail fields by family:

- invalid runtime plan, ledger namespace in SQL: `step`; oversized definition: `definition`.
- target failure: `transport`; ledger request failure: `evidence,transport,pendingAppend`.
- initialization failure: `ledgerId,stage,queryId,evidence,transport`.
- SQL failure: `step,queryId,evidence,transport`; callback failure: `callback`.
- incompatible history: `issues`; stale position/attempt mismatch: `expected,actual`.
- step attempt mismatch: `stepAttempt`; repair not allowed: `reason`; active prior queries: `queryIds`.
- all other primary errors carry code only.

Transport is `{code,httpStatus,serverCode}` with nullable numeric status fields.
PendingAppend is null or the exact `chm-receipt1:` token including the INSERT query
identity. Preserve it; reconciliation is read-only, and `NotObserved` is never replay
permission. A server error is still possible partial effects.

Secondary entries are `{kind:"recording",error}` (another primary-shaped error),
`{kind:"observer",callback}`, `{kind:"transport-cleanup",error}` (transport), or
`{kind:"access-cleanup",code}`. Callback is `{kind:"event",phase}` or
`{kind:"sql-diagnostic"}`. Secondary failures never replace the primary cause.

There are no raw SQL bodies, credentials, arbitrary exception strings, HTTP bodies,
connection URLs or environment values in normal output. Audit/source/evidence text
is intentionally retained as supplied; callers must not put secrets in those fields.
Raw authored SQL requires an explicitly configured diagnostic sink and is never
added to the JSON encoder. Text errors include this same safe complete failure JSON.

## Version and upgrade policy

Version 1 is the frozen field/tag/evidence contract above. Changing/removing fields,
their types or meanings, or silently treating a new domain state as an existing state
requires a new schema version and golden fixtures. A new command/error code must be
documented and tested explicitly; consumers should fail safely on unknown codes and
never infer recovery authorization from them. Checksums, ledger, adoption input and
CLI result versions evolve independently. No JSON decoder can construct core runtime
capabilities, validated definitions or writable ledger events.
