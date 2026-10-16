---
id: 8
slug: deliver-reusable-cli-documentation-and-release-qualification
title: "Deliver reusable CLI documentation and release qualification"
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
      verdict: "comments"
      note: "Carry domain failure and cancellation contracts into CLI validation."
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
      note: "Align CLI result contracts and release checks with runtime cancellation and private test driver."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T16:34:42Z
      mode: "implement"
      note: "Implement reusable CLI, application-owned examples and native release qualification on completed core/adoption APIs."
---

# Deliver reusable CLI documentation and release qualification

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Applications can mount reusable migration commands around their compiled plan, obtain stable text/JSON results and follow tested operational guidance. Release qualification demonstrates every claimed server/compiler combination and leaves an explicit evidence trail for consumer cutover.

## Progress


- [x] M1 — Reusable command parsing/handling and schemaVersion 1 JSON pass offline and guarded integration cases.
- [x] M2 — A two-component executable example, published contracts, compatibility matrix and release gates pass with the production dependency closure isolated from test tools.

## Surprises & Discoveries

- Cabal-built suite executables invoked directly need the package data-directory
  override; `cabal test` supplies it, while Nix-installed artifacts use installed
  data. The first early invocation failed before starting a server because this
  override was absent. Diagnostics identified the missing Python fixture path;
  corrected direct recipes and reran both new groups successfully.
- FirstUse without initialization authorization reports InitializationNotAuthorized;
  a missing recurring ExistingLedger reports LedgerRequired. The CLI test now
  exercises the intended recurring-binding case rather than asserting the wrong code.
- Cabal's core graph transitively includes the standard Haskell process library via
  http-client -> streaming-commons. Released Cabal/source evidence confirms this
  unconditional dependency. Actual fixture/optional-tool isolation remains required;
  a broad claim that no process library exists would be false (ADR 0009).




- One Nix matrix attempt passed ten groups, then the official native server exited
  -11 before CLI fixture readiness or logger output. Preserve its failed root/log;
  do not count it as passing. Different Nix-shell TMPDIRs had defeated the initial
  cross-variant job lock; use a fixed host-wide /tmp path. The native crash cause
  remains unknown; serialize the next full Nix run after distribution qualification.
- Final upstream recheck found newly published 26.8.29.10 LTS. Its package-index
  version and tag/source commit were verified, but it is not qualified. Preserve
  the exact already tested 26.8.28.14 allowlist; do not imply all current patches pass.

## Decision Log

- Use optparse >=0.18.1 && <0.20 after released-source/API review of both actual
  dependency sets. Keep parsing/dispatch/rendering independent of application
  environment/streams/exit, repeat validation in the handler, and retain core errors.
- Freeze explicit schemaVersion 1 encoders, decimal-string UInt64 sequences, four
  independent golden fixtures and exhaustive constructor matches. Preserve adoption
  planning observations and primary/secondary execution evidence; never catch async
  cancellation as an ordinary command result.
- Add read-only target/binding/provider-description accessors, two independent
  embedded libraries and a private executable using the conservative host-local
  development adapter. No accessor exposes credentials or a live guard.
- Run the same twelve owned native groups against Cabal, Nix and extracted sibling
  archives. Narrow future CI to native arm64 macOS; user deferred Linux builders and
  the repository is not remotely available. No external action is implied.
- Distill these decisions and the precise process-library boundary in ADR 0009.




## Outcomes & Retrospective

M1 passes the CLI unit suite (every parser command, malformed/duplicate evidence,
offline environment unforced, policy/provider refusal and four JSON goldens) and the
native CLI group (inspection/current distinction, explicit init, all repair/adoption
handlers, stale state, partial JSON, delayed append receipt and async propagation).
The native executable group also passes composed offline/fresh/no-op/inspection,
finalize and adoption commands, separate streams and killed-subprocess controlled
drain. M2 completes on 2026-10-16: all twelve native groups pass from seven extracted
sibling distributions and in a separate complete serial Nix run. All seven package
metadata checks, three unit suites, fourteen public negative consumers, 24 checksum
vectors, two adoption vectors, source-distribution Haddocks, six native flake checks,
formatting and Seihou drift checks pass. Cabal core library closure has 113 package
units and Nix runtime metadata 330 references, excluding optional/test/DB harnesses;
the standard transitive process library is reported explicitly. Source archives build
with only sibling packages and explicit manifest inputs; no repository source path
is needed. CLI/authoring/operations/adoption guides, JSON/error contracts and ADR 0009
are reconciled with the compiled API.

