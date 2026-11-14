# Bounded read-only inspection source qualification

Delivered source cohort `a0bf98efbffbae9def846454deef9164ecadbd9d` adds
`boundedObservation` for constrained SELECT-only reader roles. Positive row and
byte bounds are explicit; mutation and guarded defaults keep their byte-pinned
request policy. Result/read/timeout/sort overflow modes remain throwing. Native
runner cases prove that the constrained role rejects ordinary unlimited
observation, accepts bounded complete verification, and refuses an overflowing
history without accepting its prefix.

Seven extracted sibling source distributions pass metadata checks, all three
pure suites, Haddocks, embedding construction and all 54 declared native groups.
Installed Nix suite/driver/example artifacts independently pass the same 54
required groups. Both variants have zero failures/skips in their accepted runs:
108 required native groups across native Darwin LTS, both exact Altinity Linux
arm64 candidates including replicated groups, and official Linux arm64 LTS.
Working-tree Cabal separately passes the new constrained-reader/overflow case
on the exact official Linux arm64 artifact. The full working-tree matrix is not
claimed.

The artifact matrix and unchanged SQL/checksum policy identify the exact engines.
The selected SDK numeric package version remains 0.2.0.0: this is an immutable
unreleased source candidate, not an assertion that Hackage 0.2.0.0 contains the
new API. No Linux-client, managed-cloud, production cutover or remote-CI result
is inferred.

Private source artifacts and complete build evidence are
`/tmp/clickhouse-migrate-release-sdist-gqgw1kdx/`, including `artifacts.json`;
`.dev/ep53-bounded-source.log` records source construction and pure/embedding/
Haddock checks. Accepted native results are
`.dev/candidates/bounded-source-orucrn31/`, recorded in `.dev/ep53-bounded-source-matrix-3.log`; the Nix root is
`.dev/candidates/bounded-nix-6d48opnt/`, with artifact outputs in
`.dev/ep53-bounded-nix-artifacts.json` and build log
`.dev/ep53-bounded-nix-build.log`. Public invariants, strict documentation and
format checks pass in `.dev/ep53-bounded-check.log`.

Earlier runs are retained as failures: a network timeout while refetching the
compressed native binary; process exhaustion while the unrelated 36-shard
Nagare suite ran concurrently; and Darwin SIGKILL after a private cache preloader
rewrote an executable inode in place. The accepted controller serializes native
jobs, verifies the original download digest and preloads it through a fresh
inode and atomic rename, preserving the shipped fixture's own verification.
No failed invocation is counted as a passing group.

The separate actual application/platform proof belongs to
`mori://shinzui/kansoku/plans/53-prove-shared-server-maintenance-across-deployment-platforms`.
Its local Nagare ceremony passes with the exact official Linux arm64 LTS image
and these bounded reader requests.
