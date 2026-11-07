# Qualify replicated targets by replica set and quorum

Status: Accepted

Date: 2026-11-07

## Context

A replicated database coordinates table DDL through Keeper but replicates rows
only for replicated table engines. A TLS endpoint can route new sockets to
different replicas. The existing direct policy binds one UUID and local completion
in checksum v1, so changing its settings would reinterpret stored evidence.

The owned two-replica spike on exact Altinity 26.3.60.10002.altinitystable recorded
empty successful DDL with output mode `none`, HTTP 408 / Code 159 when a replica
was stopped, and quorum INSERT Code 319 followed by eventual visibility on both
replicas. Restricted application credentials could read local cluster/replica
metadata but lacked READ ON REMOTE. Quorum-one writes did not establish the last
quorum part: sequential consistency by itself could still return stale rows.

## Decision

Keep direct behavior and bytes unchanged. Add a validated replicated topology
with one cluster name and a nonempty duplicate-free expected UUID set. Admit each
new socket by UUID membership, exact qualified version, cluster macro, effective
completion settings and healthy writable Local default storage. For restricted
logins, require local `system.clusters` count to match and exactly one shard.
Counts cannot attest identities of unvisited replicas: independently verified
operator inventory and per-socket admission remain necessary.

Force synchronous ALTER/mutations, full-count nonparallel INSERT quorum, DDL
output mode `none`, sequential reads and metadata fsync. Never use an active-only
DDL mode. Divide the HTTP deadline minus a two-second response margin among three
server waits, with one-second minimum waits and a five-second minimum deadline.
Server errors with possible effects and submission uncertainty never authorize
replay. External serialization and complete cluster-wide drain remain mandatory.
The restricted login's local active-query check is diagnostic only.

Bind both checksum formats when composing a plan, retaining v1 accessors and
vectors. Replicated execution and initialization select v2, whose policy/domain
bytes differ. Decode only known format/policy pairs and refuse a ledger belonging
to the other topology. No SQL transformation or automatic ledger conversion occurs.
Legacy adoption's existing mapping contract remains v1 and fails before writes on
replicated targets; fresh replicated baselines use ordinary native execution.

Infrastructure precreates application and ledger databases with engine Replicated.
The library creates only the ledger's argument-free ReplicatedMergeTree table.
Validate columns, keys and settings exactly, parse exactly two server-supplied
string arguments without inspecting their contents, and require writable replica
health plus the configured total count. Canonical engine metadata preserves macros
while `system.replicas` expands them. Deduplication does not justify retrying writes.

The SQL envelope admits six replicated MergeTree engines only in unquoted
CREATE TABLE/MATERIALIZED VIEW engine positions, with no initial string argument.
Other replicated spellings, explicit Keeper paths, ON CLUSTER and Distributed
remain excluded. Reserve additional replicated completion/wait identifiers in pending replicated
preflight, preserving v1 binding/direct-target acceptance while preventing SQL from
overriding replicated acknowledgment semantics. Reject pending CREATE DATABASE before bootstrap,
after observing the applied prefix, without rechecking already applied history.

Centralize probe/settings/policy/checksum selection and ledger expectations in
ServerProfile; keep named target fields private. Candidate matrix entries declare
their groups. A drift check ties the runtime allowlist to matrix versions, CI image
pulls and the compatibility guide; the candidate resolver verifies exact source
tags and platform image manifests before qualification.

## Consequences

A local Keeper plus two owned Linux replicas and an alternating TCP endpoint
qualify public execution, inspection, restart and audited recovery behavior.
This is neither managed Altinity.Cloud certification nor power-loss evidence.
Production readiness still requires the consumer's managed staging baseline,
scoped grants, actual storage/replica inventory and coordination proof.
See the retained [spike observations](../release-evidence/2026-11-07-replicated-spike.json)
and [plan](../plans/12-run-migrations-and-the-ledger-on-replicated-clickhouse-databases.md).

Server waits can include coordination overhead: the spike observed a metadata ALTER error after about twelve seconds with a five-second inactive-replica wait. The HTTP deadline remains authoritative; if it expires before a complete response, preserve submission uncertainty and never infer non-submission or retry automatically.

Normalize Boolean probe settings through UInt64 before converting them to strings: ClickHouse renders Boolean values as `true`/`false`, while numeric settings render as digits. Keep configured checksum selection explicit for pending reports before an initialized event exists. Replicated fixture restart readiness waits for both database and table replica read-only flags to clear, beyond HTTP readiness.
