# clickhouse-migrate-cli

Mount `commandParser` or use `parseInvocation`, then pass the application-owned
environment and compiled plan to `handleCommand`. The application chooses configuration,
exclusive-access provider, event/diagnostic sinks, command policy, stdout and exit code.
The reusable library performs no implicit environment/secret loading or process exit.
Offline plan never evaluates the environment; mutations require a provider.

Includes plan, status, history, verify with require-current, up with explicit retained
initialization UUID, all four repair operations, and adoption preview/apply/resume.
No force/reset/checksum-rewrite operations. Repair/adoption validate explicit audit,
expected state and quiescence/evidence before core dispatch. Adoption reads only an
explicit bounded strict JSON evidence file; executable SQL comes from the compiled plan.

`renderJson` returns one schemaVersion 1 document without a newline. The caller writes
it after normal return and keeps progress on a separate sink. Synchronous failures
retain primary cause, latest acknowledged report, query/receipt identities and separate
secondary errors. Cancellation is rethrown and may produce no final JSON. Default
text/JSON excludes SQL, credentials and raw exception bodies. Frozen golden fixtures
ship under test/golden; the workspace's docs/contracts/json-v1.md defines the wire format.
