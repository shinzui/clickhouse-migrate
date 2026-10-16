# Structured error codes

All codes below are lowercase stable strings in [JSON v1](contracts/json-v1.md).
Inspect category and evidence/detail fields as well as the code. No error code
implicitly grants replay, initialization, recovery or adoption authority. Raw server
messages and arbitrary exception text are absent. HTTP/server numeric codes are
optional diagnostics, not a no-effects guarantee. The complete primary error and
separate secondary errors remain available together.

| family | operator meaning |
| --- | --- |
| command | Invalid/missing explicit input, configuration, provider or policy; dispatch refused |
| access | Coordinator acquisition/liveness/release failure; already submitted work can survive |
| transport | Request admission, response completion or bounded cleanup failure |
| ledger | Schema, identity, canonical sequence or state refusal |
| adoption | Invalid evidence/mapping/prefix or stale/conflicting batch |
| run | Scoped execution, inspection, recovery or callback failure with retained report |

## Command

`invalid-arguments`, `missing-target-configuration`, `missing-exclusive-access`, `command-not-allowed`, `expected-target-mismatch`, `invalid-audit-input`, `quiescence-required`, `recovery-evidence-required`, `invalid-repair-input`, `initialization-required`, `invalid-adoption-input`, `input-unavailable`, `input-too-large`, `invalid-json-input`, `duplicate-json-key`, `unsupported-input-version`.

## Access

`invalid-access-strategy`, `acquisition-timed-out`, `acquisition-failed`, `access-lost`, `access-scope-closed`, `access-action-failed`, `predecessor-quiescence-required`, `access-release-failed`, `access-release-timed-out`.

## Transport

`administrative-access-lost`, `invalid-request`, `client-scope-failed`, `connection-failed`, `deadline-expired`, `response-interrupted`, `response-too-large`, `unexpected-response`, `server-rejected`, `redirect-rejected`, `server-identity-mismatch`, `unsupported-server`, `completion-policy-mismatch`, `cleanup-failed`, `cleanup-timed-out`.

## Ledger

`invalid-position`, `invalid-audit`, `invalid-evidence`, `invalid-event`, `unsupported-ledger-version`, `sequence-gap`, `sequence-conflict`, `event-identity-conflict`, `ledger-identity-mismatch`, `missing-initialization`, `impossible-transition`, `definition-mismatch`, `invalid-ledger-schema`, `unsupported-ledger-storage`, `ledger-absent`, `ledger-uninitialized`, `initialization-not-authorized`, `stale-ledger-state`, `unresolved-history`, `outstanding-requests`, `ledger-limit-exceeded`.

## Adoption

`invalid-source-evidence`, `unsupported-source-checksum`, `invalid-source-checksum`, `duplicate-source-row`, `duplicate-mapping`, `incomplete-mapping`, `unknown-source-row`, `mapping-order-mismatch`, `mapping-definition-mismatch`, `historical-checksum-mismatch`, `historical-checksum-required`, `adoption-target-mismatch`, `adoption-initialization-required`, `adoption-expected-state-mismatch`, `adoption-native-conflict`, `adoption-batch-conflict`, `adoption-resume-required`, `adoption-batch-too-large`.

## Run

`invalid-runtime-plan`, `ledger-namespace-in-sql`, `definition-too-large`, `target-failed`, `ledger-request-failed`, `initialization-failed`, `sql-failed`, `callback-failed`, `incompatible-history`, `verification-not-current`, `audit-too-large`, `ledger-required`, `existing-ledger-binding-required`, `stale-position`, `attempt-mismatch`, `step-attempt-mismatch`, `repair-not-allowed`, `prior-queries-active`, `cleanup-failed`, `unexpected-runtime-failure`.

## Repair refusal reason

`no-active-migration`, `adoption-in-progress`, `uncertain-step-remains`, `no-pending-steps`, `selected-step-is-resolved`, `steps-not-resolved`, `conflicting-append`, `wrong-quiescence-target`.

Access/ledger/adoption failures at runtime use their specific family code directly
inside category `run` or `inspection`. `target-failed` also includes transport detail;
`ledger-request-failed`, `initialization-failed` and `sql-failed` preserve one of
`positive-non-submission`, `observed-server-failure` or `submission-uncertain`.
`ledger-request-failed` retains an exact pending append receipt when available.
A delayed append may arrive after a NotObserved reconciliation.

`verification-not-current` means compatible history still has pending migrations.
`incompatible-history` exposes typed issues and never claims schema drift detection.
`stale-position`/`attempt-mismatch` require a fresh guarded observation and review,
not a blind retry. `callback-failed` may follow completed SQL or a durable append.
`cleanup-failed` cannot erase the primary effect/report. A secondary recording failure
means the failure record itself did not receive a trustworthy acknowledgement.
