# Compatibility evidence

The native-qualified candidate is ClickHouse **26.8.28.14 LTS** on
Apple Silicon macOS. The exact official binary URL, SHA-256, release tag object
and dereferenced source commit are in
[test/compatibility/clickhouse-matrix.json](../test/compatibility/clickhouse-matrix.json).
The fixture verifies the digest before execution. This file links to the packaged
matrix in test-support so installed fixtures use the same candidate.

On 2026-10-16, the upstream [security/support policy](https://github.com/ClickHouse/ClickHouse/security/policy)
and [release](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.8.28.14-lts)
were checked before selecting this exact LTS candidate. The developer template's
ClickHouse version is not release evidence. Linux execution is deferred by the
user; this evidence makes no Linux or remote CI claim. All twelve required groups pass in both Nix and extracted source-distribution artifact sets; local CLI/release qualification is complete. The separate external consumer cutover remains open.

Only this exact patch passes the runtime version allowlist. New patches and
prereleases fail closed until independently qualified and explicitly added.
Runtime probes do not attest a binary digest or OS; administrators must install
the artifact/platform from the matrix. Matching version text alone is not
qualification. Supported operation is one directly addressed, persistently identified server
using local synchronous effects. The ledger uses the explicitly selected default
storage policy backed only by healthy writable Local disks, with verified metadata
and part fsync settings. Cloud, HTTP reverse proxies/load balancers,
failover aliases, distributed execution and replicated engines are excluded.
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
nix develop --builders '' -c just test-integration
```

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


The qualification host is macOS 26.7/arm64. A native server startup SIGSEGV before
readiness/logger output is preserved in release-evidence.md and is not counted as
a passing run; its cause is unknown. Fixture startup failures fail the case rather
than automatically retrying. Native protocol evidence is not production OS/uptime
certification. Final recheck found 26.8.29.10 LTS newly published in the official
package index (tag/source identity recorded in release evidence); it remains unqualified
and rejected, as does 26.9 stable. No implicit latest-patch compatibility is claimed.
