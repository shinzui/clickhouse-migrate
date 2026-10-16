# clickhouse-migrate-embed

Compile an ordered package-local JSON manifest and exact SQL bytes into a core
`MigrationComponent` with `$(embedComponent "migrations/manifest.json")`.
Enable TemplateHaskell in the caller. Manifest and path validation fail compilation;
generated code uses public core constructors and never reopens source at runtime.

Use the shipped content-qualified build entry point for timestamp-independent
Cabal builds, declaring every manifest containing splices:

```bash
clickhouse-migrate-embed-build --input path/to/package migrations/manifest.json -- build all
```

The command also accepts `test` and `haddock`, with ordinary Cabal arguments after
the command. This preflight is needed because raw Cabal can skip GHC for preserved
modification times. The public splice still registers all compiler dependencies.

The workspace's `docs/contracts/manifest-v1.md` defines fields, containment and
build guarantees. The source distribution includes fixtures and qualification
scripts in `test/fixtures/` and `test/scripts/`; these expect sibling core/embed
sources with a cabal.project naming both. No compiler plugin is required.
