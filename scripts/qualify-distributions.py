#!/usr/bin/env python3
"""Build seven sibling source archives and run the complete owned native matrix."""
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
packages = ['clickhouse-migrate', 'clickhouse-migrate-embed', 'clickhouse-migrate-cli', 'clickhouse-migrate-test-support', 'clickhouse-migrate-example-catalog', 'clickhouse-migrate-example-analytics', 'clickhouse-migrate-example']
workspace = Path(tempfile.mkdtemp(prefix='clickhouse-migrate-release-sdist-', dir='/tmp'))
print('Source archive qualification workspace:', workspace, flush=True)
subprocess.run(['cabal', 'sdist', 'all', '--output-directory', str(workspace)], cwd=ROOT, check=True)
for package in packages:
    with tarfile.open(workspace / (package + '-0.1.0.0.tar.gz')) as archive:
        archive.extractall(workspace, filter='data')
    subprocess.run(['cabal', 'check'], cwd=workspace / (package + '-0.1.0.0'), check=True)
(workspace / 'cabal.project').write_text('packages: ' + ' '.join(package + '-0.1.0.0' for package in packages) + '\nindex-state: 2026-10-15T00:00:00Z\n')
wrapper = ['cabal', 'run', 'clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build', '--']
for package, manifest in [
    ('clickhouse-migrate-embed', 'test/fixtures/component/manifest.json'),
    ('clickhouse-migrate-test-support', 'test/fixtures/kansoku/manifest.json'),
    ('clickhouse-migrate-test-support', 'test/fixtures/kansoku/manifest-first.json'),
    ('clickhouse-migrate-example-catalog', 'migrations/manifest.json'),
    ('clickhouse-migrate-example-analytics', 'migrations/manifest.json'),
]:
    wrapper += ['--input', package + '-0.1.0.0', manifest]
wrapper += ['--']
flags = ['-fintegration', '-finternal-test-driver']
subprocess.run(wrapper + ['build', 'all', 'clickhouse-migrate-integration', *flags], cwd=workspace, check=True)
subprocess.run(wrapper + ['test', 'clickhouse-migrate-unit', 'clickhouse-migrate-embed-test', 'clickhouse-migrate-cli-test', '--test-show-details=direct', *flags], cwd=workspace, check=True)
subprocess.run(wrapper + ['haddock', 'all', *flags], cwd=workspace, check=True)

def binary(target):
    return subprocess.check_output(['cabal', 'list-bin', target, *flags], cwd=workspace, text=True).strip()

info = {'workspace': str(workspace), 'suite': binary('clickhouse-migrate-integration'), 'driver': binary('clickhouse-migrate-test-driver'), 'example': binary('clickhouse-migrate-example'), 'data': str(workspace / 'clickhouse-migrate-test-support-0.1.0.0')}
(workspace / 'artifacts.json').write_text(json.dumps(info, indent=2) + '\n')
env = dict(os.environ, CLICKHOUSE_MIGRATE_SUITE=info['suite'], CLICKHOUSE_MIGRATE_TEST_DRIVER=info['driver'], CLICKHOUSE_MIGRATE_EXAMPLE=info['example'], clickhouse_migrate_test_support_datadir=info['data'])
subprocess.run(['python3', str(ROOT / 'scripts/test-release-matrix.py')], cwd=workspace, env=env, check=True)
print('Seven archives, metadata, three pure suites, Haddocks and twelve native groups passed:', workspace, flush=True)
