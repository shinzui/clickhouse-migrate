#!/usr/bin/env python3
"""Owned native server and fault proxies, controlled over private stdin/stdout RPC."""
import argparse
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import urllib.parse
from xml.sax.saxutils import escape

PASSWORD = 'test-password'
AUTH = 'Basic ' + base64.b64encode(('default:' + PASSWORD).encode()).decode()


def port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def binary_for(entry):
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise RuntimeError('Candidate matrix requires native Apple Silicon; Linux execution is deferred')
    cache = Path.home() / 'Library/Caches/clickhouse-migrate' / entry['version']
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / 'clickhouse'
    def digest(path):
        with path.open('rb') as source:
            return hashlib.file_digest(source, 'sha256').hexdigest()
    if binary.exists() and digest(binary) == entry['sha256']:
        return binary
    with tempfile.NamedTemporaryFile(prefix='download-', dir=cache, delete=False) as destination:
        candidate = Path(destination.name)
        try:
            with urllib.request.urlopen(entry['url'], timeout=60) as response:
                shutil.copyfileobj(response, destination)
            destination.flush()
            if digest(candidate) != entry['sha256']:
                raise RuntimeError('Server binary digest mismatch')
            candidate.chmod(0o755)
            candidate.replace(binary)
        finally:
            candidate.unlink(missing_ok=True)
    return binary


