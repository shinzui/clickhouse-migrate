---
id: 3
slug: embed-ordered-manifests-with-incremental-rebuild-guarantees
title: "Embed ordered manifests with incremental rebuild guarantees"
kind: exec-plan
created_at: 2026-10-16T04:45:20Z
intention: "intention_01m51gc3zpezra0de7ctcp9r8w"
master_plan: "docs/masterplans/1-bootstrap-the-initial-clickhouse-migration-library.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-16T04:45:20Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T04:57:58Z
      verdict: "changes-requested"
      note: "Remove unchecked embedding bridge and clarify manifest path containment."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T05:03:30Z
      verdict: "approved"
      note: "Revised plan addresses this review; ready for its declared implementation prerequisites and acceptance gates, not runtime qualification."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T05:03:30Z
      mode: "update"
      note: "Require validated generated construction and canonical manifest-tree containment."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T11:41:13Z
      mode: "implement"
      note: "Implement ordered manifest embedding and prove public consumer/incremental rebuild behavior."
---

# Embed ordered manifests with incremental rebuild guarantees

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Libraries can ship a component manifest and SQL files as compiled Haskell values. Changing any relevant source file triggers an incremental rebuild; deployed code works after all source files have been removed.

## Progress


- [x] M1 — 2026-10-16: The compiled component equals ordinary public core construction byte for byte. Pure tests reject JSON ambiguity and verify diagnostic redaction; 13 independent public-splice compile cases reject malformed manifests, missing files and symlink/ancestor escapes.
- [x] M2 — 2026-10-16: Eleven incremental/fresh-build comparisons pass from extracted sibling source distributions, including unchanged inputs, preserved-time/same-size SQL and manifest edits, reference/order changes, formatting and relocation. Source-free execution and all 13 public compile-failure cases pass there too. Workspace tests/builds, warning-free package checks and all six local Nix checks pass on GHC 9.12.4; Linux execution remains deferred.

## Surprises & Discoveries


2026-10-16: The initial real Cabal consumer passed ordinary construction, but a same-size SQL edit preserving its timestamp returned “Up to date” and retained the previous bytes. A fresh GHC splice build differed. Evidence was retained at `/tmp/nix-shell.dCeyqT/clickhouse-migrate-embedding-5dgaw4z0`; the failure is in Cabal’s pre-compiler file monitor, not proof of a GHC content-dependency failure. The owning package now ships a content-qualified Cabal entry point instead of a compiler-only plugin.



## Decision Log


2026-10-16: Preserve timestamp-independent acceptance by shipping `clickhouse-migrate-embed-build`. It validates declared package/manifest inputs, hashes all manifest/SQL bytes and paths, and passes a content token plus force-recomp through Cabal configuration. An unchanged token permits reuse; changed inputs invalidate Cabal before it can skip GHC. Use this command for qualified build/test/haddock paths. Plain Cabal retains timestamp assumptions and is not claimed to satisfy that guarantee. This is the required build compatibility workaround; no compiler plugin or public unchecked bridge is introduced. See `docs/adr/0004-qualify-embedding-builds-by-content.md`.



## Outcomes & Retrospective


2026-10-16: Accepted manifest v1, package/manifest-tree containment, exact-byte public construction and timestamp-independent qualified Cabal builds. The first producer/consumer test exposed a real pre-compiler stale-build path; the package-owned fingerprint preflight preserves the requested guarantee without an ineffective compiler-only plugin. Cabal and Nix test different supported Aeson generations. Source distributions include and pass the same unit, incremental, source-free and compile-failure qualification. The durable boundary is recorded in ADR 0004 and the manifest contract; downstream examples must declare all input manifests to the build entry point.



## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

At creation there was no local ADR corpus. The pre-implementation review added [Preserve uncertainty across runtime boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md): unsuccessful requests never authorize automatic replay, successor mutation requires all prior server work to be quiescent, shared ledger types are defined before runtime consumers, and test access must preserve public invariants. Follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. There is no profiled ADR bundle; preserve the plain Markdown convention. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md` must be Complete. It supplies validated constructors and context-bound checksum views. This slice implements specification section 14. A manifest is ordered JSON naming one component, its dependencies, migrations and named SQL steps. Compile-time embedding uses Template Haskell, the compiler facility that runs code while compiling a module. No local ADR existed initially; consult the prerequisite's checksum/invariant ADRs when present.

Use `mori://shinzui/haskell-jitsurei/docs/core-multiline-strings` only for internal Haskell literals; SQL files are read as exact bytes. Do not apply source indentation processing or newline normalization to them.

