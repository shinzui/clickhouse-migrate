---
type: Guide
title: "Mounting the CLI"
description: "Mount reusable migration commands with application-owned configuration, output, and exit policy."
docId: DOC-4
tags: ["cli", "integration", "adoption"]
generated:
  by: human:nadeem
  at: 2026-10-16T17:20:17Z
---

# Mounting the CLI

`clickhouse-migrate-cli` is a library. Mount `commandParser` beneath your application's
parser, or use `parseInvocation` for redacted parse diagnostics. `commandInfo` provides
standalone optparse help. The parser returns `Invocation format command`; it does not
load migration files or credentials. `handleCommand environment compiledPlan command`
returns a `CommandResult`. Supply `commandEnvironment` with optional target config,
optional externally serialized provider, event sink, diagnostic policy and either
`ReadOnlyCommands` or `AdministrativeCommands`. Offline plan does not evaluate the
environment. Remote inspection does not initialize. Mutations require a provider.
Guarded observations require one too. No reusable command owns stdout or process exit.

Use `renderJson` or `renderText` after normal return. Send progress to a separate
application sink. Async exceptions propagate after bounded cleanup; do not promise
final JSON on cancellation. Redacted parser failures do not echo arbitrary arguments.
When mounting optparse directly, choose your own redaction for its richer errors;
the handler repeats validation for programmatically constructed commands.

Commands and safety inputs:

| command | required inputs / behavior |
| --- | --- |
| `plan [--json]` | Offline compiled definitions, hashes and explicit execution schedule |
| `status`, `history` | Remote observation; optional `--guarded` |
| `verify` | Optional `--require-current`, `--guarded`; pending is compatible, not current; no schema-equality proof |
| `up` | `--expect-target`, `--actor`, `--reason`; explicit `--initialize-ledger UUID` only for first use |
| `repair resume`, `finalize` | Target, fresh `--expect-position`, current `--attempt`, actor/reason, repeated `--evidence`, `--quiescent` |
| `repair retry-step`, `accept-step` | Same plus original `--step-attempt`, `--step`, exact `--query-id` |
| `adopt plan`, `apply`, `resume` | Target, `--expect-position` or `--expect-absent`, actor/reason/evidence/quiescence, explicit `--request FILE`; absence also requires retained initialization UUID |

Use `--json` at the leaf command. `up --quiescent` additionally requires evidence;
it may supply an assertion to an application coordinator, but the coordinator must
actually exclude all administrators and establish full predecessor drain. Repair
can retain repeated `--pending-append RECEIPT`. Adoption preview performs bounded
explicit file I/O and remote observation, then validates the complete batch before
any initialization. Apply/resume reread/revalidate under the core's fresh guard.
There are no force/reset/mark-clean/checksum-rewrite commands.

See [the executable example](../../examples/two-components/README.md),
[authoring](authoring.md), [operations](operations.md), [adoption](adoption.md),
[JSON v1](contracts/json-v1.md) and [errors](error-codes.md).

## Adoption input v1

The request file contains evidence, never runnable definitions. Only the explicit
`--request` path is read, bounded to 16 MiB. Unknown fields, duplicate keys (including
escaped aliases), malformed/trailing JSON and nesting beyond 64 fail closed. Core
limits additionally bound all rows, references, historical bytes and ledger events.

```json
{
  "schemaVersion": 1,
  "source": "retained-predecessor-identity",
  "snapshotReference": "immutable-evidence/snapshot",
  "rows": [{"id": "001.sql", "appliedAt": "2020-01-01", "checksum": null}],
  "mappings": [{
    "row": "001.sql", "component": "catalog", "migration": "0001",
    "checksum": "<current compiled migration SHA-256>",
    "evidence": {"level": "operator-attestation", "references": ["review/complete-prefix"]}
  }]
}
```

Replace the placeholder with the exact lowercase hash from offline plan. Every
source row must be mapped once, in source order, to a complete native prefix.
Rows may instead retain `checksum:{"algorithm":"sha256","digest":"<stored hash>"}`.
Only with an actual retained source checksum may a mapping use
`level:"predecessor-checksum"` and `historicalBytesHex` (lowercase hex of those
historical bytes). The core verifies the historical digest; current file hashes
alone cannot promote evidence. Attested evidence forbids `historicalBytesHex`.
No optional field implicitly imports SQL or grants administrative authority.
