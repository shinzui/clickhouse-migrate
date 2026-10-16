# Checksum format v1

The public format name is `sha256-v1`. Unknown format names fail validation.
All hashes are SHA-256, exposed as exactly 64 lowercase hex characters. Validated
definitions never accept a supplied checksum. Authoring migrations are unbound;
component binding determines executable step/migration identity. Read-only bound
views expose the resulting checksums, metadata, dependencies and exact SQL bytes.
There are no Generic/Read/deserialization or writable-optic reconstruction paths.

A field is an unsigned 64-bit big-endian **byte** length followed by those bytes.
A list starts with its unsigned 64-bit big-endian element count; every element
is a field. Names use their validated ASCII (equivalently UTF-8) bytes. SQL uses
exact original bytes, with no trimming, Unicode normalization or newline changes.

The policy field contains these exact ASCII bytes, without newline or NUL:

```text
clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1
```

The step input concatenates the literal ASCII domain `clickhouse-migrate/step`,
a NUL byte, `v1`, a NUL byte, and fields in this order: policy, component name,
migration name, step name, SQL bytes.

The migration input concatenates the literal ASCII domain
`clickhouse-migrate/migration`, a NUL byte, `v1`, a NUL byte, then fields for
policy, component name and migration name, then a list of **complete step
encodings** in caller order. Step encodings include their own domains, policy
and context, and are length-prefixed inside this list. The migration input
contains neither informal separators nor only the step digest bytes.

Descriptions, source paths, timestamps, actor names and runner versions are
excluded. Dependency declarations are a sorted set in the bound component view,
rather than part of individual migration digests. The ledger must compare those
sets and the explicit component/migration sequence independently. Adding a
component before recorded work or changing recorded dependencies cannot be made
compatible merely because the migration digests still match.

The checked-in [24 vectors](../../clickhouse-migrate/test/vectors/checksum-v1.tsv)
publish complete input hex and digest hex, plus all source fields. They cover
step/migration domains, whitespace, each identity, two-step order and changed boundaries with equal concatenated SQL, Unicode SQL,
and ambiguous concatenations (`a`/`bc` versus `ab`/`c`). They were generated once
with Python's independent struct/hashlib reference in
[scripts/checksum-reference.py](../../scripts/checksum-reference.py); Haskell
tests compare its frozen inputs and outputs with both the private encoder and
public component-bound checksums. Test execution does not regenerate expectations.
Description changes and source relocation are separately verified as metadata;
paths are not representable in the checksum encoder's inputs.

The v1 policy is fixed. Changing these bytes, field order, domains, framing or
completion policy requires a new checksum version and explicit migration guidance;
existing ledger history must not be silently rewritten.
