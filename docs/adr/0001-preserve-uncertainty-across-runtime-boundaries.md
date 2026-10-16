# Preserve uncertainty across runtime boundaries

Status: Accepted

Date: 2026-10-15

## Context

The pre-implementation review of [MasterPlan 1](../masterplans/1-bootstrap-the-initial-clickhouse-migration-library.md) found ambiguity at the transport, ledger, recovery and public API boundaries. An observed server error does not establish absence of effects. An uncertain ledger INSERT can arrive after an inspection found no event. Defining initialization and evidence types after the ledger also forces earlier plans to invent incompatible substitutes.

There is no profiled ADR bundle in this repository. This record establishes a plain Markdown convention without adding OKF metadata.

## Decision

Transport distinguishes rejection before submission, acknowledged success, observed server failure with possibly partial effects, and uncertain submission. No unsuccessful outcome permits automatic replay. A server failure remains blocking even when its response is complete. Dependency exceptions and HTTP status codes alone cannot prove that nothing was sent.

Exclusive access covers all predecessor requests, including ledger writes and initialization DDL. Before admitting a successor that may mutate, the provider must ensure the prior administrator cannot submit again and its outstanding server work has ended. A lock release, process death, timeout or absent query ID is insufficient by itself. This is an application integration obligation; v1 does not implement distributed fencing.

Reconciliation reads the exact event and full history under that guard. It distinguishes present-and-identical, conflicting, and not-observed. Not-observed alone never authorizes sequence reuse or a new initialization UUID. After externally established quiescence and revalidation, an explicit recovery operation may proceed according to the projected state; the interrupted operation never resumes automatically. Reconciliation itself is read-only. If that prerequisite cannot be met, mutation remains blocked.

The transport plan defines TargetKey, QueryId and LedgerId primitives. The ledger plan owns initialization authorization, expected ledger state (including absence), identity binding/position, audit primitives and persisted evidence levels. The runner and adoption plans consume those types. Mutable entry points require an explicit provider. Public functions accept configuration, validated plans and requests and return reports; they do not expose low-level append or raw transport capabilities. Failure results preserve partial progress and cleanup failures. Asynchronous cancellation is rethrown after bounded cleanup and is not converted to ordinary success or an obligatory JSON result.

Embedding reconstructs values through public smart constructors. It must not publish an unchecked constructor, `Lift` implementation or bridge that downstream packages can use to forge validated values. A test-only core executable exercises private transport and ledger modules for the external fixture harness; those modules do not become public API just to make tests compile.

## Consequences

Failure injection must delay a ledger write until after an empty observation, and prove that no successor mutates or reuses its sequence meanwhile. Error-response tests must preserve possible partial effects. Cross-package compile fixtures exercise authoring, embedding, caller-provided access, recovery requests and reports before the CLI is built.

The eight-child decomposition remains unchanged. First-use authorization and adoption evidence no longer create backward ownership dependencies. The host-local test provider must demonstrate predecessor cleanup or require explicit quiescence evidence after an abnormal exit; OS locking alone does not satisfy server-work exclusion.

Server affinity, completion policy and durability still require the real-server acceptance in the plans. This decision records an implementation contract, not a claim that those tests have passed.

## Evidence

[ClickHouse HTTP documentation](https://clickhouse.com/docs/concepts/features/interfaces/http) explains response-body errors and continuing queries after connection loss. [ClickHouse transaction documentation](https://clickhouse.com/docs/concepts/features/operations/insert/transactions) describes operation-dependent atomicity. These support treating failure and missing observations conservatively.

The locally inspected `Core.hs` and `Manager.hs` in `mori://snoyberg/http-client/packages/http-client` implement retry on reused connections when the configured predicate permits it. Dependency versions remain an implementation-time choice requiring registry/tag verification.
