# Admit direct connections and preserve request outcomes

Status: Accepted

Date: 2026-10-16

## Context

The runner cannot infer whether SQL ran from a client exception or HTTP status.
The real-server fault fixture commits SQL before dropping its response; cancellation
and an empty independent read can both precede a later commit. The inspected
`mori://snoyberg/http-client/packages/http-client` implementation also retries some
reused-connection errors by default, and its closeManager operation is a no-op.

A one-time metadata probe cannot protect a later request sent through a newly
opened connection to another server. Direct endpoints and expected persisted
server UUIDs are necessary operational constraints, not just configuration labels.

## Decision

Own a dedicated sequential HTTP manager, disable retries/redirects/environment
proxies, retain normal TLS validation, and supply the fixed completion policy and
explicit diagnostic query ID on every POST. Before returning each new socket to
the pool, probe its identity, exact supported version and effective settings on
that socket. Only the private admitted Transport can reach later ledger code.

Freeze four outcomes: positive evidence of non-submission, fully acknowledged
success, observed server failure with possibly partial effects, and submission
uncertainty. Track actual HTTP writes rather than infer non-submission from an
exception class. Validate the complete bounded response and preserve only safe
structured error codes/status; raw SQL, credentials and exception text are absent
from default diagnostics. No outcome automatically retries SQL.

Track and explicitly close owned sockets, reject escaped handles, cancel/join
in-flight scoped calls with bounded cleanup and rethrow asynchronous cancellation.
Return synchronous cleanup errors separately from the primary observation. Private
fault hooks exercise the actual cleanup path without exposing unsafe public APIs.

## Consequences

Connection admission uses http-client's internal request/response primitives on an
already owned socket, with no pool/replay path and explicit cleanup. Pin that
package exactly to 0.7.19; upgrading requires source review and fault qualification.
The production library exposes validated target configuration, not raw HTTP access.

The exact binary/platform matrix and identity limitations live in
[compatibility.md](../user/compatibility.md). This is local completion evidence, not a
claim of power-loss durability, distributed affinity or exactly-once execution.
Ledger recovery must prove all prior requests quiescent before reusing sequence
numbers or issuing successor mutations; an empty read is insufficient.
