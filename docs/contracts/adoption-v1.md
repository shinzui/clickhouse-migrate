# Adoption v1

Adoption accepts a reviewed complete prefix into a fresh native ledger. It never
executes application SQL and never upgrades filename/time history into historical
checksum evidence. Existing native history cannot be spliced into a new batch.
The same interrupted batch may resume with fresh expected state and quiescence;
a committed identical batch is an inspection-only operation, including after
later native migrations. This read-only result makes no claim that an older
supplied executable is current with later native history.

`LegacyRow` contains exact bounded row identity, diagnostic applied-at text, and
an optional checksum actually retained by the predecessor. `SourceChecksum`
currently supports only lowercase `sha256` and a 64-character lowercase hex digest.
Unknown algorithms fail explicitly. Each `AdoptionMapping` names one source row,
one complete native component/migration identity and its bound v1 migration hash.
All rows must be mapped once, in supplied order, onto the complete native prefix.
Duplicate source/native identities, holes, unknown rows, reordering or changed
native definitions fail before initialization. Multiple statements in one source
file are deliberately reviewed as ordered native steps; the library does no SQL
splitting, file discovery or schema inference.

Attested mappings carry external references. Verified mappings additionally supply
historical source bytes whose SHA-256 must equal the checksum stored in that row.
Today's file hash alone cannot establish this. Verified means source-checksum
evidence, not proof that a partially executed predecessor file completed or that
the native steps were observed executing. Current native checksums establish the
reviewed baseline onward. Evidence level and references participate in batch
identity and remain visible in every adopted migration/step.

An opaque AdoptionRequest binds target key, expected absent/exact ledger state,
optional target/UUID initialization authorization, target-bound external quiescence,
audit actor/reason/references, source identity, durable snapshot evidence reference,
complete rows and complete mappings. Preserve a resolvable immutable snapshot
beside its digest; the library validates bytes supplied to it but cannot verify
external evidence retention, coordinator exclusion or an operator's assertion.
Actor/reason, fresh expected state and quiescence may change between administrators
resuming the same batch; they are event audit fields, not batch identity fields.

`planAdoption` performs pure whole-batch validation against the supplied inspection.
Apply/resume revalidate that same batch against the supplied compiled plan and a
fresh complete guarded read before any initialization. Only FirstUse plus explicit
authorization may create/resume compatible empty bootstrap objects. Resume requires
an existing incomplete matching batch and never initializes a missing one. Every
mutating path requires the exact expected position. A matching committed batch is
checked first and performs no append, even with its original stale absence token.
Target/ledger identity still must match. Applying an incomplete batch requires the
explicit resume operation. A different batch cannot replace it.

The immutable ledger records adoption-start, each identifiable complete definition
with evidence, then adoption-complete, acknowledging each before dependent work.
An uncertain append stops with its exact receipt and last acknowledged report.
Ordinary up blocks on an incomplete batch. Before any resume, establish that every
prior application, initialization and ledger request is quiescent, reconcile exact
receipts when available, and obtain a fresh inspection/plan. NotObserved alone is
never permission to resubmit a missing entry. Resume skips acknowledged existing
entries and appends only the matching remainder. No events are deleted or rewritten.

## Digest byte encodings

All hashes use SHA-256, rendered as 64 lowercase hexadecimal characters. `u64(x)`
is unsigned 64-bit big-endian. `field(bytes)` is `u64(byteLength) || bytes`;
`text(value)` is field of exact UTF-8, without normalization. `list(f, values)`
is `u64(count) || concatMap(f, values)`. Row order and reference order are retained.

Snapshot encoding is ASCII `clickhouse-migrate/adoption-snapshot`, NUL, `v1`, NUL,
then text(source identity), text(snapshot evidence reference), and a list of rows.
Each row encodes text(identity), text(applied-at), then u64(0) for no stored
checksum, or u64(1), text(algorithm), text(stored digest) when present.

Mapping encoding is ASCII `clickhouse-migrate/adoption-mapping`, NUL, `v1`, NUL,
then text(snapshot digest) and a list of entries. Each entry contains text(source
row identity), field(canonical definition JSON bytes from ledger v1), u64(0) for
operator attestation or u64(1) for predecessor checksum, then the ordered list of
text evidence references. Persisted references begin with source identity,
snapshot evidence reference and source row identity. Verified entries additionally
retain historical algorithm/digest before caller references.

The definitions digest reuses ledger v1: SHA-256 of canonical JSON containing the
ordered array of full mapped descriptors. It covers positions, dependencies,
identities and step hashes, excluding descriptions. Adoption-complete contains
the mapping digest; projection rechecks the definitions digest and entry count.
The ledger's source field is source identity followed by a newline and
`snapshot-evidence:` plus the evidence reference. This spelling participates in
batch comparison; the snapshot digest independently length-delimits both fields.

Inputs permit at most 1,000 rows/mappings, 2 MiB historical bytes per verified
entry, 64 MiB historical bytes per batch, and 8 MiB caller reference bytes per
batch. Each mapping allows 1–24 caller references, reserving ledger reference
space for source metadata. Source identity/row identity are at most 512 Unicode
characters; applied-at text 256, evidence reference 1,000. These texts are nonblank
and exclude NUL/newline/CR. Every serialized event is validated below a reserved
60 KiB bound before initialization, within the 64 KiB ledger wire limit.

Changing these digest encodings, evidence meanings or ledger transitions requires
an explicit new format and separately tested migration guidance. Never reinterpret
an existing batch identity silently.
