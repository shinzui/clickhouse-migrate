# Replicated release candidate qualification, 2026-11-07

The shared feature candidate is `0.1.1.0`. Its independent exact-version patch
boundary remains commit `0d4f889` / version `0.1.0.2`; see
[the patch evidence](2026-11-07-altinity-10002.md).

`just check` passes on the feature candidate: seven package metadata checks,
three pure suites, public API invariant checks, all 48 independent checksum
vectors, strict user documentation/review validation and formatting. The new
probe tests reject foreign UUIDs, unqualified versions and wrong cluster macros.
Direct request/settings/ledger bytes are pinned and all v1 vector files remain
byte-identical. The CLI verifies actual offline v1/v2 digests and legacy report
construction/matching arities. Additional policy restrictions apply only to
pending replicated work, preserving previously valid direct definitions.

The full Cabal release matrix passes **41 cases**: thirteen direct groups on
native 26.8.28.14, and those thirteen plus `replicated` on both exact Altinity
Linux arm64 images (10001 and 10002). Separately, the installed Nix suite and
mounted example pass the replicated group for each Altinity image, using their
packaged fixture data. Artifact variants serialize through the owned release
lock. The [receipt](2026-11-07-replicated.json) records archive hashes, installed
Nix artifact identities, implementation hashes and acceptance scope.

Each replicated group owns Keeper, two replicas and an alternating TCP endpoint.
It verifies the actual mounted CLI's fresh pending v2 digests, up/status/history/
verify, no-op reapply, equal application/ledger rows on both replicas, acknowledged
history after each process restart, missing/Atomic/malformed ledgers, rejection
of v1 initialization in a replicated ledger, membership mismatch, CREATE DATABASE
refusal before ledger bootstrap and observed plain-MergeTree Code 56. Stopping the
other replica after intent produces a server failure and blocking ledger uncertainty,
never acknowledged success; restart, explicit replica synchronization and audited
accept/finalize recover without replaying SQL.

The seven `0.1.1.0` source archives are generated and their packaged files compared
with the final tree, including the new profile, checksum vectors, public fixtures,
replicated harness and embedded example manifests/SQL. This is packaging evidence;
the complete extracted-source qualification for the independent patch is recorded
separately rather than being claimed again for the feature cohort.

The [64-observation spike](2026-11-07-replicated-spike.json) and
[its interpretation](2026-11-07-replicated-spike.md) retain completion/metadata
observations. Development exposed Boolean probe spelling, a corrected non-key
mutation case, and HTTP readiness preceding database/table replica readiness.
Fixture restart now polls those read-only flags within a deadline, without retrying
server startup. A follow-up readiness-race failure was retained before this fix.
The engine parser additionally requires actual single-quoted arguments. A mocked
remote Docker context is refused before network/container mutation; normal fixtures
verify local Unix context, exact image platform and each persisted server UUID.

Replicated policy waits share the request budget, but coordination overhead can
still exhaust the HTTP deadline. Such outcomes remain uncertain. Restricted-login
membership uses local replica/shard counts plus UUID admission on every new socket;
operators independently verify UUIDs of unvisited replicas. Local active-query
diagnostics never establish cluster-wide quiescence. Full-count nonparallel quorum,
not sequential consistency alone, establishes acknowledged visibility.

No managed cluster was changed or probed for this implementation. The infrastructure
repository records staging Local storage and narrow grants, but does not establish
production storage/default macros/per-replica endpoints. Managed readiness still
requires the consumer's replicated baseline, scoped metadata grants, replica
inventory, coordinator/drain evidence and successful managed staging run. No Hackage
upload, release tag, remote CI or production cutover is implied.
