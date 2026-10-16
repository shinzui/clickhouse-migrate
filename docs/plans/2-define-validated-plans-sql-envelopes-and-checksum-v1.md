---
id: 2
slug: define-validated-plans-sql-envelopes-and-checksum-v1
title: "Define validated plans SQL envelopes and checksum v1"
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
      note: "Specify usable bound views and metadata constructors; prohibit unchecked embedding bridges."
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
      note: "Specify bound public views, description construction and invariant-preserving embedding."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T11:30:00Z
      mode: "implement"
      note: "Implement invariant-safe definitions, conservative SQL envelope and byte-level checksum contract."
---

# Define validated plans SQL envelopes and checksum v1

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Applications can construct explicitly ordered migration plans and reject malformed definitions before any network operation. The same logical definitions produce published, byte-for-byte reproducible v1 checksums, giving embedding, history verification and execution a common identity contract.

## Progress


- [x] M1 — 2026-10-16: Pure tests accept independent libraries with shared local names, preserve explicit order, and reject invalid names/duplicates/empty definitions/dependency errors. Lexer tests cover exact bytes, UTF-8/NUL, nested comments, escaped quotes/identifiers, heredocs, multiple statements, protected settings and excluded commands.
- [x] M2 — 2026-10-16: Public two-library composition runs; six representation bypasses fail compilation. All 24 independent input/digest vectors match private encoding and public bound checksums. Unit suite, Haddock, all package builds/checks/distributions, and all six local Nix checks pass; Linux execution remains deferred.

## Surprises & Discoveries


2026-10-16: Current ClickHouse syntax documents nested block comments and `//` line comments as well as SQL/hash comment forms. The scanner handles these explicitly and requires the later server matrix to qualify them. Public fields are ordinary functions over private data representations, so the public consumer can inspect checksums/SQL without exposing record setters or Generic reconstruction.



## Decision Log


2026-10-16: Freeze the exact policy/domain/framing bytes in `docs/contracts/checksum-v1.md`; independent Python vectors include changed step boundaries with equal concatenated SQL. Restrict command headers to qualified table/view names, keep a documented local DDL/INSERT allowlist, and reject quoted SETTINGS keys or unfamiliar quoted-identifier escapes conservatively. Semantic safety and completion remain author/server-qualification obligations. List-oriented parsing helpers reject empty collections; the plan helper returns a direct structured EmptyPlan error.

2026-10-15: Final checksum calculation occurs at component binding. This preserves ergonomic library-owned migration definitions while ensuring every persisted digest includes the identity required by the specification. Generic record access is restricted where it would undermine smart constructors.

## Outcomes & Retrospective


2026-10-16: Accepted the invariant-safe authoring/view API, order-preserving graph validation, conservative SQL envelope and checksum v1 contract. The fixed policy and framing are independently reproducible; descriptions are excluded and dependency/order descriptors remain available for ledger comparison. Tests run against exposed modules as well as private encoders, and Nix runs the actual core suite. No network execution or server support is claimed. Durable decisions are distilled in `docs/adr/0003-bind-checksums-through-invariant-safe-definitions.md`.



## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

