#!/usr/bin/env python3
"""Record repeatable observations before promoting a replicated completion policy."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'clickhouse-migrate-test-support/test/scripts'))
from replicated_fixture import ReplicatedServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--entry', default='altinity-linux-arm64-10002')
    args = parser.parse_args()
    entry = next(e for e in json.loads((ROOT / 'test/compatibility/clickhouse-matrix.json').read_text())['entries'] if e['id'] == args.entry)
    records = []
    args.report.parent.mkdir(parents=True, exist_ok=True)
    server = ReplicatedServer(entry)
    success = False

    def record(question, case, sql, replica=0, settings=None, user='app'):
        result = server.request(replica, sql, settings, user)
        result.update(question=question, case=case, user=user)
        records.append(result)
        args.report.write_text(json.dumps(dict(candidate=entry, observations=records), indent=2) + '\n')
        print(str(question) + ' ' + case + ': HTTP ' + str(result['status']) + ' (' + str(result['elapsedSeconds']) + 's)', flush=True)
        return result

    def ok(*args, **kwargs):
        result = record(*args, **kwargs)
        if result['status'] != 200:
            raise RuntimeError(result['body'])
        return result

    none = dict(distributed_ddl_output_mode='none')
    try:
        ok(1, 'create-ledger-shape', "CREATE TABLE fixture_ledger.events (sequence UInt64, event_id UUID, ledger_id UUID, event String) ENGINE=ReplicatedMergeTree ORDER BY sequence SETTINGS fsync_after_insert=1, fsync_part_directory=1, storage_policy='default'", settings=none)
        for replica in range(2):
            for case, sql in [
                ('database', "SELECT name,engine FROM system.databases WHERE name IN ('fixture_app','fixture_ledger') ORDER BY name"),
                ('table', "SELECT engine,engine_full,sorting_key,primary_key,partition_key,sampling_key,create_table_query FROM system.tables WHERE database='fixture_ledger' AND name='events'"),
                ('server-defaults', "SELECT name,value FROM system.server_settings WHERE name IN ('default_replica_path','default_replica_name') ORDER BY name"),
                ('replication', "SELECT zookeeper_path,replica_name,total_replicas,active_replicas,is_readonly FROM system.replicas WHERE database='fixture_ledger' AND table='events'"),
                ('identity', 'SELECT toString(serverUUID()) AS server_id, version(), hostName()')]:
                ok(1, case, sql, replica)
        for mode in ['throw', 'none', 'null_status_on_timeout']:
            settings = dict(distributed_ddl_output_mode=mode)
            name = 'fixture_app.ddl_' + mode
            for phase in ['online', 'offline']:
                if phase == 'offline':
                    server.stop_replica(1)
                for command, sql in [('create', 'CREATE TABLE ' + name + ' (x UInt64) ENGINE=ReplicatedMergeTree ORDER BY x'), ('alter', 'ALTER TABLE ' + name + ' ADD COLUMN y UInt8'), ('drop', 'DROP TABLE ' + name)]:
                    record(2, mode + '-' + phase + '-' + command, sql, settings=settings)
                if phase == 'offline':
                    server.start_replica(1)
                    ok(2, mode + '-catch-up', 'SYSTEM SYNC DATABASE REPLICA fixture_app', replica=1, settings=none, user='default')
                    ok(2, mode + '-restarted-ddl-state', "SELECT name FROM system.tables WHERE database='fixture_app' AND name='ddl_" + mode + "'", replica=1)
        ok(2, 'create-mutation-table', 'CREATE TABLE fixture_app.changes (x UInt64, y UInt64) ENGINE=ReplicatedMergeTree ORDER BY x', settings=none)
        ok(2, 'seed', 'INSERT INTO fixture_app.changes VALUES (1, 1)', settings=dict(insert_quorum=2, insert_quorum_parallel=0))
        server.stop_replica(1)
        record(2, 'alter-sync-offline', 'ALTER TABLE fixture_app.changes ADD COLUMN z UInt8', settings=none)
        mutation = record(2, 'mutation-sync-offline', 'ALTER TABLE fixture_app.changes UPDATE y=2 WHERE x=1', settings=none)
        if mutation['status'] == 200 or not any('Code: ' + str(code) + '.' in mutation['body'] for code in [159, 341]):
            raise RuntimeError('Missing replica mutation did not produce its expected completion refusal')
        server.start_replica(1)
        ok(2, 'mutation-catch-up', 'SYSTEM SYNC REPLICA fixture_app.changes', replica=1, user='default')
        ok(3, 'create-insert-table', 'CREATE TABLE fixture_app.quorum (x UInt64) ENGINE=ReplicatedMergeTree ORDER BY x', settings=none)
        server.stop_replica(1)
        record(3, 'quorum-timeout', 'INSERT INTO fixture_app.quorum VALUES (7)', settings=dict(insert_quorum=2, insert_quorum_parallel=0))
        ok(3, 'local-after-timeout', 'SELECT * FROM fixture_app.quorum')
        server.start_replica(1)
        ok(3, 'insert-catch-up', 'SYSTEM SYNC REPLICA fixture_app.quorum', replica=1, user='default')
        for replica in range(2):
            record(3, 'sequential-after-restart', 'SELECT * FROM fixture_app.quorum', replica, dict(select_sequential_consistency=1, insert_quorum_parallel=0))
        # Isolate replica lag with a quorum-one write; the completed quorum's part
        # must make sequential reads fail on the deliberately stale second replica.
        ok(4, 'stop-fetches', 'SYSTEM STOP FETCHES fixture_app.quorum', replica=1, user='default')
        ok(4, 'last-quorum-part', 'INSERT INTO fixture_app.quorum VALUES (8)', settings=dict(insert_quorum=1, insert_quorum_parallel=0))
        record(4, 'lagging-sequential-read', 'SELECT * FROM fixture_app.quorum', replica=1, settings=dict(select_sequential_consistency=1, insert_quorum_parallel=0))
        ok(4, 'resume-fetches', 'SYSTEM START FETCHES fixture_app.quorum', replica=1, user='default')
        ok(4, 'lag-catch-up', 'SYSTEM SYNC REPLICA fixture_app.quorum', replica=1, user='default')
        for user in ['app', 'default']:
            record(5, 'all-replica-identities', "SELECT toString(serverUUID()) AS server_id FROM clusterAllReplicas('fixture', system.one)", user=user)
            record(5, 'cluster-members', "SELECT cluster,shard_num,replica_num,host_name FROM system.clusters WHERE cluster='fixture' ORDER BY replica_num", user=user)
        record(6, 'plain-mergetree', 'CREATE TABLE fixture_app.plain (x UInt64) ENGINE=MergeTree ORDER BY x', settings=none)
        record(6, 'explicit-keeper-path', "CREATE TABLE fixture_app.explicit (x UInt64) ENGINE=ReplicatedMergeTree('/different/path','different') ORDER BY x", settings=none)
        record(6, 'replacing-engine', 'CREATE TABLE fixture_app.replacing (x UInt64, ver UInt64) ENGINE=ReplicatedReplacingMergeTree(ver) ORDER BY x', settings=none)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(server.request, 1, 'SELECT sleep(3)', dict(query_id='chm-spike-active'))
            time.sleep(.3)
            for user in ['app', 'default']:
                record(7, 'remote-active-query', "SELECT query_id FROM clusterAllReplicas('fixture', system.processes) WHERE query_id='chm-spike-active'", user=user)
            future.result()
        for replica in range(2):
            ok(8, 'storage-policy', "SELECT disks FROM system.storage_policies WHERE policy_name='default'", replica)
            ok(8, 'storage-disks', 'SELECT name,type,is_remote,is_read_only,is_broken FROM system.disks', replica)
        success = True
    finally:
        server.close(success)


if __name__ == '__main__':
    main()
