# Retain HTTP transport and revisit ClickHaskell

Status: Accepted

Date: 2026-10-16

## Context

The [initial specification](../initial-spec.md#8-transport-and-target-identity)
selected direct HTTP to keep migrations independent of an application's analytics
client. [ADR 0005](0005-admit-direct-connections-and-preserve-request-outcomes.md)
records the resulting transport contract and fault qualification. The original
decision did not document a comparative evaluation of ClickHaskell; this record
adds that evaluation rather than attributing it to the initial selection.

`mori://KovalevDima/ClickHaskell/packages/ClickHaskell` is a credible native TCP
alternative. Reusing a driver could reduce the transport code maintained here.
Our HTTP implementation has its own maintenance cost: it uses internal
request/response primitives and pins http-client exactly. Existing fault tests
provide evidence for its behavior, not proof of superiority over another driver.

On 2026-10-16, [Hackage preferred versions](https://hackage.haskell.org/package/ClickHaskell/preferred.json)
and upstream tags identified ClickHaskell 1.1.0 as the current release. Tag
`v1.1.0` in `mori://KovalevDima/ClickHaskell/repos/ClickHaskell` resolves to
`4524fbdd08cd0cf4a3468180323cbf6c4cf5667b`. Inspection of that release found:

- Exception cleanup reconnects before restoring the connection-state MVar. A
  cancellation can therefore initiate a new handshake; if reconnection throws,
  later use can block indefinitely on the empty MVar. This reconnect path does
  not itself replay the failed SQL operation.
- There is no public connection-close operation, and connection initialization
  lacks exception-safe socket cleanup around authentication.
- Query packets use an empty query ID, with no public per-query ID argument for
  the explicit diagnostic IDs required by our transport contract.

The inspected project-relative sources are `library/ClickHaskell.hs`,
`library/ClickHaskell/Connection.hs` and
`library/ClickHaskell/Protocol/Client.hs` under
`mori://KovalevDima/ClickHaskell` (source-file artifact URIs pending).
The lifecycle defect and an existing consumer repair are tracked at
`mori://KovalevDima/ClickHaskell/upstream-issues/connection-lifecycle-cancellation`.
This is a source review, not a run of our migration fault suite against ClickHaskell.

## Decision

Retain the qualified HTTP transport for now. Revisit ClickHaskell as its released
lifecycle and query-control APIs mature; maturity means demonstrated capabilities,
not a particular age or version number. This decision does not permanently exclude
a native adapter or justify maintaining custom transport code indefinitely.

A future evaluation should verify current Hackage releases and upstream tags,
review the released source, and establish:

- Exception-safe initialization, explicit socket disposal and bounded cancellation
  without reconnecting during exception cleanup or stranding connection state.
- Explicit per-query IDs, enforced completion settings and server identity/version
  admission on every new physical connection, including reconnections.
- Preservation of the four transport outcomes and the prohibition on automatic SQL
  replay. A lost acknowledgement must remain uncertain even with a native driver.
- Equivalent fault coverage for committed effects with lost responses, interrupted
  reads, deadlines, cancellation, cleanup and reconnection, plus ledger and recovery
  integration coverage. Compare maintenance costs after identifying required changes.

Keep any adapter behind the internal transport boundary so plan, checksum, ledger
and recovery contracts remain stable. Record a replacement decision with the
resulting evidence before adopting it.

## Consequences

We continue to own HTTP transport maintenance and dependency upgrade qualification.
ClickHaskell remains an explicit candidate for reducing that burden once its APIs
and fault-test results satisfy the migration contract. Neither transport removes
the possibility that SQL completed after the client lost contact with the server.
