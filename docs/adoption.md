# Reviewed legacy cutover

Adoption accepts a reviewed baseline without running its application SQL. Start
with the [operations guide](operations.md), [adoption format](contracts/adoption-v1.md)
and [supported target](compatibility.md). Filename/time history always remains
operator-attested. Current-file hashes protect the accepted native baseline onward;
they do not establish which bytes a predecessor executed or whether a partially
executed legacy file completed.

Prepare a separate application change that embeds explicit ordered components,
loads its own target/credentials, integrates target-wide administrative exclusion,
and mounts the reusable command handler. Keep this separate from package publication
or live database execution. Establish required writer/reader maintenance for the
particular DDL and data changes. A migration lock alone does not fence application
traffic. Retire every path invoking the old runner; a second executable with a
different coordination strategy invalidates the exclusion contract.

Before mutation, retain an immutable snapshot of the predecessor ledger, source
revision, exact source files and hashes, step mapping, operator review and known
partial/interrupted work. Use a durable resolvable evidence reference beside its
digest. Map every accepted legacy row exactly once onto the complete native prefix,
in explicit order. Review every statement's qualified objects, engines, nested
writes and response-bound local completion. Do not infer safety from IF NOT EXISTS,
matching filenames, an empty process list or the current schema.

Preserve original historical files as evidence. When native definitions require
reauthoring, record every source/native difference and its reason explicitly.
Review the whole source file as one complete migration; do not silently omit
assertions or incomplete statements. If the original history cannot replay on a
fresh isolated database, record and resolve that consumer prerequisite separately.
Do not edit old evidence to make a test green.

Construct source-neutral LegacyRows and AdoptionMappings through the public
smart constructors. Use attestedMapping for filename/time history. Use verifiedMapping
only when the predecessor actually retained a supported algorithm/digest and
supplied historical bytes match it. Even verified source bytes do not prove that
a legacy file completed. Inspect the complete adoption plan, its exact mapping and
snapshot digests, accepted native checksums and evidence levels before applying.

Establish quiescence of all prior application, initialization and ledger requests
while retaining exclusion. For a missing ledger, generate/retain its UUID and use
explicit target-bound initialization authorization with FirstUse. For an initialized
empty ledger, bind ExistingLedger and its exact observed position. `planAdoption`
is pure; apply revalidates the complete batch and a fresh guarded read before
initialization or adoption writes. A changed/stale request fails without mutation.
Persist the returned ledger UUID and use ExistingLedger for recurring operations.

Apply writes immutable adoption-start, identifiable entries and adoption-complete.
It submits no application SQL. If a request or callback fails, retain the primary
error, last acknowledged report, exact pending receipt and secondary errors.
An incomplete batch blocks ordinary up. Do not retry an unknown append because
one read returns NotObserved: queued requests can arrive later, including after an
empty process-list observation. Establish complete external drain, reconcile exact
receipts read-only when available, inspect again under coordination, rebuild the
same batch with fresh expected position/audit/quiescence, and call resumeAdoption.
A different source snapshot, mapping, accepted definition or evidence strength
cannot replace the interrupted batch. Resume does not initialize a missing batch.

A fully committed identical batch returns only an observation with no additional
writes, even using its original stale absence token or after later native history.
That result does not certify that an older supplied plan is current with newer
native migrations. Verify using the complete current application plan before
returning to ordinary up. Confirm adopted entries still retain their attestation
or historical-checksum evidence. Then execute an explicitly appended native
migration on an isolated existing-history fixture before enabling the new
administrative path. Keep the old runner retired permanently.

## Captured consumer fixture

The immutable source is `mori://shinzui/kansoku` at revision
138d9a316931bbf46781757a29ab6c7fdd90f870, project-relative
`db/clickhouse/migrate.sh` and `db/clickhouse/migrations/` (artifact-level URIs
pending). Its shell runner uses filename order, multiquery execution, and a
filename/applied_at ledger without checksums. The checked-in fixture is
[test/fixtures/kansoku](../clickhouse-migrate-test-support/test/fixtures/kansoku/provenance.json),
containing originals, exact contiguous byte ranges, synthetic legacy rows and
reviewed native manifests. Original files are never rewritten by embedding.

The source has 25 files / 253 statements. The native baseline has 257 steps:
two standalone SELECT assertions are each mapped to explicit Memory-table prepare,
INSERT SELECT of the exact assertion, and cleanup steps. One materialization step
removes its mutations_sync=2 override and uses the immutable qualified local policy.
There is no replica-completion claim. Failed checks stop before cleanup and require
explicit recovery. All three adaptations and source/native hashes are recorded in
provenance. Local Atomic exchanges and replacement views retain their original SQL.

Run `just test-consumer-fixtures` in the native development environment. It checks
capture hashes/ranges, embeds the first real two-statement file and full component,
executes fresh native definitions, independently replays original source ranges,
compares targeted schema metadata observations, adopts the complete filename/time
prefix with zero application submissions, verifies, and runs one appended native
migration. These fixture results do not prove arbitrary schema equality, historical
source verification or a live consumer cutover.

Capture authoring tools require an exact source commit and a new output directory;
they are not build hooks or runtime SQL discovery. `scripts/capture-kansoku-fixture.py`
captures original bytes and proposed boundaries, and
`scripts/review-kansoku-native-assertions.py` records the three explicit native
adaptations before the fixture is frozen. Review new captures independently rather
than overwriting released evidence. Embedded consumer builds use the content-qualified
build wrapper with both manifest inputs declared.

The actual external runner replacement remains a separate change to
`mori://shinzui/kansoku` after the CLI example is accepted. Initiative closure needs
that canonical change reference plus evidence that old entry points are retired,
coordination/maintenance is established, adopted native history verifies, and a
subsequent native migration succeeds. Local fixture success leaves this gate open.
