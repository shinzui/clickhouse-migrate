# Read complete history with bounded rows

Status: Accepted

Date: 2026-10-16

## Context

Valid bounded events can accumulate beyond the ordinary HTTP response limit.
Treating the total response limit as a ledger capacity prevents later inspection
and recovery after successful writes.

## Decision

Use one private streamed JSONEachRow SELECT for complete ledger reads, retaining
the existing decoded Rows boundary. Bound each raw row and incomplete decoder
buffer by the configured byte limit, and retain decoded rows until framed EOF.
Do not return usable prefixes on late server errors, invalid JSON, oversized rows,
truncation or cancellation. Keep server overflow modes throwing, ordinary response
limits, request deadlines, no replay, admission and socket ownership unchanged.

## Consequences

There is no aggregate wire-byte ceiling for valid history. Memory retained by the
projection and reports remains proportional to total history. A single response
preserves the existing observation boundary; pagination would require a separate
snapshot contract and cannot silently omit duplicate conflicts. Keep numeric
sequence sorting and duplicate validation in the projection: a SELECT string alias
can order physical rows lexicographically, so arrival order cannot be folded as
an already-validated numeric prefix. This refines
[ADR 0006](0006-freeze-immutable-ledger-and-explicit-coordination.md).