Evidence: `/tmp/clickhouse-migrate-ep8-distributions.log` and its preserved
`/tmp/clickhouse-migrate-release-sdist-saaumydn` witness workspace;
`/tmp/clickhouse-migrate-ep8-nix-matrix-final.log` for the complete serial Nix run;
root-checks/closure/flake/format logs under the same ep8 prefix. The earlier pre-ready
SIGSEGV is explicitly excluded and retained, with unknown cause and no uptime claim.
New upstream 26.8.29.10 LTS/26.9 stable remain unqualified, rather than being silently
accepted. Final matrix annotations record evidence without changing the admitted
version/digest/SQL. No Linux builder, remote CI, publication, deployment or external
consumer change occurred. The separate cutover at `mori://shinzui/kansoku` remains open.

The early parsed/typed consumer and subprocess tests found data-directory and
expected-error test assumptions before expanding qualification. Exact-wire goldens
and public core reports avoided a second CLI state model. The closure audit also
prevented an inaccurate claim about HTTP's standard transitive process library.




## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

At creation there was no local ADR corpus. The pre-implementation review added [Preserve uncertainty across runtime boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md): unsuccessful requests never authorize automatic replay, successor mutation requires all prior server work to be quiescent, shared ledger types are defined before runtime consumers, and test access must preserve public invariants. Follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. There is no profiled ADR bundle; preserve the plain Markdown convention. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisites: `docs/plans/7-adopt-legacy-history-with-auditable-consumer-fixtures.md` and `docs/plans/3-embed-ordered-manifests-with-incremental-rebuild-guarantees.md` must be Complete; runner and transport are transitively complete. This implements spec sections 16, 18 and remaining public-contract acceptance in 19. CLI integration is a library embedded by an application executable, not runtime migration-file discovery. `mori://shinzui/haskell-jitsurei/docs/core-standards` remains the source convention; consult applicable CLI recipes through Mori before borrowing parser/help APIs. There are no local ADRs at creation; at implementation read prior children’s decisions on package boundaries, ledger/recovery and adoption evidence.

## Plan of Work


M1 adds `clickhouse-migrate-cli/src/ClickHouseMigrate/CLI.hs`, `CLI/Parser.hs`, `CLI/Handler.hs`, `CLI/Render/Text.hs`, and `CLI/Render/Json.hs`. Use optparse-applicative after Mori lookup, released-source review and Hackage/tag verification. Expose parsers and dispatchers receiving the compiled plan, caller connection config, exclusive-access provider, event sink and command policy. The executable owns environment/secret loading, logging, stdout and exit-code choice. Required commands are offline plan; remote status/history; verify with optional require-current; up with explicit target-bound initialize-ledger; repair resume/retry-step/accept-step/finalize; and adopt plan/apply/resume. Mutation without a provider fails. Repair/adoption require expected state and audit fields; uncertain work additionally requires explicit quiescence acknowledgement and evidence. Help distinguishes compatible, current and schema drift, and forbids force/mark-clean/reset/checksum rewriting.

Publish `docs/user/contracts/json-v1.md` with schemaVersion 1, stable command/status/error codes and explicit report variants. For normally returning commands, JSON is one complete command-result document on stdout, including synchronous partial failure with completed work and unresolved attempts. Asynchronous cancellation preserves cancellation semantics; a final JSON document is not guaranteed on interruption or process termination. Progress goes to a separate caller sink, with tests capturing both streams. Keep operator-attested acceptance distinct from observed server success and source-checksum evidence. Default renderers redact SQL, credentials, sensitive parameters and raw server diagnostics; raw detail is explicit opt-in. Use golden contract fixtures, including malformed input and partial failures, and make encoders explicit enough that adding a Haskell constructor cannot silently break the wire format.

M2 creates `examples/two-components/` with two small library components and an application-owned executable that mounts the parser; list them as non-public workspace packages with valid distributions. It must run offline plan without a server, demonstrate explicit initialization/fresh up, no-op second up, inspection, repair and adoption against isolated fixtures. Publish authoring/composition, connection/exclusive-access, maintenance, recovery and adoption guides, along with ledger/checksum/manifest/adoption/JSON contracts and error codes. Reconcile README, Haddocks and examples with the final API rather than conceptual signatures.

