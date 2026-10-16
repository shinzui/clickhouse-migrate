---
type: Reference
title: "Manifest format v1 and qualified embedding builds"
description: "Look up the manifest v1 format, path containment, and qualified embedding build procedure."
docId: DOC-10
tags: ["contracts", "manifests", "embedding"]
generated:
  by: human:nadeem
  at: 2026-10-16T12:00:55Z
---

# Manifest format v1 and qualified embedding builds

`ClickHouseMigrate.Embed.embedComponent` is a Template Haskell splice taking a
package-relative manifest path and producing a `MigrationComponent`. The compiler
provides the owning package root (GHC 9.12 uses its working directory setting).
The manifest and all SQL are read only during compilation; generated code calls
the public core constructors, including description construction, and has a bounded
invariant-error branch. There is no unchecked public constructor or Lift instance.

```json
{
  "manifestVersion": 1,
  "component": "analytics",
  "dependencies": [],
  "migrations": [{
    "name": "0001-events",
    "description": "Create event storage",
    "steps": [{"name": "create-events", "file": "sql/create-events.sql"}]
  }]
}
```

All shown fields are required except description, which may be absent, null or a
string. No other fields are accepted at any level. Duplicate object keys are
rejected before map construction, including Unicode-escaped equivalent keys.
The version must be the JSON number 1. Names follow the core ASCII grammar;
dependency arrays cannot contain duplicates. Migrations and steps must be nonempty,
with unique names in scope. Array order is execution order; filenames are never
sorted. External dependency existence/order is checked when composing the plan.

SQL file paths resolve relative to the manifest directory. Manifest paths resolve
relative to the compiler's package root. Absolute paths, parent segments, NUL and
backslash separators are rejected. Every path ancestor is canonicalized; a symlink
which leaves the boundary is rejected even if a later link returns inside.
The manifest must stay inside the package root, and every SQL file must stay
inside the canonical manifest directory. Being elsewhere in the package is
insufficient. Internal symlinks are permitted, and both lexical and canonical file
paths become compiler dependencies. Missing files, malformed UTF-8 SQL and invalid
core definitions fail compilation. Diagnostics identify manifest/definition paths
and codes without dumping SQL or raw parser/file diagnostics.

SQL bytes are embedded verbatim. File relocation, JSON whitespace and descriptions
do not change core checksums. SQL whitespace, identity, order and boundaries do.
Compiled artifacts need no source files and do not accept environment-based SQL
replacement.

For timestamp-independent Cabal builds, use the executable shipped by this package:

```bash
clickhouse-migrate-embed-build --input path/to/library migrations/manifest.json -- build all
clickhouse-migrate-embed-build --input path/to/library migrations/manifest.json -- test all
```

Repeat `--input PACKAGE_ROOT MANIFEST` for every manifest owning splices in the
build, including library dependencies. Cabal project/target arguments follow the
command. When developing the tool in this workspace, `cabal run
clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build -- ...` invokes it;
`just build` and `just test-unit` already use it for the fixture manifest.

The tool validates and fingerprints declared manifests, referenced file bytes and
paths before invoking Cabal, then includes the fingerprint in build configuration
and forces the resulting compiler invocation. It never submits SQL. Cabal can
otherwise cache stale contents when modification times are preserved. The raw
Cabal command is therefore not qualified for timestamp-independent embedding;
listing extra-source-files and registering compiler dependencies alone does not
remove this limitation. Consumers must package their manifests and SQL via
extra-source-files and use the declared-input build entry point for this guarantee.

`just test-embedding` compares each incremental qualified Cabal result against a
fresh GHC build, tests manifest/path errors through the public splice, and executes
the result after removing all sources. Its scripts and fixtures live in the embed
source distribution at `test/scripts/` and `test/fixtures/`. Run them from an
extracted workspace containing sibling core/embed source distributions and a
cabal.project naming both. Failed evidence stays in a dedicated directory under
/tmp; the harness edits only disposable copies.
