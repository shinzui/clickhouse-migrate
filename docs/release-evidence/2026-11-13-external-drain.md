# Explicit external-drain repair qualification, 2026-11-13

Implementation commit `f4bc4e6d32decfaaf1a19e1033a22f3e28fc167c` preserves the
strict existing API and adds an explicit required process-observation sink. See
[EP-13](../plans/13-accept-explicit-external-drain-authority-when-repair-process-diagnostics-are-unavailable.md)
and [archive identities](2026-11-13-external-drain.json).

The seven extracted sibling archives pass metadata validation, compilation,
three pure suites, Haddocks and all **41 required candidate/group cases**:
13 on native ClickHouse 26.8.28.14 and 14 each on exact Altinity
26.3.60.10001.altinitystable and 26.3.60.10002.altinitystable Linux arm64 images.
There are zero failed or skipped source cases. All 110 Haskell/Python/Cabal
source files in the archives match the committed implementation. Subsequent
unreleased changelog and repository documentation annotations change no executable
source, manifest or SQL. The witness workspace is
`/tmp/clickhouse-migrate-release-sdist-dl3yz481`; private local logs are
`.dev/ep13-distributions.log`.

The working tree separately passes `just check`, all three pure suites, the repair
and failure-boundary groups, and all 13 native LTS matrix groups. Its first Linux
group refused because the older exact image was absent from Apple Container.
After explicitly pulling that digest, the complete extracted-source matrix passes
both Linux artifacts, including Keeper/two-replica restart and recovery. This is
not a claim that the failed working-tree 41-case command completed successfully.
The matrix runner now checks every OCI prerequisite before starting native work.

Six actual scoped-role repair flows exercise denied and read-granted observations,
retry, accept, finalize and resume; strict refusal, observer failure/cancellation
and stale native positions remain covered. Interrupted recovery retains exact
pending receipts. Both real surviving-mutation cases refuse visible recorded work
even when a caller deliberately supplies positive external evidence. CLI JSON v1
golden tests remain unchanged and pass.

Linux fixtures use Apple Container 1.5.0 with exact inspected image digest/platform,
owned private mounts and inspected Keeper/replica addresses. A first smoke run
failed on absent container-name DNS before bootstrap; inspected addresses resolve
that fixture assumption. Only fixture-owned containers/process IDs are stopped.
No Colima runtime is used. CI is configured for the same runtime; no remote run is
claimed. This evidence covers exact declared server artifacts with Darwin clients;
managed-cloud, Linux clients, power-loss and Kansoku cutover remain separate gates.

Commands run inside the native development environment:

```bash
just check
just test-unit
just test-repair
just test-failure-boundaries
just test-release-matrix
just qualify-distributions
just check-public-invariants check-docs check-reviews check-format
```

Authoritative Hackage metadata for all four packages and upstream tags were
rechecked on 2026-11-13: 0.2.0.0 remains the latest published release. This qualified
source revision adds unreleased behavior; adopting it requires an explicit immutable
source selection for the complete cohort. No package version, release tag or
Hackage upload is selected by this implementation. Downstream selection and
acceptance belong to
`mori://shinzui/kansoku/plans/50-accept-portable-drain-evidence-without-cross-user-process-visibility`.


Qualification clarification: the read-granted fixture above did not run a second
user's active query to prove row isolation. Kansoku's subsequent joined test found
that SELECT on system.processes alone exposes cross-user query text on 26.8.28.14.
That fixture therefore qualifies diagnostic availability, not an enforced own-user
view. Actual isolation requires denying SELECT or an operator-owned row policy
verified against active other-user work. The delivered SDK still requires explicit
external drain authority and refuses visible recorded work. The corrected joined
application proof belongs to
`mori://shinzui/kansoku/plans/53-prove-shared-server-maintenance-across-deployment-platforms`.
