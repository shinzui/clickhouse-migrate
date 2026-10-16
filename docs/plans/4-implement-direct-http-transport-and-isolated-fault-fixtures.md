---
id: 4
slug: implement-direct-http-transport-and-isolated-fault-fixtures
title: "Implement direct HTTP transport and isolated fault fixtures"
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
      note: "Separate pre-submission rejection, observed server failure, and uncertain outcome."
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
      note: "Define four outcomes, early identity primitives, request policy and private fault driver."
---

# Implement direct HTTP transport and isolated fault fixtures

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


The library can submit a single SQL statement to a pinned direct HTTP(S) target and distinguish complete success from failure or uncertainty. Tests prove no POST is replayed after a lost response, redirect or reused-connection failure. Isolated server and fault fixtures become reusable by ledger and runner tests.

## Progress


- [ ] M1 — Owned test servers and a controllable HTTP fault proxy prove the transport never redirects or replays SQL.
- [ ] M2 — Supported server identity, completion settings, bounded response validation and cleanup pass on an explicitly recorded candidate server matrix.

## Surprises & Discoveries




## Decision Log


2026-10-15: Accept the HTTP abstraction only after an effect-committed/response-lost test proves one submission. Disabling a convenience retry layer alone does not neutralize http-client's reused-connection replay path.

## Outcomes & Retrospective




## Context and Orientation


At planning time this repository contains `docs/initial-spec.md`, `mori.dhall`, `mina.kdl`, and Seihou-installed planning skills, but no Haskell implementation. `mori.dhall` already declares the four root package directories. Files named below that are absent are deliverables, not existing APIs. Run commands from the repository root. The initial specification remains the normative product contract; this plan supplies the implementation decisions and acceptance for its slice.

At creation there was no local ADR corpus. The pre-implementation review added [Preserve uncertainty across runtime boundaries](../adr/0001-preserve-uncertainty-across-runtime-boundaries.md): unsuccessful requests never authorize automatic replay, successor mutation requires all prior server work to be quiescent, shared ledger types are defined before runtime consumers, and test access must preserve public invariants. Follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. There is no profiled ADR bundle; preserve the plain Markdown convention. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md` must be Complete for valid SQL and the fixed completion policy. This implements spec sections 7.2, 8 and transport acceptance in section 19. Transport means the layer sending bytes and interpreting a full server response; a query ID is diagnostic identity, not an idempotency key.

Source was located through `mori://snoyberg/http-client/packages/http-client` and `mori://snoyberg/http-client/packages/http-client-tls`. The inspected Core module retries when a connection was reused and the manager's retry predicate accepts the exception; default manager settings accept several connection errors. Configure a dedicated manager with retries disabled and verify the released source actually used. The source paths within `mori://snoyberg/http-client` are `http-client/http-client/Network/HTTP/Client/Core.hs`, `Manager.hs` and `Types.hs` (artifact-level file URIs pending).

