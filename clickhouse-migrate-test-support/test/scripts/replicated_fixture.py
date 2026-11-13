#!/usr/bin/env python3
"""Owned Keeper plus two replicas; no shared server or container network."""
import base64
import http.client
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.parse
import uuid

from native_fixture import NativeServer, PASSWORD, port, verify_apple_image


class RoundRobin:
    def __init__(self, replicas):
        self.replicas = replicas
        self.next = 0
        self.lock = threading.Lock()
        owner = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                with owner.lock:
                    target = owner.replicas[owner.next % len(owner.replicas)]
                    owner.next += 1
                try:
                    with socket.create_connection(('127.0.0.1', target.port), timeout=2) as upstream:
                        peers = [self.request, upstream]
                        while True:
                            ready, _, _ = select.select(peers, [], [], 1)
                            if not ready:
                                if owner.closed:
                                    return
                                continue
                            for source in ready:
                                data = source.recv(65536)
                                if not data:
                                    return
                                (upstream if source is self.request else self.request).sendall(data)
                except OSError:
                    return
        class Listener(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True
        self.closed = False
        self.server = Listener(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = 'http://127.0.0.1:' + str(self.server.server_address[1])

    def close(self):
        self.closed = True
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class ReplicatedServer:
    def __init__(self, entry):
        if 'image' not in entry:
            raise RuntimeError('Replicated fixture requires an OCI candidate')
        self.entry = entry
        self.root = Path(tempfile.mkdtemp(prefix='clickhouse-migrate-replicated-', dir='/tmp'))
        self.runtime = ['container']
        verify_apple_image(entry)
        self.network = 'clickhouse-migrate-' + uuid.uuid4().hex
        self.keeper = None
        self.replicas = []
        self.proxy = None
        self.closed = False
        try:
            subprocess.run(self.runtime + ['network', 'create', '--label', 'clickhouse-migrate.fixture=owned', self.network], check=True, capture_output=True)
            keeper_name = self.network + '-keeper'
            self.keeper = keeper_name
            keeper_config = self.root / 'keeper.xml'
            keeper_config.write_text('''<clickhouse><logger><level>warning</level><console>true</console></logger>
<listen_host>0.0.0.0</listen_host><keeper_server><tcp_port>9181</tcp_port><server_id>1</server_id>
<log_storage_path>/fixture/log</log_storage_path><snapshot_storage_path>/fixture/snapshots</snapshot_storage_path>
<coordination_settings><operation_timeout_ms>10000</operation_timeout_ms><session_timeout_ms>10000</session_timeout_ms></coordination_settings>
<raft_configuration><server><id>1</id><hostname>localhost</hostname><port>9234</port></server></raft_configuration>
</keeper_server></clickhouse>''')
            keeper_port = port()
            subprocess.run(self.runtime + ['run', '--detach', '--name', keeper_name,
                '--network', self.network, '--label', 'clickhouse-migrate.fixture=owned',
                '--user', str(os.getuid()), '-p', f'127.0.0.1:{keeper_port}:9181',
                '--memory', '512m', '--platform', 'linux/' + entry['architecture'],
                '--volume', str(self.root) + ':/fixture', '--entrypoint', '/bin/sh',
                entry['image'], '-c', 'exec sleep 2147483647'], check=True, capture_output=True, timeout=60)
            self.keeper_log = (self.root / 'keeper.log').open('w')
            self.keeper_process = subprocess.Popen(self.runtime + ['exec', keeper_name, 'clickhouse', 'keeper', '--config-file=/fixture/keeper.xml'], stdout=self.keeper_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if self.keeper_process.poll() is not None:
                    raise RuntimeError('Keeper exited before readiness')
                try:
                    with socket.create_connection(('127.0.0.1', keeper_port), timeout=.2) as connection:
                        connection.sendall(b'ruok')
                        if connection.recv(4) == b'imok':
                            break
                except OSError:
                    pass
                time.sleep(.05)
            else:
                raise RuntimeError('Keeper readiness deadline expired')
            names = [self.network + '-r1', self.network + '-r2']
            for name in names:
                self.replicas.append(NativeServer(entry, dict(name=name, network=self.network, config='', defer_start=True)))
            def address(name):
                inspected = json.loads(subprocess.check_output(['container', 'inspect', name], text=True))[0]
                return inspected['status']['networks'][0]['ipv4Address'].split('/')[0]
            addresses = [address(name) for name in names]
            keeper_address = address(keeper_name)
            cluster = '<remote_servers><fixture><shard>' + ''.join('<replica><host>' + ip + '</host><port>9000</port><user>default</user><password>' + PASSWORD + '</password></replica>' for ip in addresses) + '</shard></fixture></remote_servers>'
            for i, replica in enumerate(self.replicas):
                extra = cluster + '<zookeeper><node><host>' + keeper_address + '</host><port>9181</port></node></zookeeper><macros><cluster>fixture</cluster><shard>1</shard><replica>r' + str(i + 1) + '</replica></macros><interserver_http_port>9009</interserver_http_port><interserver_http_host>' + addresses[i] + '</interserver_http_host><distributed_ddl><path>/clickhouse/task_queue/ddl</path></distributed_ddl>'
                config = replica.root / 'config.xml'
                config.write_text(config.read_text().replace('</clickhouse>', extra + '</clickhouse>'))
                replica.ready()
                (self.root / 'replicas.json').write_text(json.dumps([dict(replica='r' + str(n + 1), root=str(r.root), endpoint=r.endpoint) for n, r in enumerate(self.replicas)], indent=2) + '\n')
            # Administrative bootstrap exactly mirrors consumer infrastructure.
            for database in ['fixture_app', 'fixture_ledger']:
                result = self.request(0, "CREATE DATABASE " + database + " ON CLUSTER fixture ENGINE=Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')", user='default')
                if result['status'] != 200:
                    raise RuntimeError('Bootstrap: ' + result['body'])
            for replica in self.replicas:
                replica.query("CREATE USER app IDENTIFIED WITH plaintext_password BY 'test-password' SETTINGS database_replicated_allow_only_replicated_engine = 1 CONST")
                replica.query('GRANT SELECT, INSERT, CREATE TABLE, CREATE VIEW, ALTER TABLE, DROP TABLE, DROP VIEW, TRUNCATE ON *.* TO app')
            self.proxy = RoundRobin(self.replicas)
            self.endpoint = self.proxy.endpoint
        except BaseException:
            self.close(False)
            raise

    def request(self, replica, sql, settings=None, user='app'):
        settings = {**dict(default_format='JSONEachRow', wait_end_of_query=1, async_insert=0, mutations_sync=2, alter_sync=2, fsync_metadata=1,
                          max_result_rows=0, max_result_bytes=0, result_overflow_mode='throw', read_overflow_mode='throw',
                          distributed_ddl_task_timeout=5, replication_wait_for_inactive_replica_timeout=5, insert_quorum_timeout=5000), **(settings or {})}
        connection = http.client.HTTPConnection('127.0.0.1', self.replicas[replica].port, timeout=15)
        auth = 'Basic ' + base64.b64encode((user + ':' + PASSWORD).encode()).decode()
        started = time.monotonic()
        try:
            connection.request('POST', '/?' + urllib.parse.urlencode(settings), sql.encode(), {'Authorization': auth})
            response = connection.getresponse()
            body = response.read().decode()
            headers = dict(response.getheaders())
            return dict(endpoint=self.replicas[replica].endpoint, replica='r' + str(replica + 1), sql=sql, settings=settings, status=response.status, headers=headers, body=body, elapsedSeconds=round(time.monotonic() - started, 3))
        finally:
            connection.close()

    def query(self, sql):
        return self.replicas[0].query(sql)

    def stop_replica(self, replica):
        self.replicas[replica].stop(signal.SIGKILL)

    def start_replica(self, replica):
        target = self.replicas[replica]
        target.restart()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                databases = target.query('SELECT is_readonly FROM system.database_replicas')
                tables = target.query('SELECT is_readonly FROM system.replicas')
                if databases and all(row['is_readonly'] == 0 for row in databases + tables):
                    return
            except OSError:
                pass
            time.sleep(.05)
        raise RuntimeError('Restarted replicated databases remained read-only; fixture failed without restart retry')

    def close(self, success):
        if self.closed:
            return
        self.closed = True
        if self.proxy:
            self.proxy.close()
        for replica in reversed(self.replicas):
            replica.close(success)
        if self.keeper:
            logs = subprocess.run(self.runtime + ['logs', self.keeper], capture_output=True, text=True)
            (self.root / 'keeper-container.log').write_text(logs.stdout + logs.stderr)
            subprocess.run(self.runtime + ['delete', '--force', self.keeper], capture_output=True, timeout=15)
            if hasattr(self, 'keeper_process'):
                self.keeper_process.wait(timeout=10)
                self.keeper_log.close()
        subprocess.run(self.runtime + ['network', 'delete', self.network], capture_output=True, timeout=15)
        if success:
            shutil.rmtree(self.root)
        else:
            print('Replicated fixture evidence: ' + str(self.root), file=__import__('sys').stderr, flush=True)
