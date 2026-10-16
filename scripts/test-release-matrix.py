#!/usr/bin/env python3
"""Run every required native group serially; never skip an unavailable candidate."""
import json
import fcntl
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parent.parent
GROUPS = ['transport', 'completion', 'ledger', 'exclusive', 'runner', 'repair', 'boundaries', 'survivors', 'adoption', 'consumer', 'cli', 'example']
matrix = json.loads((ROOT / 'test/compatibility/clickhouse-matrix.json').read_text())
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('Only aarch64-darwin is qualified; Linux builders are deferred')
if len(matrix['entries']) != 1 or matrix['entries'][0]['id'] != 'lts-native':
    raise SystemExit('Update runner to enumerate every declared candidate; refusing silent skips')
entry = matrix['entries'][0]
print('Required native release matrix:', entry['version'], entry['tag'], entry['sha256'], flush=True)
# Explicit overrides permit Nix and extracted-source artifacts to run the SAME
# cases. Otherwise resolve already built Cabal artifacts from this project.
def binary(variable, target, flags=()):
    if variable in os.environ:
        return os.environ[variable]
    return subprocess.check_output(['cabal', 'list-bin', target, *flags], cwd=ROOT, text=True).strip()

suite = binary('CLICKHOUSE_MIGRATE_SUITE', 'clickhouse-migrate-test-support:test:clickhouse-migrate-integration', ['-fintegration'])
driver = binary('CLICKHOUSE_MIGRATE_TEST_DRIVER', 'clickhouse-migrate:exe:clickhouse-migrate-test-driver', ['-finternal-test-driver'])
example = binary('CLICKHOUSE_MIGRATE_EXAMPLE', 'clickhouse-migrate-example:exe:clickhouse-migrate-example')
env = dict(os.environ, CLICKHOUSE_MIGRATE_TEST_DRIVER=driver, CLICKHOUSE_MIGRATE_EXAMPLE=example)
if 'CLICKHOUSE_MIGRATE_SUITE' not in os.environ:
    env.setdefault('clickhouse_migrate_test_support_datadir', str(ROOT / 'clickhouse-migrate-test-support'))
# Serialize independent artifact variants on this host. This is only fixture-job
# coordination, never a production administrative provider or proof of drain.
with (Path('/tmp') / 'clickhouse-migrate-native-release.lock').open('a') as gate:
    fcntl.flock(gate, fcntl.LOCK_EX)
    for group in GROUPS:
        print('Required case:', group, flush=True)
        subprocess.run([suite, group], cwd=ROOT, env=env, check=True)
print('All twelve native groups passed; no external consumer cutover, remote CI or publication implied', flush=True)
