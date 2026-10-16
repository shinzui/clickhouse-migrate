---
type: Reference
title: "Ledger v1 wire and projection contract"
description: "Look up the immutable ledger schema, event encoding, projection, and append protocol."
docId: DOC-9
tags: ["contracts", "ledger", "recovery"]
generated:
  by: human:nadeem
  at: 2026-10-16T14:21:42Z
---

# Ledger v1 wire and projection contract

The dedicated validated database uses Atomic. Its only table is `events`, a local
MergeTree with these exact ordered columns:

| Column | Type | Meaning |
|---|---|---|
| sequence | UInt64 | Contiguous ledger-global sequence, starting at one |
| event_id | UUID | Client-generated immutable event identity |
| ledger_id | UUID | UUID explicitly authorized at first use |
| event | String | Complete canonical UTF-8 JSON event |

The sorting/primary key is `sequence`; partition and sampling keys are empty.
There are no defaults, TTLs, codecs, projections, constraints, replacing/deduplication
semantics or extra objects. The candidate's normalized CREATE definition is
checked in full. Required table settings are `fsync_after_insert=1` and
`fsync_part_directory=1`, explicit `storage_policy='default'`, with the candidate's default `index_granularity=8192`.
The default policy must contain only healthy writable Local disks, with no
remote flags; selecting an Atomic/MergeTree engine alone does not establish this.
Every request forces `fsync_metadata=1`; metadata preflight verifies it is effective.
Normal inserts use the fixed synchronous completion settings. These checks concern
the documented native process/server-crash model; power loss, disk/controller
failure, backups and independent application/history restores remain unqualified.

The event string is JSON with sorted object keys, compact separators, UTF-8
strings, Aeson's JSON scalar spelling and unsigned decimal integer sequences.
The frozen independent initialized-event vector in
`clickhouse-migrate/test/vectors/ledger-initialized-v1.json` pins the spelling.
All nested object keys are sorted explicitly, independently of KeyMap iteration.
A decode must reproduce the exact original canonical bytes. Duplicate keys,
unknown fields/kinds/versions, alternate whitespace/number spellings, missing fields,
invalid names/UUIDs, malformed UTC times and events over 65,536 bytes fail closed.
The physical sequence/UUID columns must match the JSON envelope exactly.

Each envelope contains exactly `version` (1), `sequence`, `eventId`, `ledgerId`,
`runId`, nullable `attemptId`, diagnostic `occurredAt`, `runnerVersion`, `audit`,
`context`, `kind` and `body`. Audit is `{actor,reason,references}`: nonblank bounded actor and
reason, at most 32 bounded reference strings. Timestamps never order events.
An attempt's later events retain its run identity; explicit recovery creates a new
attempt and may belong to a different run. Query IDs are unique diagnostic request
identities, not replay or uniqueness controls.

Context is null for initialization/batch boundaries. Migration events carry
`{component,migration,checksum,step}`; step is null or `{name,checksum}`. Each
context must exactly match the active immutable definition and affected step,
so individual rows retain stable names and digests as well as attempt links.

The kind/body families are:

| Kind | Body fields and constraints |
|---|---|
| initialized | target, schemaVersion=1, checksumFormat=sha256-v1, exact completion policy; first event, no attempt |
| migration-started | definition; fresh attempt, next global ordinal, no unresolved work |
| step-started | step (zero-based index), queryId; first unresolved, never-started step |
| step-succeeded | step, queryId; must match its recorded intent |
| execution-failed | step, queryId, safe code/httpStatus/serverCode; matches intent; possibly partial effects |
| migration-completed | empty object; all steps resolved by observed success or audited acceptance |
| recovery-authorized | action, nullable step, expected position, previousAttempt, nextAttempt, target, quiescence audit |
| step-accepted | step, evidence; requires matching accept-step authorization |
| adoption-started | source, snapshot digest, mapping digest, definitions digest, positive count; fresh ledger only |
| adoption-entry | definition, evidence; next contiguous batch ordinal |
| adoption-completed | mapping digest; count and complete definitions digest must match |