class NativeServer:
    def __init__(self, entry):
        self.entry = entry
        self.root = Path(tempfile.mkdtemp(prefix='clickhouse-migrate-server-', dir='/tmp'))
        self.port = port()
        self.tcp_port = port()
        self.binary = binary_for(entry)
        self.process = None
        self.log = (self.root / 'console.log').open('w')
        self.proxies = []
        self.keep = True
        for directory in ['data', 'tmp', 'user_files', 'format_schemas']:
            (self.root / directory).mkdir()
        users = self.root / 'users.xml'
        users.write_text('''<clickhouse><profiles><default><max_threads>2</max_threads><async_insert>1</async_insert><wait_for_async_insert>0</wait_for_async_insert><async_insert_busy_timeout_ms>10000</async_insert_busy_timeout_ms><mutations_sync>0</mutations_sync><alter_sync>0</alter_sync><fsync_metadata>0</fsync_metadata><max_result_rows>1</max_result_rows><result_overflow_mode>break</result_overflow_mode><max_block_size>1</max_block_size></default></profiles>
<users><default><password>test-password</password><networks><ip>127.0.0.1</ip></networks>
<profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
<quotas><default><interval><duration>3600</duration><queries>0</queries><errors>0</errors>
<result_rows>0</result_rows><read_rows>0</read_rows><execution_time>0</execution_time></interval></default></quotas></clickhouse>''')
        root = escape(str(self.root))
        (self.root / 'config.xml').write_text(f'''<clickhouse>
<logger><level>warning</level><log>{root}/server.log</log><errorlog>{root}/error.log</errorlog></logger>
<path>{root}/data/</path><tmp_path>{root}/tmp/</tmp_path><user_files_path>{root}/user_files/</user_files_path>
<format_schema_path>{root}/format_schemas/</format_schema_path><users_config>{root}/users.xml</users_config>
<listen_host>127.0.0.1</listen_host><http_port>{self.port}</http_port><tcp_port>{self.tcp_port}</tcp_port>
<max_connections>64</max_connections><max_thread_pool_size>128</max_thread_pool_size>
<background_schedule_pool_size>8</background_schedule_pool_size><background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size>
<background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size>
<background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size>
<background_pool_size>16</background_pool_size><background_move_pool_size>2</background_move_pool_size>
<background_fetches_pool_size>2</background_fetches_pool_size><background_common_pool_size>2</background_common_pool_size>
<mark_cache_size>0</mark_cache_size><uncompressed_cache_size>0</uncompressed_cache_size>
</clickhouse>''')
        try:
            self.process = subprocess.Popen([str(self.binary), 'server', '--config-file', str(self.root / 'config.xml')], stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError('Owned server exited before readiness')
                try:
                    with urllib.request.urlopen(self.endpoint + '/ping', timeout=.2) as response:
                        if response.read() == b'Ok.\n':
                            break
                except OSError:
                    pass
                time.sleep(.05)
            else:
                raise RuntimeError('Owned server readiness deadline expired')
            identity = self.query('SELECT version() AS version, toString(serverUUID()) AS server_id')[0]
            version = identity['version']
            if identity['server_id'] != (self.root / 'data/uuid').read_text().strip():
                raise RuntimeError('Endpoint is not the owned server data directory')
            if version != entry['version']:
                raise RuntimeError('Candidate server version mismatch')
        except BaseException:
            print(f"Owned server failure evidence: {self.root}", file=sys.stderr, flush=True)
            self.close(False)
            raise

    @property
    def endpoint(self):
        return f'http://127.0.0.1:{self.port}'

    def query(self, sql):
        request = urllib.request.Request(self.endpoint + '/?default_format=JSONEachRow&wait_end_of_query=1', data=sql.encode(), headers={'Authorization': AUTH}, method='POST')
        with urllib.request.urlopen(request, timeout=10) as response:
            return [json.loads(line) for line in response.read().splitlines() if line.strip()]

    def restart(self):
        """Kill/restart only this owned process, preserving its data/config/UUID."""
        if self.process is not None and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
        self.process = subprocess.Popen([str(self.binary), 'server', '--config-file', str(self.root / 'config.xml')], stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Owned restarted server exited')
            try:
                identity = self.query('SELECT version() AS version, toString(serverUUID()) AS server_id')[0]
                if identity['version'] == self.entry['version'] and identity['server_id'] == (self.root / 'data/uuid').read_text().strip():
                    return
            except OSError:
                pass
            time.sleep(.05)
        raise RuntimeError('Owned server restart deadline expired')

    def close(self, success):
        for proxy in self.proxies:
            proxy.close()
        if self.process is not None and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.log.close()
        if success:
            shutil.rmtree(self.root)


class FaultProxy:
    def __init__(self, target, tls=False):
        self.target = target
        self.tls = tls
        self.mode = 'pass'
        self.query_id = None
        self.stage = None
        self.step = None
        self.rules = []
        self.release = threading.Event()
        self.identity_spoof = False
        self.closed = False
        self.events = []
        self.open_connections = 0
        self.lock = threading.Lock()
        proxy = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def setup(self):
                super().setup()
                with proxy.lock:
                    proxy.open_connections += 1
            def finish(self):
                try:
                    super().finish()
                finally:
                    with proxy.lock:
                        proxy.open_connections -= 1
            def log_message(self, *args):
                pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                with proxy.lock:
                    stage = None
                    step = None
                    if body.startswith(b'CREATE DATABASE IF NOT EXISTS '):
                        stage = 'ddl-database'
                    elif body.startswith(b'CREATE TABLE IF NOT EXISTS '):
                        stage = 'ddl-table'
                    elif b'FORMAT JSONEachRow\n' in body:
                        try:
                            payload = json.loads(body.split(b'FORMAT JSONEachRow\n', 1)[1])
                            event = json.loads(payload['event'])
                            stage = event['kind']
                            context = event.get('context') or {}
                            step = (context.get('step') or {}).get('name')
                        except (ValueError, KeyError, TypeError):
                            pass
                    if stage is None and body.lstrip().startswith((b'CREATE ', b'ALTER ', b'INSERT ', b'DROP ', b'TRUNCATE ', b'RENAME ')):
                        stage = 'application-sql'
                    mode = proxy.mode
                    if proxy.stage is not None and stage != proxy.stage:
                        mode = 'pass'
                    query_id = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get('query_id', [''])[0]
                    if proxy.query_id is not None and query_id != proxy.query_id:
                        mode = 'pass'
                    if proxy.step is not None and step != proxy.step:
                        mode = 'pass'
                    for rule in proxy.rules:
                        if rule['stage'] == stage and (rule.get('step') is None or rule['step'] == step):
                            mode = rule['mode']
                    if mode == 'delay-first':
                        mode = 'delay' if not proxy.events else 'pass'
                    if mode == 'close-second':
                        mode = 'pass' if not proxy.events else 'close'
                    event_index = len(proxy.events)
                    proxy.events.append({'path': self.path, 'mode': mode, 'stage': stage, 'connection': self.client_address[1], 'forwarded': mode not in ['redirect', 'close', 'hold-before']})
                if mode == 'close':
                    self.close_connection = True
                    return
                if mode == 'redirect':
                    self.send_response(307)
                    self.send_header('Location', proxy.redirect_url)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                if mode == 'hold-before':
                    if not proxy.release.wait(timeout=15):
                        self.close_connection = True
                        return
                    with proxy.lock:
                        proxy.events[event_index]['forwarded'] = True
                upstream = http.client.HTTPConnection('127.0.0.1', target.port, timeout=20)
                try:
                    upstream.request('POST', self.path, body=body, headers={'Authorization': self.headers.get('Authorization', ''), 'Content-Type': 'text/plain'})
                    response = upstream.getresponse()
                    data = response.read()
                    headers = dict(response.getheaders())
                    status = response.status
                finally:
                    upstream.close()
                if mode == 'drop':
                    self.close_connection = True
                    return
                if mode == 'delay':
                    time.sleep(2)
                if proxy.identity_spoof and data.strip():
                    rows = [json.loads(line) for line in data.splitlines() if line.strip()]
                    if rows and 'server_id' in rows[0]:
                        rows[0]['server_id'] = '00000000-0000-0000-0000-000000000000'
                        data = b''.join(json.dumps(row).encode() + b'\n' for row in rows)
                if mode in ['unsupported-version', 'prerelease-version', 'weakened-policy']:
                    rows = [json.loads(line) for line in data.splitlines() if line.strip()]
                    if mode == 'unsupported-version':
                        rows[0]['version'] = '26.8.28.15'
                    elif mode == 'prerelease-version':
                        rows[0]['version'] = '26.8.28.14-rc1'
                    else:
                        rows[0]['mutations_sync'] = 0
                    data = b''.join(json.dumps(row).encode() + b'\n' for row in rows)
                if mode == 'weakened-storage' and data.strip():
                    rows = [json.loads(line) for line in data.splitlines() if line.strip()]
                    for row in rows:
                        if 'is_remote' in row:
                            row['is_remote'], row['type'] = 1, 'ObjectStorage'
                    data = b''.join(json.dumps(row).encode() + b'\n' for row in rows)
                if mode == 'late-error':
                    status, data = 200, b'Code: 999. DB::Exception: SQL_SECRET_MARKER (SYNTHETIC_ERROR)\n'
                self.send_response(status)
                for name in ['X-ClickHouse-Exception-Code', 'Content-Type']:
                    if name in headers:
                        self.send_header(name, headers[name])
                if mode == 'switch-identity':
                    proxy.identity_spoof = True
                    self.send_header('Connection', 'close')
                    self.close_connection = True
                self.send_header('Content-Length', str(len(data) + (20 if mode == 'truncate' else 0)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                    self.wfile.flush()
                except OSError:
                    pass
                if mode == 'truncate':
                    self.close_connection = True
        self.http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        if tls:
            cert = target.root / ('proxy-cert-' + str(self.http.server_port) + '.pem')
            key = target.root / ('proxy-key-' + str(self.http.server_port) + '.pem')
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-keyout', str(key), '-out', str(cert), '-subj', '/CN=localhost',
                            '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            self.http.socket = context.wrap_socket(self.http.socket, server_side=True)
        self.http.daemon_threads = True
        self.http.block_on_close = False
        self.redirect_url = self.endpoint
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()

    @property
    def endpoint(self):
        return f'{"https" if self.tls else "http"}://127.0.0.1:{self.http.server_port}'

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.release.set()
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)


def serve(matrix, entry_id):
    entries = json.loads(Path(matrix).read_text())['entries']
    entry = next(value for value in entries if value['id'] == entry_id)
    server = NativeServer(entry)
    def stop_signal(*_):
        raise SystemExit(1)
    signal.signal(signal.SIGTERM, stop_signal)
    print(json.dumps({'endpoint': server.endpoint, 'root': str(server.root), 'version': entry['version']}), flush=True)
    success = False
    try:
        for line in sys.stdin:
            request = json.loads(line)
            operation = request['operation']
            try:
                if operation == 'restart':
                    server.restart()
                    result = None
                elif operation == 'query':
                    result = server.query(request['sql'])
                elif operation == 'proxy-start':
                    proxy = FaultProxy(server, bool(request.get("tls", False)))
                    server.proxies.append(proxy)
                    result = {'id': len(server.proxies)-1, 'endpoint': proxy.endpoint}
                elif operation == 'proxy-stop':
                    server.proxies[request['id']].close()
                    result = None
                elif operation == 'proxy-mode':
                    proxy = server.proxies[request['id']]
                    with proxy.lock:
                        proxy.mode = request['mode']
                        proxy.query_id = request.get('queryId')
                        proxy.stage = request.get('stage')
                        proxy.step = request.get('step')
                        proxy.rules.clear()
                        proxy.release.clear()
                    result = None
                elif operation == 'proxy-rule':
                    proxy = server.proxies[request['id']]
                    with proxy.lock:
                        proxy.rules.append(request)
                    result = None
                elif operation == 'proxy-release':
                    server.proxies[request['id']].release.set()
                    result = None
                elif operation == 'proxy-open-connections':
                    proxy = server.proxies[request['id']]
                    with proxy.lock:
                        result = proxy.open_connections
                elif operation == 'proxy-events':
                    proxy = server.proxies[request['id']]
                    with proxy.lock:
                        result = list(proxy.events)
                elif operation == 'proxy-redirect':
                    server.proxies[request['id']].redirect_url = request['endpoint']
                    result = None
                elif operation == 'stop':
                    success = bool(request['success'])
                    print(json.dumps({'result': None}), flush=True)
                    break
                else:
                    raise RuntimeError('Unknown fixture operation')
                print(json.dumps({'result': result}), flush=True)
            except Exception:
                print(json.dumps({'fixtureError': 'owned-fixture-operation-failed'}), flush=True)
    finally:
        server.close(success)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--matrix', required=True)
    parser.add_argument('--entry', default='lts-native')
    options = parser.parse_args()
    serve(options.matrix, options.entry)
