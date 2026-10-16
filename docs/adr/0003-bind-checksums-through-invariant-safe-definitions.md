# Bind checksums through invariant-safe definitions

Status: Accepted

Date: 2026-10-16

## Context

A reusable library authors migrations without knowing the application's component
composition. Persisted identity must nevertheless include component identity,
ordered step boundaries and the fixed completion policy. Public record updates
or Generic reconstruction would let clients invalidate values after validation.

## Decision

Keep standalone SqlStep/Migration/MigrationComponent authoring values abstract.
Use data representations with private constructors, no public Generic/Read or
unchecked deserialization, and read-only accessors. Component binding inside
migrationPlan computes step and migration checksums and exposes immutable view
values. Public description updates apply before binding and do not affect hashes.
Embedding must reconstruct through these same smart constructors.

Freeze [checksum v1](../user/contracts/checksum-v1.md) as domain-separated SHA-256
with unsigned 64-bit big-endian lengths/counts, exact SQL bytes, context identity
and policy. Migration inputs contain ordered complete step encodings. Component
dependency sets and global order remain independently compared descriptors;
matching SQL digests do not establish history compatibility.

The [SQL envelope](../user/contracts/sql-envelope-v1.md) recognizes literal/comment
boundaries, restricts command families and rejects protected setting spellings.
It preserves payload bytes and never claims to prove arbitrary SQL semantics,
ledger isolation, remote-write absence or response-bound completion. Authors
must review those obligations; the transport's server matrix must qualify actual
completion behavior before execution support is claimed.

## Consequences

Independent libraries can reuse local names while binding distinct identities.
The checksum format is reproducible outside Haskell and has checked-in complete
input/digest vectors. Public consumer tests run a composition and reject
representation bypasses; private source tests can exercise encoder boundaries
without exposing them. A change to the policy or byte layout needs a new version
and migration guidance, rather than silent reinterpretation of stored history.