A definition contains global `ordinal`, `componentIndex`, component name, sorted
unique dependencies, migration name/checksum and ordered `{name,checksum}` steps.
The checksum/policy formats are fixed by initialization. Compare every recorded
definition with the complete supplied plan's prefix, including dependency and order
evidence. A new definition inserted before recorded work is incompatible even if
all old SQL digests match. Descriptions are not identity evidence.

Evidence is `{level,references}`, where level is `operator-attestation` or
`predecessor-checksum`, and references are nonempty and bounded. Accepted completion
remains distinct from observed query success. Adoption entries remain blocking until
the complete batch is recorded. The definitions digest is SHA-256 of the canonical
JSON ordered array of definition objects. Source-specific snapshot/mapping validation
belongs to the adoption API, not to the ordinary execution path.

Fold validated rows in sequence order. Collapse only identical events with the same
sequence and identity; divergent identity/sequence content, gaps, foreign ledgers,
reused query/attempt identities and impossible or contradictory transitions block.
Incomplete migrations and adoption remain blocking regardless of age.

A recovery authorization names the exact current observed position, old and fresh
attempt IDs, target and external quiescence evidence. Resume requires only never-
started steps to remain; retry/accept require the first unresolved started/failed
step; finalize requires all steps resolved. Authorization itself does not let an
ordinary up resume after interruption. Retrying resets only the authorized step
and requires a fresh query ID. Accepting never executes later steps implicitly.

Machine reads force unlimited server result/read sizes, throwing read/result/
timeout/sort overflow modes, and a bounded complete client response. A profile's
partial-result mode must never turn a truncated prefix into valid full history.
Requests explicitly accept identity encoding; advertising gzip with decompression
disabled is insufficient for direct-server metadata reads.

Every append is frozen before its single POST. A full acknowledgement precedes any
dependent operation. Every unsuccessful submitted append, including a complete
server error, stops the store and retains exact identity/sequence/digest and INSERT query ID for later
read-only guarded reconciliation. Present-identical is folded, conflicting blocks,
and not-observed describes only that read. No result automatically reinserts an
event or resumes SQL. Before sequence reuse or bootstrap resumption, the caller's
coordinator must fence predecessor submission and establish that ALL prior requests
(including DDL and ledger INSERTs) have ended. An empty read or released OS lock
cannot establish this.

First-use permission is separately bound to target and ledger UUID; persist that
UUID with interrupted bootstrap evidence. Compatible empty objects can be completed
only with renewed explicit permission and quiescence. Existing-ledger mutation
requires the configured expected UUID; read-only discovery does not grant binding
or initialization authority. Read-only observation never creates objects.

## Complete history reads

History uses one complete JSONEachRow SELECT with server partial-result modes
disabled. The HTTP byte limit bounds each raw row, excluding the LF delimiter
(and including CR in CRLF), rather than the total ledger response. Ordinary metadata
and command responses retain their total-body limit. Default limits and the 16 MiB
configuration cap are unchanged. Full HTTP framing and every row must validate
before any prefix is usable; late errors, oversized rows, corrupt suffixes,
truncation and cancellation stop dependent mutation. Configured deadlines still
apply to the whole request. Decoded events, projections and reports retain all
history, so total retained memory grows with history size.

## Recovery metadata preparation

After validating a fresh guarded position and selected attempt, recovery prepares
its complete authorization and deterministic acceptance/finalization events before
its first append. Size accounting uses canonical UTF-8/JSON bytes, including
repeated accepted references and the separate quiescence audit. Retry and resume
check conservative bounds for generated start, success, failure and completion
metadata; they do not predict SQL results. Required sequence capacity is checked
before authorization. Oversized events return `recovery-event-too-large` with a
safe event role, preserving the original position and attempt. Supply smaller
reviewed evidence in a new explicit request; successful requests retain evidence
verbatim. Once a valid event is submitted, existing uncertainty, receipts and
external quiescence rules still apply.
