# Separate component catalog from execution schedule

Status: Accepted

Date: 2026-10-16

## Context

Component concatenation cannot append A.two after applied A.one and B.one without
changing the recorded prefix. Library-owned migration order and application-owned
execution order need separate representations.

## Decision

Keep an immutable validated component catalog with stable indices and dependencies.
An optional complete explicit schedule contains every migration exactly once,
preserves each component's authored subsequence and activates dependencies before
dependents. Dependencies constrain first activation; the application orders later
upgrade prerequisites explicitly. The default constructor still concatenates.

Ledger descriptors, execution, reporting, recovery and adoption consume one ordered
schedule. Checksums, event encodings and existing ordinals are unchanged. Retain
the applied schedule verbatim and append new entries; never infer order from the
database. Public identities are built only from validated names.

## Consequences

An application can execute A.one, B.one, A.two without rewriting history. Library
authors must communicate later upgrade requirements; v1 adds no versioned dependency
language. Catalog changes and applied schedule changes still fail compatibility.
CLI reports expose both catalog grouping and the actual schedule. This refines
[ADR 0006](0006-freeze-immutable-ledger-and-explicit-coordination.md),
[ADR 0007](0007-scope-commands-and-preserve-acknowledged-progress.md) and
[ADR 0008](0008-adopt-reviewed-prefixes-with-explicit-evidence.md).
