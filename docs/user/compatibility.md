---
type: Reference
title: "Compatibility evidence"
description: "Look up the exact qualified ClickHouse artifact, platform, and support limits."
docId: DOC-5
tags: ["compatibility", "clickhouse", "qualification"]
generated:
  by: human:nadeem
  at: 2026-11-13T22:09:25Z
---

# Compatibility evidence

The exact server candidates are ClickHouse **26.8.28.14 LTS** on Apple Silicon macOS
and in an exact owned Linux arm64 OCI image, plus **26.3.60.10001.altinitystable**
and **26.3.60.10002.altinitystable** on Linux arm64 in owned local containers. The exact official binary URL, SHA-256, release tag object
and dereferenced source commit are in
[test/compatibility/clickhouse-matrix.json](../../test/compatibility/clickhouse-matrix.json).
The fixture verifies the digest before execution. This file links to the packaged
matrix in test-support so installed fixtures use the same candidate.

On 2026-10-16, the upstream [security/support policy](https://github.com/ClickHouse/ClickHouse/security/policy)
and [release](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.8.28.14-lts)
were checked before selecting the original exact LTS candidate. The developer
template's ClickHouse version is not release evidence. The original twelve-group
qualification is retained in [initial release evidence](../release-evidence.md).
On 2026-11-02 both exact candidates passed all thirteen groups from Nix and
extracted-source artifacts. The Altinity patch adds explicit owned OCI fixtures; see [the dated qualification](../release-evidence/2026-11-02-altinity.md).
The clients run on Darwin; this makes no Linux client, managed-cloud or remote CI
claim. The separate external consumer cutover remains open.

Only these exact patches pass the runtime version allowlist. New patches and
prereleases fail closed until independently qualified and explicitly added.
Runtime probes do not attest a binary digest or OS; administrators must install
the artifact/platform from the matrix. Matching version text alone is not
qualification. Supported operation is one directly addressed, persistently identified server
using local synchronous effects, or a single-shard replicated cluster with an exact
configured replica set and Keeper-backed pre-existing Replicated databases. The ledger uses the explicitly selected default
storage policy backed only by healthy writable Local disks, with verified metadata
and part fsync settings. Owned replica-fixture evidence is not managed-cloud certification. Arbitrary cloud
proxies, multi-shard clusters, Distributed tables and SQL rewriting remain excluded.
The fault proxy is test infrastructure, not a supported production topology.

The identity probe reads `serverUUID()`, `version()`, `hostName()` and effective
completion settings. The UUID comes from the server data root's persisted UUID
file; deleting/corrupting that file changes identity, while cloning the data root
can duplicate it. Administrators must prevent clones sharing an expected identity.
DNS/alias text alone proves no affinity. TLS uses normal certificate verification;
HTTP is appropriate only on a trusted administrative network. Admission runs on
the actual newly opened connection before application or ledger bytes, including
connections opened after an earlier successful probe.

Every POST supplies an explicit query ID and `async_insert=0`, `mutations_sync=1`,
`alter_sync=1`, `wait_end_of_query=1` and JSONEachRow output. Ledger metadata writes additionally force
`fsync_metadata=1`; machine reads force throwing overflow modes and unrestricted
server read/result limits while retaining client response bounds. Requests explicitly
accept identity encoding. There is no arbitrary
request/manager/settings injection. These settings define observed local completion,
not power-loss durability or atomic SQL-plus-ledger commit. Query IDs identify
requests; they do not deduplicate SQL. A full bounded response must validate before
success. Lost/truncated/oversize/malformed responses after submission are uncertain;
a complete server error can have partial effects. Neither authorizes replay.

Run from the native development environment:

```bash
# Start Apple Container and pre-pull each exact Linux arm64 digest from the matrix.
container system start
container image pull --platform linux/arm64 <exact-matrix-image-digest>
nix develop --builders '' -c just test-integration
```

The current fixture uses Apple Container for Linux servers, including an owned
Keeper and network for replication. It inspects the exact image digest/platform
and uses inspected private addresses without assuming container-name DNS.
Historical Docker qualification records describe their original execution boundary.
The workflow configuration is updated; local evidence does not claim a remote CI run.

Each suite owns a new temporary native server, data root, credentials and ports.
No shared developer server is used. Profiles deliberately default to weaker
completion settings; the transport must override them on every independent POST.
The transport group checks committed effects and one received POST after response
loss, truncation, late errors, timeout and reused-socket failure; zero redirect
forwarding; untrusted TLS; body bounds; wrong UUID/version/settings; identity changes
on reconnect; post-scope rejection; separate cleanup errors and closed sockets.
The completion group checks visible synchronous INSERT, local ALTER, a mutation
blocked by stopped merges, an empty read before a delayed INSERT commits, and a
server query surviving client cancellation. All passed on 2026-10-16. Failed fixture
runs preserve their owned diagnostic root; successful runs remove only owned data.

Ledger qualification also passes `just test-ledger` and `just test-exclusive-access`:
initialization DDL/first-event response loss; representative execution, recovery and
adoption append loss; complete observed error with a committed event; read-only exact
receipt reconciliation; delayed intent/completion/adoption after NotObserved; a
delayed first INSERT after empty row/process observations with a blocked different-
UUID successor; wrong engines/columns/UUID/target/storage; physical duplicate,
sequence gap/conflict, unknown version, missing initialization and foreign-ledger
corruption; and acknowledged history after owned-server SIGKILL/restart. The suite
runs against both Cabal and Nix-built core drivers. Public separate-process host-local
coordination runs in the Cabal harness; the Nix package build also compiles that
adapter. Extracted sibling source distributions pass the complete ledger group.

A caller-owned externally serialized job may retain exclusion across read-only
NotObserved diagnosis and eventual request drain. It must admit no mutating successor
until every predecessor request is quiescent. The host-local development adapter
leaves a persistent marker after clean release and process death, and requires an
explicit target-bound external attestation before later entry. Neither an absent
system.processes row nor an empty ledger read satisfies that responsibility.


Runner qualification passes the public up/status/history/verify and four repair
operations in both Cabal and Nix dependency closures, and from extracted sibling
source distributions. `just test-runner`, `just test-repair` and
`just test-failure-boundaries` enumerate observer and dependent-ledger response-loss
boundaries, retained checkpoints, composite primary/secondary failures, incompatible
prefixes, stale repair state and active-query refusal. Retry executes only its
selected step; resume stops at its selected migration; accept/finalize execute no
application SQL and retain attestation evidence. Both owned-process termination
and asynchronous cancellation leave a real server mutation alive; external drain
and explicit evidence are required before recovery. Ordinary up never consumes
standing recovery authorization. ADR 0007 and operations.md describe these limits.
The optional `integration-tests` Nix output installs this public harness for
explicit native execution; it does not start a server during a Nix package build.


Adoption qualification passes `just test-adoption` and `just test-consumer-fixtures`.
All ten native groups pass with the Nix-built public harness/core driver and again
from extracted sibling source distributions. Coverage includes every adoption
append/observer boundary, cancellation/cleanup, stale/conflicting batches, exact
receipts and a delayed entry arriving after NotObserved with a blocked successor.
The captured consumer at its recorded immutable revision independently passes
25 native migrations / 257 reviewed steps and 253 original source statements,
then zero-SQL adoption of 25 filename/time rows and one appended native migration.
Its three explicit native adaptations and unchanged source hashes are published in
provenance and ADR 0008. Filename-only evidence remains operator-attested. Schema
metadata comparisons are fixture observations, not a general schema-equality claim.
The external consumer runner replacement remains separate.


The client qualification host is macOS 26.7/arm64; the Altinity server runs in a
separate Linux arm64 VM/container. Its ports are allocated on the Docker host and
reserved across owned ClickHouse restarts. All candidates must be available for
the full matrix; missing prerequisites fail, without silently skipping candidates.
The initial qualification host is macOS 26.7/arm64. A native server startup SIGSEGV before
readiness/logger output is preserved in release-evidence.md and is not counted as
a passing run; its cause is unknown. Fixture startup failures fail the case rather
than automatically retrying. Native protocol evidence is not production OS/uptime
certification. Final recheck found 26.8.29.10 LTS newly published in the official
package index (tag/source identity recorded in release evidence); it remains unqualified
and rejected, as does 26.9 stable. No implicit latest-patch compatibility is claimed.


## Qualifying a new ClickHouse build

Use the exact published upstream tag (which can differ from the image version):

```bash
python3 scripts/qualify-candidate.py --tag <upstream-tag> --repo <upstream-repository> --image <image:version>
```

The resolver prints immutable source and image identities, a CI pull line and an
evidence skeleton. It writes only with `--write`, refusing duplicate IDs or versions.
Add the version to `supportedVersions` in
`clickhouse-migrate/src/ClickHouseMigrate/Internal/ServerPolicy.hs` and name it in
this guide. Declare the candidate's groups in the matrix and add its exact CI pull.
Run `python3 scripts/check-candidate-policy.py` to identify omissions, pre-pull into
the isolated context, then run `just test-release-matrix` and `just qualify-distributions`.
Record dated evidence for both artifact variants before marking the candidate
qualified and bumping the shared patch version. `just check-public-invariants`
checks agreement between the runtime allowlist, matrix, CI and this guide.


## Replicated completion and admission

Replicated targets admit each new connection only to an expected UUID, qualified
version, matching cluster macro, effective completion settings and healthy writable
Local default storage. Restricted logins use the local `system.clusters` replica
count and require one shard. This check does not attest UUIDs of unvisited replicas;
operators must independently verify the configured UUID inventory. Every socket
that is used still requires UUID admission. Neither counts nor DNS prove identity.

Every replicated write uses synchronous ALTER/mutations and full-count nonparallel
INSERT quorum. DDL uses output mode `none`, which waits for inactive replicas and
throws on timeout. Reads use sequential consistency. Acknowledged writes must be
visible on every configured replica; sequential consistency alone is insufficient
for weaker quorum-one writes. The three server wait bounds share the HTTP deadline
minus a two-second response margin. The request deadline is at least five seconds.
Replicated ledgers record checksum format v2. The owned two-replica fixture and its
64-observation spike are retained under `docs/release-evidence/`.

The release version is `0.2.0.0`, consolidating the unpublished patch and
replicated feature candidates below. The major bump accounts for public
constructor additions and the new versioned replicated contracts. Direct targets
retain checksum v1 and their existing completion policy. Earlier qualification
receipts keep their original candidate versions; they do not establish publication
or managed-cluster readiness.

The independent patch cohort is `0.1.0.2`; the replicated feature candidate is the shared `0.1.1.0` cohort. Its package version does not imply Hackage publication or managed-cluster readiness.

On 2026-11-07 all three exact candidates passed all thirteen existing groups in both Nix and extracted-source variants (39 cases per variant). See [the independent 10002 evidence](../release-evidence/2026-11-07-altinity-10002.md).

The `0.1.1.0` candidate passes the final 41-case matrix plus both installed-Nix replicated groups; see [the replicated qualification](../release-evidence/2026-11-07-replicated.md).


A direct Linux arm64 26.8.28.14 OCI artifact is qualified for the owned
Nagare ceremony at
`mori://shinzui/kansoku/plans/53-prove-shared-server-maintenance-across-deployment-platforms`.
Its exact platform manifest is
`docker.io/clickhouse/clickhouse-server@sha256:597add6eeadf0b3c562b58c9a63d9712b9a0cde4e49b68e64a697dbf2b363b25`.
This adds no runtime version and changes no SDK implementation. Working-tree, extracted-source and Nix variants each pass all thirteen direct
native groups; see [the qualification](../release-evidence/2026-11-14-lts-linux-arm64.md).
no replicated or Linux-client support is inferred for this image.
