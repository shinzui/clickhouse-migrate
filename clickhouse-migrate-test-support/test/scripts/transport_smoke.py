#!/usr/bin/env python3
"""Early real-server producer/consumer acceptance before expanding fault variants."""
import argparse
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--driver', required=True)
    args = parser.parse_args()
    script = Path(__file__).resolve().parent / 'native_fixture.py'
    matrix = script.parent.parent / 'data/clickhouse-matrix.json'
    evidence = Path(tempfile.mkdtemp(prefix='clickhouse-migrate-smoke-', dir='/tmp'))
    with (evidence / 'fixture.log').open('w') as log:
        service = subprocess.Popen([sys.executable, str(script), '--matrix', str(matrix)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        success = False
        try:
            if not select.select([service.stdout], [], [], 40)[0]:
                raise RuntimeError('Owned fixture startup watchdog expired')
            ready = json.loads(service.stdout.readline())
            def rpc(operation, **fields):
                service.stdin.write(json.dumps({'operation': operation, **fields}) + '\n')
                service.stdin.flush()
                if not select.select([service.stdout], [], [], 20)[0]:
                    raise RuntimeError('Owned fixture RPC watchdog expired')
                response = json.loads(service.stdout.readline())
                if 'result' not in response:
                    raise RuntimeError('Owned fixture operation failed')
                return response['result']
            proxy = rpc('proxy-start')
            rpc('proxy-mode', id=proxy['id'], mode='drop')
            sql = evidence / 'create.sql'
            sql.write_text('CREATE TABLE default.response_lost (id UInt8) ENGINE=Memory')
            result = subprocess.run([args.driver, 'command', proxy['endpoint'], 'lost-create-response', str(sql), '3000000', '1048576'], text=True, capture_output=True, timeout=10, check=True)
            report = json.loads(result.stdout)
            assert report['scopeError'] is None and report['cleanupErrors'] == [], report
            assert report['outcomes'][0]['outcome'] == 'submission-uncertain', report
            assert rpc('query', sql='EXISTS TABLE default.response_lost')[0]['result'] == 1
            events = rpc('proxy-events', id=proxy['id'])
            assert len(events) == 1 and events[0]['forwarded'], events
            assert 'test-password' not in json.dumps(events) + result.stdout
            print(f"ClickHouse {ready['version']}: committed effect + lost response => uncertainty; exactly one submission")
            success = True
        finally:
            if service.poll() is None:
                try:
                    service.stdin.write(json.dumps({'operation': 'stop', 'success': success}) + '\n')
                    service.stdin.flush()
                    service.communicate(timeout=20)
                except (OSError, subprocess.TimeoutExpired):
                    service.terminate()
                    service.wait(timeout=20)
            if not success:
                print(f'Early transport evidence retained at {evidence}', file=sys.stderr)
    if success:
        import shutil
        shutil.rmtree(evidence)


if __name__ == '__main__':
    main()
