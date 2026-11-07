# Replicated completion spike, 2026-11-07

The [64 observations](2026-11-07-replicated-spike.json) cover all eight plan questions
on an owned Keeper plus two replicas of the pinned Linux arm64 Altinity 10002
image. Run `scripts/replicated-spike.py --report <path>` with an isolated Docker
context and the pre-pulled matrix image to reproduce them.

DDL output `none` returns empty success, waits for inactive replicas and throws
Code 159 after a five-second server deadline (observed about 5.3 seconds). `throw`
returns rows on success; `null_status_on_timeout` returns HTTP 200 despite a missing
replica, so neither is the command acknowledgment policy. Queued DDL catches up
through Keeper after restart. ALTER/mutation waits also preserve possible effects.

A quorum-two INSERT returned Code 319 with a locally visible row; it became
visible on both replicas after restart. An error or client deadline never proves
non-submission. Quorum-one writes do not establish the last quorum part: a lagging
replica returned stale data even with sequential consistency. Full-count quorum
must therefore be tested through direct reads of both replicas after acknowledgment.

Metadata preserves server default macros in engine_full; system.replicas expands
them. The observed default path/name are `/clickhouse/tables/{uuid}/{shard}` and
`{replica}`. Both replicas report healthy Local default storage. The restricted
login lacks READ ON REMOTE (Code 497) but can read local membership/replica health.
The admin observes the active query through clusterAllReplicas; application repair
uses a local diagnostic plus mandatory external cluster-wide drain evidence.
Plain MergeTree is refused with Code 56, explicit Keeper arguments with Code 80,
and argument-free ReplicatedReplacingMergeTree(ver) is accepted.

Initial fixture startup attempts exposed a Keeper/data-owner mismatch, fixed by
running Keeper under the copied data owner's UID and waiting for its own readiness.
Their diagnostic roots are retained; no readiness retry hides a failed fixture.
Managed production macros, storage and per-replica endpoints remain separate
consumer observations. The infrastructure repository records only staging's
healthy Local default policy and narrow grants, not those production answers.