At creation there was no local ADR corpus. The pre-implementation review added [Preserve uncertainty across runtime boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md): unsuccessful requests never authorize automatic replay, successor mutation requires all prior server work to be quiescent, shared ledger types are defined before runtime consumers, and test access must preserve public invariants. Follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. There is no profiled ADR bundle; preserve the plain Markdown convention. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/1-bootstrap-seihou-tooling-and-the-four-package-workspace.md` must be Complete. Its package layout, compiler and test entry points are required. This slice implements specification sections 5–7 and the pure part of section 19. A SQL envelope is a lexer that recognizes statement boundaries and forbidden forms; it is not a complete SQL parser or schema-safety proof. A checksum is a SHA-256 digest of a specified binary encoding, not a normalized SQL string.

The conceptual spec places a checksum inside a Migration built without a component name, but section 6 requires component identity in its hash. Resolve that mismatch explicitly: standalone migration definitions remain unbound; component construction binds their identities and calculates final checksums. Only bound plan inspection exposes executable migration/step checksums. Do not insert a fake checksum before component binding.

## Plan of Work


M1 adds `clickhouse-migrate/src/ClickHouseMigrate/Definition.hs`, `Plan.hs`, `Error.hs`, and `Internal/SqlEnvelope.hs`. Hidden constructor names validate the ASCII grammar `[a-z0-9][a-z0-9_-]{0,127}`. Reject empty collections at the parsing boundary, duplicate identities in their scopes, missing/self/cyclic dependencies and a dependency appearing after its dependent. Preserve caller order without topological sorting. Return structured errors with definition paths and safe locations. No environment reads or IO belong in these constructors.

The lexer preserves original ByteString payloads while validating UTF-8, no NUL, substantive SQL and a single statement. Cover quoted identifiers, escapes, line/block comments and explicitly supported heredoc forms; reject unterminated constructs and unsupported ambiguous forms. Permit at most one trailing terminator plus comments. Reject transaction control, USE, session SET, client directives, ON CLUSTER, INSERT FORMAT and protected-setting overrides, including mixed case and comments between tokens. Define a conservative accepted command envelope for local DDL and INSERT SELECT/VALUES, and document qualifications/replication/remote-write/ledger-isolation obligations that cannot be proven lexically. Never imply that a lexer establishes full SQL safety or asynchronous completion.

M2 adds `Internal/Checksum.hs`, bound plan descriptors and `docs/contracts/checksum-v1.md`. Freeze the byte layout as a documented domain/version/policy discriminator followed by unsigned 64-bit big-endian byte lengths for variable fields and unsigned 64-bit counts for lists. Distinct step and migration domains include component/migration identity; the step domain also includes step identity and exact SQL, and the migration domain includes the ordered complete step encodings. Freeze exact discriminator/policy bytes in this milestone and publish complete input hex and expected digest hex. Dependencies are compared in the stored component descriptor as a sorted set, while component/migration order remains a sequence; descriptions and source paths never enter these hashes. Reject unknown formats. Use an independent reference encoder to generate expected vectors once and check them in, rather than generating expected values with the implementation under test.

Finalize exports in `clickhouse-migrate/src/ClickHouseMigrate.hs`. Bound values expose read-only views and structured constructors, not Generic reconstruction, Read, unchecked FromJSON or setters that can invalidate them. Internal ordinary records may use Jitsurei's generic-lens style. Add package compilation fixtures that prove clients cannot forge a valid step or mutate SQL through a public optic. Record the checksum and public-invariant decisions in ADRs.

Freeze the authoring and inspection surface in M2, and compile a separate consumer using only exposed modules. Keep the four representative constructors from specification section 5 with `Migration` explicitly unbound. Add these operations (all view types have hidden constructors and ordinary read-only accessors):

```haskell
withMigrationDescription :: Maybe Text -> Migration -> Migration
inspectPlan :: MigrationPlan -> NonEmpty ComponentView
componentMigrations :: ComponentView -> NonEmpty MigrationView
migrationSteps :: MigrationView -> NonEmpty StepView
migrationChecksum :: MigrationView -> MigrationChecksum
stepChecksum :: StepView -> StepChecksum
stepSql :: StepView -> ByteString
```

ComponentView also exposes its validated name and dependency set; MigrationView exposes its component-qualified MigrationId, description and ordered steps; StepView exposes its validated local name and bytes. The view hierarchy represents bound definitions; no checksum accessor exists on an unbound Migration or SqlStep. Checksum values expose their format and canonical digest representation but cannot be supplied back as trusted definitions. Description updates are pure metadata updates before binding. This supplies the manifest's description field without unsafe record mutation and lets offline plan rendering use the core rather than reconstruct identity.

Add a representative two-library composition fixture before expanding diagnostics. Compile-failure fixtures cover constructor access, `Coercible`/newtype or Generic reconstruction where relevant, public deserialization and writable optics. Embedding must use the same public constructors; do not add a public unchecked `Lift` or internal-named exposed bridge. M1 must enumerate accepted command families and protected-setting spellings in `docs/contracts/sql-envelope-v1.md`; a leading DDL keyword alone cannot authorize detached/background commands. Match that contract against EP-4's supported completion cases before expanding server support.

## Concrete Steps


Create the named suite and fixtures, then run from the repository root:

```bash
nix develop -c cabal test clickhouse-migrate-unit --test-show-details=direct
nix develop -c just check-public-invariants
nix develop -c cabal haddock clickhouse-migrate
```

`just check-public-invariants` must compile valid public consumers and assert compilation failure for constructor/optic bypass fixtures. The unit suite must check fixed checksum vectors plus definition and lexer properties.

## Validation and Acceptance


Accept two library components with the same local migration name and preserve their supplied order. Reject duplicate names within one scope, empty/comment-only SQL, invalid UTF-8, NUL, two statements, escaped-boundary attacks and dependency cycles. Semicolons inside every supported literal/comment form must not create extra steps. Changing one SQL byte, component identity, migration/step identity, step boundary or order changes the corresponding digest; changing description or relocating a file does not. Verify ambiguous concatenation examples cannot share encoded inputs. Reordering existing components or changing recorded dependencies will be detectable from the descriptors consumed by the ledger plan. This plan does not claim real-server execution support.

## Idempotence and Recovery


Builds and pure tests may be repeated. Integration tests must allocate their own temporary directories, ports and database names, track their server processes, and clean up only resources they created. Preserve failed-run evidence before cleanup. Never test against a persistent application database. A failed or uncertain mutating request is not safe to repeat: inspect its exact event and attempt under exclusive access, and use the explicit recovery protocol. Do not erase history, rewrite checksums or assume a timeout stopped server work.

## Interfaces and Dependencies


Consumes the workspace in `docs/plans/1-bootstrap-seihou-tooling-and-the-four-package-workspace.md`. Owns ComponentName, MigrationName, StepName, SqlStep, unbound Migration definitions, MigrationComponent, MigrationPlan, DefinitionError, PlanError, checksum format v1 and the fixed completion-policy identifier. Expose `sqlStep`, `sqlMigration`, `migrationComponent`, and `migrationPlan` with the spec's input shapes, refining the result types to distinguish bound views. Constructors recompute identity rather than accepting caller-supplied checksums. Plans for embedding and ledger must consume these APIs, never duplicate the lexer or encoder. The future transport implements async_insert=0, mutations_sync=1 and alter_sync=1 as the runtime interpretation of this policy.

Revision 2026-10-15 — Pre-implementation API/correctness review: Make unbound/bound public views and metadata construction concrete; close embedding bypasses.
