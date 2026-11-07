# Qualify an exact Altinity engine with owned Linux fixtures

Status: Accepted

Date: 2026-11-02

## Context

The staging consumer at `mori://shinzui/kansoku` needs exact Altinity
`26.3.60.10001.altinitystable`; the first library release admitted only
`26.8.28.14`. A version string, shared-server ping or historical Linux consumer
success does not qualify a different engine or managed endpoint. The requested
consumer staging initiative explicitly authorizes the compatibility work:
`mori://tan/tan-app-infrastructure/plans/42-qualify-kansoku-artifacts-and-the-staging-clickhouse-contract`.

## Decision

Admit the exact Altinity patch only alongside its immutable owned-server matrix
entry and the same thirteen required native groups used for the existing patch.
The new candidate runs the published Linux arm64 OCI manifest in a fresh container
through an explicitly selected local Unix Docker context. Verify architecture,
version and persisted server UUID; never use an ambient application endpoint or
mount a host data directory. Docker allocates and retains both published ports
for the fixture lifetime. Killing/restarting ClickHouse retains its container,
ports, data root and identity. Failed fixtures retain diagnostics and remove only
their recorded owned container; startup failure is a failed case, without retries.
The container/process harness remains optional test-support, outside the core.

Run every candidate and group for Nix artifacts and extracted sibling source
archives. Missing images or container context fail the release check; they never
silently skip the candidate. Serialize fixture variants on the local host. The
source candidate is the patch cohort `0.1.0.1`; local qualification does not imply
Hackage publication, a release tag, remote CI execution or consumer cutover.

This extends ADR 0009's original Darwin-only engine scope. It preserves ADR 0005's
direct connection, identity, completion and no-replay boundaries. Cloud endpoints,
reverse proxies, load balancers, failover aliases and replicated/distributed effects
remain excluded until separately qualified. An Altinity-branded local container
establishes engine evidence; it does not establish Altinity.Cloud compatibility.

## Consequences

The compatibility matrix and dated release evidence identify exact artifacts and
scope. Matching version text does not attest OS, binary identity, endpoint affinity
or administrative exclusion/drain. Linux arm64 server evidence with Darwin-built
clients is not Linux amd64 application-image acceptance, power-loss durability or
production uptime certification. The consumer must complete managed-endpoint,
scoped-grant, persistent-coordination and packaged recovery acceptance separately.

The independent `0.1.0.2` patch cohort adds exact Altinity `26.3.60.10002.altinitystable` with the same immutable-artifact and two-variant procedure. See [the dated evidence](../release-evidence/2026-11-07-altinity-10002.md) for its suffixed tag and arm64 manifest.