Finish `test/compatibility/clickhouse-matrix.json`, `docs/user/compatibility.md`, `scripts/check-production-closure.py` and CI release jobs. Verify current upstream supported stable/LTS policy and tags at qualification time, record exact server patches/digests and compiler/transport versions, and run all real-server failure suites on every claimed series. Keep default acceptance limited to tested exact patches; a broader patch policy requires explicit documented evidence. Include effective fsync/synchronous settings, direct self-managed Atomic/MergeTree assumptions and tested process/server failure limits. Do not claim Cloud, distributed execution or power-loss protection from process-kill tests. Build source tarballs, run package metadata/Haddock checks, compile consumers from the distributions and inspect both Cabal library dependencies and Nix runtime closures without traversing `/nix/store`.

Produce `docs/release-evidence.md` mapping every section 19 criterion to a test command, fixture and result. Use it for release qualification, not a checklist that manufactures passing evidence. Complete the separate consumer runner replacement at `mori://shinzui/kansoku` through that repository's workflow when authorized, after the example proves the integration API. A fixture-only result is insufficient to close that gate. Finally distill all child decisions into local ADRs and reconcile the MasterPlan registry and remaining integration gates. Building releasable artifacts does not by itself authorize publishing to Hackage or deployment.

Use the already compiled public consumer contracts from the definition and runner plans for CLI integration. Parsing must validate expected-state tokens, target-bound initialization, audit fields and operation-specific recovery inputs before dispatch. Reuse the core's failure/report and evidence types; do not translate ObservedServerFailure into proof of no effects or NotObserved into permission to retry. Add golden results for delayed-ledger uncertainty and synchronous failure after partial progress, plus a subprocess cancellation check that proves cleanup without requiring final JSON. Build and run the opt-in internal test driver from source distributions for qualification, and prove it is absent from normal production outputs.

## Concrete Steps


Create the named recipes and run from the repository root:

```bash
nix develop -c cabal test clickhouse-migrate-cli-test --test-show-details=direct
nix develop -c cabal run clickhouse-migrate-example -- plan --json
nix develop -c just test-example
nix develop -c just test-release-matrix
nix develop -c just check-production-closure
nix develop -c just check-packages
nix develop -c cabal haddock all
nix develop -c cabal sdist all
nix flake check
```

The offline example emits exactly one valid JSON document with schemaVersion 1 and two components without opening a connection. Matrix logs must name exact tested versions and fail any missing required case, not silently skip unavailable server jobs. Use Nix evaluation/derivation metadata commands for closure inspection; never search/read store paths.

## Validation and Acceptance


Every command works through a reusable library handler with application-controlled configuration and exit policy. Tests prove offline behavior, compatible versus require-current verification, mandatory access and initialization authorization, stale repair/adoption rejection, and complete partial-failure JSON. Capture stdout, stderr and callback streams to establish one result document and redaction. Example components preserve independent naming and order. Distributions compile without the repository's source tree. The core's production dependency graph excludes embed, CLI, test-support and PostgreSQL tooling; test harness/process/container dependencies occur only in test scopes. All frozen schemas have fixtures and upgrade/version policy. Release evidence must distinguish tested claims, exclusions and the separate consumer gate, and must not call the overall initiative complete until that gate passes.

## Idempotence and Recovery


Builds and pure tests may be repeated. Integration tests must allocate their own temporary directories, ports and database names, track their server processes, and clean up only resources they created. Preserve failed-run evidence before cleanup. Never test against a persistent application database. A failed or uncertain mutating request is not safe to repeat: inspect its exact event and attempt under exclusive access, and use the explicit recovery protocol. Do not erase history, rewrite checksums or assume a timeout stopped server work.

## Interfaces and Dependencies


Consumes all public model/runtime/adoption APIs from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md`, `docs/plans/6-execute-inspect-and-repair-migrations-conservatively.md`, `docs/plans/7-adopt-legacy-history-with-auditable-consumer-fixtures.md` and embedding from `docs/plans/3-embed-ordered-manifests-with-incremental-rebuild-guarantees.md`. Owns CLI command types, parser/dispatch contracts, text rendering and JSON schemaVersion 1. It may extend shared CI/Nix/Cabal wiring defined by `docs/plans/1-bootstrap-seihou-tooling-and-the-four-package-workspace.md` and matrix scenarios defined by `docs/plans/4-implement-direct-http-transport-and-isolated-fault-fixtures.md`, but must preserve their single source of truth. JSON rendering must not redefine core state/evidence semantics. No library API calls exitWith or reads secrets implicitly. The external consumer change is an initiative integration gate with its own canonical reference, not a hidden core dependency.

Revision 2026-10-15 — Pre-implementation API/correctness review: Align CLI with typed failures, recovery inputs and asynchronous cancellation semantics.