`mori://shinzui/kansoku/okf/adrs/concepts/ADR-2` describes connection-lifetime faults exposed by stalled-handshake, socket-close, cancellation and watchdog tests. Reuse those testing lessons, not its native driver or writer retry policy. Official HTTP documentation confirms that status alone is insufficient; see [ClickHouse HTTP interface](https://clickhouse.com/docs/concepts/features/interfaces/http).

## Plan of Work


M1 creates `clickhouse-migrate/src/ClickHouseMigrate/Internal/Transport.hs` and `Internal/Http.hs`, plus `clickhouse-migrate-test-support/src/ClickHouseMigrate/TestSupport/Server.hs`, `FaultProxy.hs`, and the integration suite. The server harness owns temporary data/config/log directories, loopback ports and process lifetime; it must neither connect to nor delete the template's shared developer server. A fault proxy counts actual request submissions, can forward a request then drop its response, truncate bodies, send late errors, redirect and close a reused socket. Bound every test with a watchdog and preserve diagnostic logs on failure.

Begin with one CREATE TABLE request forwarded exactly once whose successful response is dropped: observe the table exists using a separate read, while the transport reports uncertainty and the proxy count is one. This is the required early consumer check. Configure a dedicated HTTP manager, disable its retry predicate and redirects, do not inherit proxy/failover settings implicitly, retain TLS verification, send SQL in the POST body and credentials in protected headers. Do not put credentials or sensitive values in URLs. Assign an explicit query ID to every request including ledger and metadata operations.

M2 adds `clickhouse-migrate/src/ClickHouseMigrate/Target.hs` and `Internal/ServerPolicy.hs`. Target configuration contains a canonical caller target key, direct endpoint, expected server identity and ledger namespace, plus an explicit binding mode for first use or an expected LedgerId. This plan defines the UUID identity primitive without storage behavior; the ledger plan implements binding and initialization authorization. First-use configuration alone never authorizes creation. Establish and document the server identity probe and its limitations before allowing application writes; never equate an alias string with verified server affinity. Configuration/credential/timeouts remain caller-supplied. Freeze protected completion settings and wait_end_of_query=1; inspect the entire bounded response, exception headers and late errors. Internal reads use a strictly decoded, bounded machine format; commands must reject unexpected bodies rather than infer success from arbitrary text. Treat truncation, disconnect, cancellation and timeout as uncertain once submission may have occurred.

Select candidate supported stable/LTS server releases by checking current upstream support policy and release tags, then record exact versions and binary/container digests in `test/compatibility/clickhouse-matrix.json` and `docs/compatibility.md`. No server version is chosen by this plan. The developer template's binary is not automatically a release candidate. Test local ALTER and mutations under alter_sync=1 and mutations_sync=1, and synchronous INSERT under async_insert=0. Probe required capabilities before mutation, reject unsupported/prerelease series, and initially allow only tested exact patches. Cleanup errors remain separate from primary execution errors. Write ADRs for direct-target support and no-replay transport.

Define that four-way result before ledger integration. Preserve a safe structured server error separately from the outcome classification. Configure response handling so status-based exceptions cannot discard the bounded body or collapse an observed server failure into pre-submission rejection. Complete success requires the expected command/read response shape; it never follows solely from an HTTP status. Apply the fixed settings to every request, including ledger appends and probes, rather than relying on a previous request's session state. Reserve query IDs, authentication, output format and completion settings against caller overrides; accept no arbitrary preconfigured HTTP Manager or Request in the public target API.

The fault suite invokes a core-package `clickhouse-migrate-test-driver` executable enabled by the default-off `internal-test-driver` flag from the workspace plan. It compiles the actual private implementation sources and returns test observations; test-support owns servers, proxies and process supervision. Extend this driver for later ledger faults, while public runner tests use public APIs. Never expose Internal.Http or raw ledger append functions to make the external suite compile.

M2 must add an observed-error case with possible partial effects and a delayed ledger-style INSERT that is still in flight after an empty read. The latter establishes the transport evidence consumed by EP-5: not seeing a row is not proof the request cannot commit later. The no-replay assertion is at most one submission per authorized request (exactly one for faults deliberately injected after forwarding); connect/TLS failures may submit zero. Prove protected settings on independent HTTP requests, not only on a settings probe.

## Concrete Steps


Use Mori first, then inspect the current upstream releases before adding dependency bounds:

```bash
mori registry search http-client
mori registry show snoyberg/http-client --full
mori registry docs snoyberg/http-client
```

Create these project test entry points and run them from the repository root:

```bash
nix develop -c just test-transport
nix develop -c just test-completion-policy
```

The recipes select the integration groups and launch owned fixtures from `test/compatibility/clickhouse-matrix.json`. Logs must include the tested server version, fault mode and received request count, with no secrets or SQL bodies. Do not make test success depend on a manually running server.

## Validation and Acceptance


For every candidate server, verify at most one submission per request after response loss, malformed/late error body, timeout, redirect, and reused-connection failure; require exactly one in cases injected after forwarding. Assert zero requests reach a redirect destination. Reject invalid TLS certificates and wrong server identity; credentials must not appear in recorded URLs or default diagnostics. Confirm body size bounds, truncation detection and full-body completion, including HTTP 200 carrying an error. Exercise cancellation and close failures under the watchdog, and demonstrate an in-flight server query can survive client interruption. A separate query observation can show it remains active but cannot authorize replay. Acceptance includes actual effects and request counts, not only mock return values.

## Idempotence and Recovery


Builds and pure tests may be repeated. Integration tests must allocate their own temporary directories, ports and database names, track their server processes, and clean up only resources they created. Preserve failed-run evidence before cleanup. Never test against a persistent application database. A failed or uncertain mutating request is not safe to repeat: inspect its exact event and attempt under exclusive access, and use the explicit recovery protocol. Do not erase history, rewrite checksums or assume a timeout stopped server work.

## Interfaces and Dependencies


Consumes validated SQL and policy identifiers from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md`. Owns TargetConfig/TargetKey/QueryId/LedgerId, capability and identity checks, safe TransportError and an internal scoped Transport boundary with execute/read operations. Its outcomes are NotSubmitted, AcknowledgedSuccess, ObservedServerFailure and SubmissionUncertain. NotSubmitted requires positive evidence that submission never began; an exception type or non-2xx status alone is insufficient. ObservedServerFailure preserves possibly partial effects even when the full error response was received. Both failure and uncertainty stop the runner and require explicit recovery after a step-start record. No outcome authorizes automatic replay. No transport function automatically retries. The test-support library depends on core; server suites live there, avoiding a core-to-test-support cycle. Ledger code must call this transport for every append and read. This plan owns the fault harness and candidate matrix format; later plans add scenarios and release qualification expands the matrix.

Revision 2026-10-15 — Pre-implementation API/correctness review: Separate server failure from non-submission; add private driver and delayed-write evidence.
