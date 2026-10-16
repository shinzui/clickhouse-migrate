# Adopt reviewed prefixes with explicit evidence

Status: Accepted

Date: 2026-10-16

## Context

Legacy filename/time ledgers do not establish historical source bytes or completion
of a partially executed multi-statement file. The new runner must accept a reviewed
baseline without presenting it as observed execution. Initialization itself is a
mutation and must not precede validation of the complete adoption request.

The captured consumer at `mori://shinzui/kansoku`, revision
138d9a316931bbf46781757a29ab6c7fdd90f870, has 25 source files / 253 statements.
Its project-relative `db/clickhouse/migrate.sh` and
`db/clickhouse/migrations/` are the exact source artifacts; file-level URIs are
pending. Two SELECT assertions and one query-level completion override need
explicit native adaptations. Atomic table exchanges and replacement views are
ordinary local DDL that need qualification in the initial conservative allowlist.

## Decision

Freeze [adoption v1](../user/contracts/adoption-v1.md). Require one reviewed complete
mapping onto a native prefix, preserving source snapshot/mapping/definition hashes,
per-entry evidence, exact expected state and external quiescence. Adopt only into
fresh history or resume the identical interrupted batch. Initialization and every
append occur only after complete validation and a fresh guarded observation.
An identical committed batch returns only an observation, bypassing mutation and
stale-position refusal even after newer native history; this does not certify an
older supplied plan compatible/current with that newer history.

Filename/time imports remain operator attestations. Verify historical checksums
only when the predecessor retained a supported algorithm/digest and supplied
historical source bytes match it. Retain source evidence references; a digest
alone is not reviewable history. Do not infer successful predecessor execution
from either source bytes or current schema.

Preserve captured original files and contiguous source ranges byte-for-byte.
Record every native adaptation explicitly beside source/step hashes. Keep SELECT
outside the execution envelope: execute each captured assertion through a named
application Memory table with explicit CREATE, INSERT SELECT of the original
check, and DROP steps. Failed checks stop before cleanup and require explicit
recovery. Remove the single protected mutations_sync=2 override in the reviewed
native materialization step; v1 applies mutations_sync=1 for the qualified local
non-replicated target and claims no replica completion.

Qualify only an exact CREATE OR REPLACE VIEW header and a single EXCHANGE TABLES
pair with both names qualified. All later REPLACE tokens and unsupported table
replacement remain rejected. Preserve the fixed SQL completion-policy/checksum
bytes. The consumer's native baseline has 257 explicit steps; historical filename
rows still attest complete source files rather than these native SQL observations.

## Consequences

The core remains source-neutral and does not depend on embedding, CLI or a legacy
reader. Captured source/synthetic rows and their application adapter live in test
support, with embedding only in its integration component. Fresh native replay and
original-source replay plus adoption must be qualified independently. A source
replay defect remains an explicit consumer prerequisite, never a reason to rewrite
original evidence. The actual external runner replacement remains a separate
initiative gate after the CLI integration example.

Execution order now follows [ADR 0010](0010-separate-component-catalog-from-execution-schedule.md),
which preserves the catalog and immutable global prefix.
