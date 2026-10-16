# Initial library release evidence

Qualification date: 2026-10-16. Local implementation EP1–7 is qualified; EP8 final
qualification is in progress. This is a releasable-artifact assessment, not a Hackage
publication, deployment, remote CI run or completion of the external consumer cutover.
Linux builders are deferred at the user's request. No persistent application database
or external repository was modified.

## Exact scope

The only claimed server is **26.8.28.14 LTS**, official **aarch64-darwin** binary,
SHA-256 `ab5a04de4a6b705e0f1f02e6a0e0a44feff8b4455b6dfcc4a03b7571f98fbb60`,
release `v26.8.28.14-lts`, tag object `cb8b2f96f32feb4203ab9edbf4f03b274bbb6952`,
source commit `3694fe07040369cef78c937311cbaac5f0555484`.
The [packaged matrix](../test/compatibility/clickhouse-matrix.json) is authoritative.
The official [support policy](https://github.com/ClickHouse/ClickHouse/security/policy)
and [release](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.8.28.14-lts)
were rechecked on this date: 26.8 is supported. This does not qualify other supported
series or future patches. Runtime admission accepts this exact version only;
operators must install the recorded platform/digest, which a version probe cannot attest.

Compiler is **GHC 9.12.4**, base 4.21.2.0, GHC2024. Cabal's dated plan resolves
http-client **0.7.19**, http-client-tls **0.4.0**, Aeson **2.3.2.0**, optparse-applicative
**0.19.0.0**. The pinned Nix dependency set separately resolves http-client **0.7.19**,
http-client-tls **0.3.6.4**, Aeson **2.2.4.1**, optparse-applicative **0.18.1.0**.
Both artifact variants require the same native cases; source/release evidence is in
[dependencies](dependencies.md). No managed Seihou pins changed.

Requirements: one direct persistently identified self-managed server; Atomic ledger
namespace, exact immutable MergeTree event schema; default policy on healthy writable
Local disks; explicit `async_insert=0`, `mutations_sync=1`, `alter_sync=1`,
`wait_end_of_query=1`, metadata/part fsync and complete bounded reads. Qualification
uses deliberately weak defaults to verify every request overrides them.
No Cloud, production HTTP proxy, failover/distributed/replicated topology, Linux,
broader compiler/patch compatibility, exactly-once SQL, atomic SQL/ledger commit,
general schema equality or power-loss durability claim is made.

## Section 19 acceptance mapping

All commands below run inside `nix develop --builders ''`. `just test-release-matrix`
builds opt-in artifacts and executes twelve required groups serially, failing a
missing/unavailable candidate instead of skipping. Each group owns new temporary
server/data/process/port resources. Cabal, Nix and extracted sibling distributions
must execute these same cases. Successful fixtures clean only their own roots;
failed roots/logs are preserved. Earlier failing attempts are not passing evidence.

| Section 19 criterion | Command and exact fixture | Evidence/status |
| --- | --- | --- |
| Invalid names, duplicates, empty/comment SQL, UTF-8, dependency/order/cycle refusal | `just test-unit`; core Main/SqlEnvelopeTests | EP2 passed |
| Caller order, local naming and independent libraries | core/public Valid; `just test-example`; separate catalog/analytics libraries | Core passed; executable final qualification pending |
| SQL literal/comment/heredoc separators, protected settings, forbidden forms | core SqlEnvelopeTests; real consumer replay | EP2/7 passed |
| Deterministic checksum vectors, ambiguous concatenation, order/whitespace/excluded descriptions/paths | `just check-public-invariants`; 24 frozen independent vectors | EP2 passed |
| Manifest/SQL incremental rebuild including preserved times | `just test-embedding`; positive and compile-fail fixtures | EP3 passed |
| Fresh up and no-op second run | `runner`, `example` groups; independent effect/request counts | Runner passed; executable final qualification pending |
| Missing recurring ledger; explicit target/UUID initialization | `ledger`, `runner`, `cli` groups | Ledger/runner passed; CLI final qualification pending |
| Changed applied SQL/order/unknown definitions/corruption/schema before SQL | `ledger`, `runner` groups | EP5/6 passed |
| Every section 11 interruption boundary, no implicit replay | `boundaries`, `repair`, `adoption` groups; all callbacks and dependent appends | EP6/7 passed |
| Committed SQL with lost response blocks ordinary up | `transport`, `runner`, `cli` groups | EP4/6 passed; CLI final qualification pending |
| Intent/success/completion/repair/adoption acknowledgements and reconciliation | `ledger`, `boundaries`, `repair`, `adoption`, `cli` groups; exact receipts | EP5/6/7 passed; CLI final qualification pending |
| Local ALTER/mutation/synchronous INSERT on each claimed series | `completion`, `consumer` groups; stopped merges and visible effects | Sole exact native patch passed |
| Late HTTP error/truncation/timeouts/redirect/reuse no false success/replay | `transport` group | EP4 passed |
| Administrative exclusion and access loss stops writes | `exclusive`, `boundaries`; separate processes, persistent host-local markers, live check | EP5/6 passed |
| Query survives interruption; recovery requires quiescence | `completion`, `survivors`, `adoption`; real active mutation/delayed ledger request | EP4/6/7 passed |
| Actual process/server crash recovery and explicit storage limits | `ledger`, `survivors`, `example`; owned SIGKILL/restart and client termination | Core passed; example final qualification pending; no power-loss claim |
| Every repair, stale refusal, checkpoints and interrupted audit authorization | `repair`/RepairBoundaries, `cli` groups | EP6 passed; CLI final qualification pending |
| Finalize successful steps without SQL replay | `repair`, `cli`, `example`; independent request counts | EP6 passed; CLI/example final qualification pending |
| Filename-only adoption weaker attestation, no SQL | `adoption`, `consumer`, `cli`, `example` | EP7 passed; CLI/example final qualification pending |
| Duplicate/holey/conflicting mappings; identical-batch interrupted resume | core AdoptionTests; `adoption` and `cli` groups | EP7 passed; CLI final qualification pending |
| Separate real consumer runner replacement | `mori://shinzui/kansoku`, separately authorized workflow | **OPEN — external repository cutover not performed** |
| Captured real consumer fresh replay/adoption/new migration | `consumer`; frozen immutable revision/provenance with 25 files, 253 source statements, 257 native steps, 25 rows and one new native step | EP7 passed in Nix and extracted distributions |
| Composition/authoring/CLI/target/access/maintenance/recovery/adoption guides | README, authoring.md, cli.md, operations.md, adoption.md | Written; final example/build checks pending |
| Executable two-library example | `example` group; three independent private packages | Final qualification pending |
| Ledger/checksum/manifest/adoption/JSON schemas and error codes | docs/contracts, error-codes.md; pure vectors and CLI golden cases | Existing schemas passed; four CLI goldens passed |
| Redaction and callback/cleanup failures | `boundaries`, `adoption`, `cli`, `example`; pure CLI goldens; capture stdout/stderr separately | Core/adoption passed; CLI/example final qualification pending |
| Test tooling absent from production package closure | `just check-production-closure`; Cabal library graph, Nix derivation/path-info metadata | Final qualification pending; standard transitive Haskell process library reported separately |

The captured consumer source is `mori://shinzui/kansoku`, revision
`138d9a316931bbf46781757a29ab6c7fdd90f870`, project-relative
`db/clickhouse/migrate.sh` and `db/clickhouse/migrations/` (file-level URIs pending).
Provenance retains all original bytes/ranges and separately records three reviewed
native adaptations. Real filename/time history has no stored source checksum;
current file hashes are not stronger historical evidence. The fixture's synthetic
history and controlled schema observations do not close the external runner gate.

## Reproducible package gates

`just check-packages` checks all four public packages and three private example
packages. `just test-unit` runs core, embedding and CLI suites. `just haddock` uses
the content-qualified embedding wrapper. `just qualify-distributions` creates seven
archives in a new temporary workspace, extracts siblings with a dated Cabal project,
checks metadata, builds the opt-in driver/suite/example, runs pure tests and Haddocks,
then all twelve native groups. Native Nix qualification uses `.#integration-tests`,
`.#internal-test-driver` and `.#example` with explicit artifact overrides to the same
matrix script. Default Nix checks never start servers. `nix flake check --builders ''`,
formatting, public invariant negatives, independent digest vectors and Seihou managed
file drift are separate gates.

The closure checker never opens/traverses store paths. It uses Cabal component
edges, Nix derivation fields and `nix path-info` JSON reference identifiers. Core
has no embed/CLI/test-support/example/PostgreSQL dependency, fixture executable,
Python/container runner or private driver in its normal outputs. The HTTP stack's
standard Haskell `process` library is transitive via streaming-commons; it is not
an installed process harness, and the checker does not claim its absence. ADR 0009
records why replacing the qualified TLS/transport stack for that claim is unwarranted.

Future CI is configured for native arm64 macOS only. It has not run, and no remote
project availability is assumed. No release tag, push, Hackage upload or deployment
has been performed. Full initiative completion remains contingent on the explicitly
open external cutover above.
