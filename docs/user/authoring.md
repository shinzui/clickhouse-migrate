---
type: Guide
title: "Authoring and composing migrations"
description: "Author validated migrations, compose library components, and embed ordered SQL safely."
docId: DOC-3
tags: ["authoring", "composition", "embedding"]
generated:
  by: human:nadeem
  at: 2026-10-16T17:20:17Z
---

# Authoring and composing migrations

A library owns a stable component name, dependency names, ordered migrations and
ordered named SQL steps. Build with `sqlStep`, `sqlMigration`, `migrationComponent`
and `migrationPlan`, checking every `Either`; or embed the same model through a
manifest. Names are validated ASCII identifiers. Arrays/caller order are explicit:
there is no filename sorting, topological reordering or runtime SQL discovery.
Dependencies must exist earlier in the supplied component order. Migration names
are scoped to a component; step names are scoped to a migration.

The [two-component example](../../examples/two-components/README.md) compiles separate
catalog and analytics libraries. Each exports `component :: MigrationComponent`;
the application composes `migrationPlan (Catalog.component :| [Analytics.component])`.
Analytics declares a dependency on catalog. The application may append its own
component after both. Core checks the complete recorded global prefix, including
component order/dependencies, migration identities and all named step checksums.
Changing descriptions is harmless; modifying applied identity/order/SQL is not.
Append a new migration rather than editing an applied one.

Write exactly one qualified local statement per step. A step may contain literal
or comment semicolons; the [SQL envelope](contracts/sql-envelope-v1.md) distinguishes
these from real statement separators. It rejects session/transaction/cluster commands,
unqualified mutation targets, replicated/distributed/remote engines and completion
setting overrides. SQL is otherwise opaque: the library does not infer schema, prove
idempotence or split files at runtime. Use reviewed explicit steps and the server's
actual grammar. A server error can leave partial effects. Avoid encoding secrets in
SQL, descriptions or audit references; only explicit SQL diagnostics expose SQL bytes.

Embedding uses package-relative manifests and compile-time exact byte capture. Include
manifest/SQL in `extra-source-files`, and use the [content-qualified build wrapper](contracts/manifest-v1.md)
with every owning library manifest. This also catches preserved timestamps. Source
distributions must contain every input, and compiled artifacts need no migration
files at runtime. The [checksum contract](contracts/checksum-v1.md) defines versioned
preimages; file paths, descriptions and source layout do not affect them.

## Connection and administrative ownership

Construct a validated target key, direct endpoint, persisted expected server UUID,
ledger namespace, binding, explicit credentials and bounded HTTP limits with
`ClickHouseMigrate.Target`. `FirstUse` is only a binding mode: it grants no initialization
authority. Retain the new UUID before using `authorizeInitialization`; after success
or interruption persist the same identity and use `ExistingLedger` for recurring runs.
Read-only configuration accessors expose target key and binding, never credentials
or a live client. Install only the exact qualified native artifact/platform in
[compatibility](compatibility.md); runtime version text does not attest its digest.

Provide `externallySerialized strategy scope timeout acquire release alive`. Its
acquire excludes all administrators for the entire target. Losing access latches
failure and stops later writes but cannot fence bytes already submitted. Release
must not admit a successor until every prior SQL, ledger INSERT and initialization
DDL has drained. A timeout, closed client socket or empty process/history read does
not establish this. All maintenance/backfills/manual DDL must use the same external
coordination. Follow [operations](operations.md) for diagnosis and recovery.
