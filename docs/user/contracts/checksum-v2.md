---
type: Reference
title: "Checksum format v2"
description: "Reproduce the SHA-256 digests that bind replicated completion policy."
docId: DOC-14
tags: ["contracts", "checksums", "replication"]
generated:
  by: process:codex
  at: 2026-11-07T14:47:03Z
---

# Checksum format v2

`sha256-v2` uses the field lengths, list framing, component/migration/step names,
exact SQL bytes and SHA-256 algorithm of [v1](checksum-v1.md). Its step domain is
`clickhouse-migrate/step\0v2\0`; its migration domain is
`clickhouse-migrate/migration\0v2\0`. Here `\0` denotes one NUL byte. Its policy field
is exactly the following UTF-8 bytes, without a trailing newline:

```text
clickhouse-migrate/replicated-sync-v1;async_insert=0;mutations_sync=2;alter_sync=2;insert_quorum=all;insert_quorum_parallel=0;distributed_ddl_output_mode=none;select_sequential_consistency=1
```

The quorum is the configured full replica count. Server wait bounds limit how long
requests wait; they do not change acknowledgment semantics and are excluded from
the digest. The replica UUIDs, endpoint and ledger namespace are deployment
configuration, also excluded. Migrations are never rewritten for replication.

Binding computes both formats. `stepChecksum` and `migrationChecksum` retain v1;
`stepChecksumFor ChecksumV2` and `migrationChecksumFor ChecksumV2` select v2.
The runner selects the format from the configured topology. An initialized ledger
records the format/policy pair and rejects the other topology's format with
`unsupported-ledger-version`; there is no automatic history conversion.

The independent `scripts/checksum-reference.py --check` verifies all 24 v1 and
24 v2 vectors. The checked-in inputs are identical cases with different domain
and policy bytes. Existing v1 vector bytes remain unchanged.
