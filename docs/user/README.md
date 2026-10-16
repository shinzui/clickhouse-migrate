---
type: Navigation
title: User documentation
description: Find guides, operational runbooks, compatibility evidence, and versioned interface contracts.
docId: DOC-1
tags: [documentation, guides, contracts, operations]
generated:
  by: process:codex
  at: 2026-10-16T17:47:58Z
---

# User documentation

Start with [authoring and composition](authoring.md), then
[the two-component example](../../examples/two-components/README.md) and
[CLI integration](cli.md) to mount migrations in your application.

- [Operations and recovery](operations.md): target configuration, administrative exclusion, and uncertain work.
- [Legacy adoption](adoption.md): reviewed evidence, complete prefixes, and coordinated cutover.
- [Compatibility](compatibility.md): the exact qualified server artifact and support limits.
- [Error codes](error-codes.md): stable diagnostic families and operator meaning.

Versioned contracts describe [checksums](contracts/checksum-v1.md),
[SQL envelopes](contracts/sql-envelope-v1.md), [manifests](contracts/manifest-v1.md),
[the ledger](contracts/ledger-v1.md), [adoption](contracts/adoption-v1.md), and
[JSON results](contracts/json-v1.md).

The generated `index.md` lists documents by reader intent.
Implementation [plans](../plans/), [ADRs](../adr/),
[the initial specification](../initial-spec.md), [dependency evidence](../dependencies.md),
and [release evidence](../release-evidence.md) live outside this reader-facing bundle.

Documentation follows
`mori://shinzui/okf-profiles/profiles/user-documentation`, pinned to v0.21.0 in
[the shared descriptor](../../mori/user-documentation-profile.dhall).
The bundle is addressed as `mori://shinzui/clickhouse-migrate/okf/user-documentation`;
individual pages use `/concepts/DOC-N` after that URI. Handles remain stable across moves
and title changes. New pages use the next unused number from
`okf id next docs/user DOC --profile mori/user-documentation-profile.dhall`.

Run `just check-docs` with `okf` 0.9.0.0 or later and `dhall` installed. After editing
content, update its generation provenance, run `okf index docs/user --write`, and add a
change entry with `okf log add docs/user -m "Describe the documentation change."`.
Existing page producer names and revision dates were carried from Git authorship and
last-content commits during adoption; the new navigation page records its automation producer.
