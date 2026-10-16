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

No local ADR corpus or profiled ADR bundle exists at creation. Before implementation, follow `agents/skills/exec-plan/ADR.md` and read relevant records added by prerequisites. Create durable decisions in `docs/adr/` using the convention then present; do not introduce a new OKF profile incidentally. All cross-repository references use canonical Mori URIs.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`: GHC 9.12 or newer, GHC2024, common Cabal settings with DeriveAnyClass, DuplicateRecordFields, OverloadedLabels and OverloadedStrings, postpositive qualified imports, strict fields, unprefixed field names and explicit deriving strategies. `ClickHouseMigrate.Prelude` is the only module enabling PackageImports. Keep generic-lens label instances local to modules that need them. Validated public types must not expose constructors, writable generic optics, unchecked deserializers or Generic instances that bypass validation. Use MultilineStrings for internal multiline Haskell SQL; file embedding must preserve bytes without its indentation processing.

Before selecting any dependency API, use Mori registry search/show/docs and inspect its source. Before adding bounds or pins, verify current Hackage releases and upstream release tags, record evidence in `docs/dependencies.md`, and test the resolved versions. Local corpus versions are not release evidence. Never search or read `/nix/store`.

Hard prerequisite: `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md` must be Complete for valid SQL and the fixed completion policy. This implements spec sections 7.2, 8 and transport acceptance in section 19. Transport means the layer sending bytes and interpreting a full server response; a query ID is diagnostic identity, not an idempotency key.

Source was located through `mori://snoyberg/http-client/packages/http-client` and `mori://snoyberg/http-client/packages/http-client-tls`. The inspected Core module retries when a connection was reused and the manager's retry predicate accepts the exception; default manager settings accept several connection errors. Configure a dedicated manager with retries disabled and verify the released source actually used. The source paths within `mori://snoyberg/http-client` are `http-client/http-client/Network/HTTP/Client/Core.hs`, `Manager.hs` and `Types.hs` (artifact-level file URIs pending).

`mori://shinzui/kansoku/okf/adrs/concepts/ADR-2` describes connection-lifetime faults exposed by stalled-handshake, socket-close, cancellation and watchdog tests. Reuse those testing lessons, not its native driver or writer retry policy. Official HTTP documentation confirms that status alone is insufficient; see [ClickHouse HTTP interface](https://clickhouse.com/docs/concepts/features/interfaces/http).

## Plan of Work


M1 creates `clickhouse-migrate/src/ClickHouseMigrate/Internal/Transport.hs` and `Internal/Http.hs`, plus `clickhouse-migrate-test-support/src/ClickHouseMigrate/TestSupport/Server.hs`, `FaultProxy.hs`, and the integration suite. The server harness owns temporary data/config/log directories, loopback ports and process lifetime; it must neither connect to nor delete the template's shared developer server. A fault proxy counts actual request submissions, can forward a request then drop its response, truncate bodies, send late errors, redirect and close a reused socket. Bound every test with a watchdog and preserve diagnostic logs on failure.

Begin with one CREATE TABLE request forwarded exactly once whose successful response is dropped: observe the table exists using a separate read, while the transport reports uncertainty and the proxy count is one. This is the required early consumer check. Configure a dedicated HTTP manager, disable its retry predicate and redirects, do not inherit proxy/failover settings implicitly, retain TLS verification, send SQL in the POST body and credentials in protected headers. Do not put credentials or sensitive values in URLs. Assign an explicit query ID to every request including ledger and metadata operations.

M2 adds `clickhouse-migrate/src/ClickHouseMigrate/Target.hs` and `Internal/ServerPolicy.hs`. Target configuration contains a canonical caller target key, direct endpoint, expected server identity and ledger namespace; later ledger access binds a ledger UUID. Establish and document the server identity probe and its limitations before allowing application writes; never equate an alias string with verified server affinity. Configuration/credential/timeouts remain caller-supplied. Freeze protected completion settings and wait_end_of_query=1; inspect the entire bounded response, exception headers and late errors. Internal reads use a strictly decoded, bounded machine format; commands must reject unexpected bodies rather than infer success from arbitrary text. Treat truncation, disconnect, cancellation and timeout as uncertain once submission may have occurred.

Select candidate supported stable/LTS server releases by checking current upstream support policy and release tags, then record exact versions and binary/container digests in `test/compatibility/clickhouse-matrix.json` and `docs/compatibility.md`. No server version is chosen by this plan. The developer template's binary is not automatically a release candidate. Test local ALTER and mutations under alter_sync=1 and mutations_sync=1, and synchronous INSERT under async_insert=0. Probe required capabilities before mutation, reject unsupported/prerelease series, and initially allow only tested exact patches. Cleanup errors remain separate from primary execution errors. Write ADRs for direct-target support and no-replay transport.

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


For every candidate server, verify exactly one request after a response loss, malformed/late error body, timeout, redirect, and reused-connection failure. Assert zero requests reach a redirect destination. Reject invalid TLS certificates and wrong server identity; credentials must not appear in recorded URLs or default diagnostics. Confirm body size bounds, truncation detection and full-body completion, including HTTP 200 carrying an error. Exercise cancellation and close failures under the watchdog, and demonstrate an in-flight server query can survive client interruption. A separate query observation can show it remains active but cannot authorize replay. Acceptance includes actual effects and request counts, not only mock return values.

## Idempotence and Recovery


Builds and pure tests may be repeated. Integration tests must allocate their own temporary directories, ports and database names, track their server processes, and clean up only resources they created. Preserve failed-run evidence before cleanup. Never test against a persistent application database. A failed or uncertain mutating request is not safe to repeat: inspect its exact event and attempt under exclusive access, and use the explicit recovery protocol. Do not erase history, rewrite checksums or assume a timeout stopped server work.

## Interfaces and Dependencies


Consumes validated SQL and policy identifiers from `docs/plans/2-define-validated-plans-sql-envelopes-and-checksum-v1.md`. Owns TargetConfig/TargetKey/QueryId, capability and identity checks, safe TransportError and an internal scoped Transport boundary with execute/read operations. Its outcomes distinguish known rejection, acknowledged complete response and potentially submitted/unknown result. No transport function automatically retries. The test-support library depends on core; server suites live there, avoiding a core-to-test-support cycle. Ledger code must call this transport for every append and read. This plan owns the fault harness and candidate matrix format; later plans add scenarios and release qualification expands the matrix.
