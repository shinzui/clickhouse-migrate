# Mount CLI with owned policy and native release evidence

Status: Accepted

Date: 2026-10-16

## Context

Applications need one command surface around their compiled plan without delegating
secret loading, output streams, process exit or administrative coordination to a
library. Uncertain SQL and ledger responses must retain core evidence through JSON
rendering. Source distributions and optional Nix outputs need the same native cases.
Linux builders and remote CI execution are deferred by the user; the repository is
not available remotely. The separate external consumer cutover is still open.

## Decision

Expose composable optparse parsers, input/result types, application-supplied handler
environment, and explicit text/JSON renderers. The core exposes read-only target
key/binding and provider description accessors; none grants a live capability.
Validate safety inputs in both parser adapter and handler; no implicit config,
migration discovery, printing or process exit. Configuration and providers are never
part of serializable reports. Keep initialization/repair/adoption authorization
explicit, and revalidate under core scopes. Adoption input is bounded strict v1 JSON
with duplicate/unknown field refusal and historical bytes only as evidence.

Freeze [JSON v1](../user/contracts/json-v1.md), explicit exhaustive encoders and independent
goldens. Preserve primary failure, latest acknowledged report, separate local SQL
observations, exact append receipts and secondary cleanup/observer/recording failures.
UInt64 event sequences are decimal strings. Distinguish accepted/operator-attested
from observed completion and verified predecessor bytes. Default output omits SQL,
credentials and raw exceptions. Async exceptions propagate; no final document is
promised after interruption. The executable owns streams, diagnostics and exit policy.

Use two separately embedded example libraries and an application-owned executable.
The example's host-local adapter is explicitly developmental, preserves dirty markers
and requires actual external quiescence before successor entry. Its dependencies do
not become core dependencies. Qualify only the exact native Apple Silicon LTS patch
in the matrix, using the same twelve serial groups for Cabal, Nix and extracted sibling
source artifacts. CI configuration is future reproducibility, not a claim of a run.
Never publish artifacts or change an external consumer as an incidental release check.

Check production boundaries from Cabal component edges, Nix derivation metadata and
Nix path-info references, without reading/traversing store files. Exclude optional
embed/CLI/test-support/examples, PostgreSQL, fixture servers, Python/container/process
harnesses and the private driver. **Do not claim the standard Haskell `process` library
is transitively absent**: the already selected http-client depends on streaming-commons,
whose library includes process utilities. Hackage source 0.2.3.1 confirms the unconditional
edge; this is not an installed runner/test harness or a new core direct dependency.
Preserve verified TLS and the qualified no-replay transport rather than replacing it
to make a misleading dependency count. The checker reports this transitive edge and
fails any direct core process dependency. This narrows the plan's overly broad
"process dependencies only in test scopes" wording to actual harness/tool isolation.

## Consequences

A new wire-visible domain state must be explicitly encoded, documented and tested.
Applications must supply real exclusion/drain evidence; flags and types cannot prove
that promise. No Linux, Cloud, distributed/replicated, broad patch or power-loss claim
follows from native process/server kill tests. The external runner replacement at
`mori://shinzui/kansoku` remains a separate authorized workflow and release gate.