## Plan of Work


M1 adds `clickhouse-migrate-embed/src/ClickHouseMigrate/Embed.hs`, `Manifest.hs`, and private manifest/path helpers. Publish `docs/user/contracts/manifest-v1.md` with the exact format in spec section 14, required/optional fields and error paths. Parse JSON in a way that observes duplicate keys before building a map; a normal object decoder that silently keeps one value is insufficient. Reject unknown fields, duplicate keys, wrong versions, missing files and invalid core definitions. Preserve arrays as declared, rather than ordering by filenames. Resolve paths relative to the manifest and enforce package-local containment: reject absolute paths and any parent segment, inspect symlinks, and require every canonical SQL path to remain inside the canonical manifest directory, itself inside the owning package root. Being elsewhere in the same package is not sufficient. Reject symlinked ancestors that escape either boundary; the caller-supplied manifest location must resolve within its package. Test directory symlinks as well as file symlinks. Emit actionable compiler errors containing paths/identities, without dumping SQL.

Expose a compile-time `embedComponent` entry point and register the manifest plus every referenced SQL file with the compiler dependency mechanism. Resolve the supported compiler API through Mori before implementation. Do not assume registration alone proves recompilation correctness. Generated code must reconstruct through public smart constructors and the description combinator, after identical compile-time validation. Emit an explicit case on validation results with a bounded invariant-failure diagnostic for an impossible generated mismatch; never fall back to an empty component or expose an unchecked bridge. Do not derive an unchecked public Lift instance for validated core types. Compile a downstream consumer against the actual exposed modules, since an Internal module name does not make an exposed API private. The embedding package owns any genuinely necessary compiler plugin, and a plugin is accepted only if the incremental harness demonstrates its necessity and correctness.

M2 adds the package-owned `clickhouse-migrate-embed-build` executable as the qualified Cabal entry point, plus `scripts/test-embedding-rebuild.sh` and fixture packages beneath `clickhouse-migrate-embed/test/fixtures/`. Build once with the content-qualified entry point, edit only SQL bytes, rebuild without cleaning, and run the artifact to inspect its checksum and bytes. Independently add/remove/reorder manifest entries without touching the Haskell splice module. Include changes with preserved/coarse timestamps, unchanged file length and package-relative relocation where feasible. Compare each incremental result with a clean build oracle, then hide source SQL and manifests and execute the already-built artifact. Wire the script into `just test-embedding` and CI. Package all needed fixtures via extra-source-files and verify the test from a source distribution.

## Concrete Steps


After adding the harness and suite, run:

```bash
nix develop -c cabal test clickhouse-migrate-embed-test --test-show-details=direct
nix develop -c just test-embedding
nix develop -c cabal sdist clickhouse-migrate-embed
```

The harness must print each source-only change and whether the rebuilt component matches the clean-build checksum. A missed rebuild is a failing exit status, not an expected warning.

## Validation and Acceptance


Prove exact-byte agreement between an embedded component and runtime construction from the same bytes. Relocation and JSON whitespace leave checksums unchanged; SQL whitespace and order changes alter them. Invalid manifests fail compilation, including duplicate JSON keys and symlink escape attempts. Editing only an SQL file, only manifest ordering, or only the referenced-file set rebuilds correctly on GHC 9.12.4 and every other compiler advertised at release. A compiled consumer runs with no source files or environment-based SQL overrides. Do this representative compile/run check before expanding the manifest parser's diagnostics.

## Idempotence and Recovery


The harness operates on disposable copies of fixture packages; never edit the user's source SQL to test recompilation. Keep before/after logs and hashes when a rebuild is missed. Recreate the disposable fixture for the next case, but do not clean between the edits that constitute an incremental case. A compiler plugin may be removed only after the same cases pass without it.

## Interfaces and Dependencies


Consumes Definition/Plan/Checksum from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md`. Owns manifest format v1, `ClickHouseMigrate.Embed` and the incremental-build harness; it may depend on core, JSON parsing, compiler APIs and file utilities, but core must not depend on it. It returns the same MigrationComponent used by ordinary composition. It does not own execution, runtime filesystem discovery or checksum semantics. Any added compiler compatibility workaround requires source and release evidence in `docs/dependencies.md`.

Revision 2026-10-15 — Pre-implementation API/correctness review: Require validated generated construction and canonical manifest-directory containment.

Revision 2026-10-16 — The first consumer check exposed Cabal’s timestamp cache before GHC runs. Ship a content-qualified build entry point and package the harness/fixtures to preserve the original incremental acceptance, including preserved timestamps.
