---
type: Reference
title: "SQL envelope v2"
description: "Author replicated table engines while preserving lexical SQL boundaries."
docId: DOC-15
tags: ["contracts", "sql", "replication"]
generated:
  by: process:codex
  at: 2026-11-07T14:47:03Z
---

# SQL envelope v2

This supersedes [v1](sql-envelope-v1.md), retaining its UTF-8, literal, comment,
statement-boundary and command-family rules. It permits these unquoted engines
only directly after `ENGINE` or `ENGINE =` in CREATE TABLE or CREATE MATERIALIZED
VIEW: `ReplicatedMergeTree`, `ReplicatedReplacingMergeTree`,
`ReplicatedAggregatingMergeTree`, `ReplicatedSummingMergeTree`,
`ReplicatedCollapsingMergeTree`, and `ReplicatedVersionedCollapsingMergeTree`.
The optional first engine argument must not be a string literal. For example,
`ReplicatedReplacingMergeTree(ver)` is accepted. Explicit Keeper paths and replica
names, other replicated words, quoted engine spellings, `ON CLUSTER`, `Distributed`
and remote table functions remain outside the envelope. SQL is never rewritten.

For pending replicated work, additional completion settings are protected identifiers, alongside the original
`async_insert`, `mutations_sync` and `alter_sync`: `insert_quorum`,
`insert_quorum_parallel`, `insert_quorum_timeout`, `distributed_ddl_output_mode`,
`distributed_ddl_task_timeout`, `replication_wait_for_inactive_replica_timeout` and
`select_sequential_consistency`. Migrations cannot override completion or its waits.
Binding remains a strict extension of v1, and direct targets keep accepting previously valid SQL. Replicated preflight rejects pending overrides with `invalid-runtime-plan` before bootstrap or application writes. Existing valid SQL bytes keep their existing v1 digest.

A replicated run rejects pending CREATE DATABASE steps with
`database-creation-on-replicated-target` after reading the existing prefix and
before bootstrap or application writes. Applied migrations are excluded from this
check. Operators precreate every application and ledger database as `Replicated`.
This is a lexical envelope; authors remain responsible for SQL semantics and for
using the precreated replicated databases.
