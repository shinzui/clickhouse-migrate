# Prepare recovery metadata before authorization

Status: Accepted

Date: 2026-10-16

## Context

Individually valid audit fields can exceed the event limit after adding the full
recovery envelope. Acceptance repeats audit references as attestation evidence;
authorization also contains a separate quiescence audit. Checking only at each
append permits a locally invalid second event to follow durable authorization.

## Decision

After fresh guarded state/action validation, prepare exact authorization and any
deterministic acceptance/finalization events. Validate canonical encoded bytes,
contexts, transitions and required sequence capacity before the first write. Reuse
the prepared identities, timestamps and metadata on submission. Retry/resume bound
all possible generated SQL observation envelopes conservatively without declaring
an outcome in advance. One canonical codec owns the event-byte maximum.

Reject oversized metadata with a typed safe recovery event role. Preserve evidence
verbatim and leave the position/attempt unchanged on preparation rejection. Do not
truncate evidence, roll back recorded authorization or weaken subsequent uncertain
append handling. Callbacks still report only acknowledged events.

## Consequences

A smaller explicit request can reuse the original position after a local size
rejection. Once submission begins, receipts, one submission, blocking uncertainty,
masked acknowledgement updates and explicit recovery semantics remain unchanged.
This extends the prevalidation principle of [ADR 0008](0008-adopt-reviewed-prefixes-with-explicit-evidence.md)
to the scoped recovery contract in [ADR 0007](0007-scope-commands-and-preserve-acknowledged-progress.md).
