#!/usr/bin/env python3
"""Run required native groups on one exact owned candidate; never use an ambient server."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def binary(target):
    return subprocess.check_output(['cabal', 'list-bin', target, '-fintegration',
                                    '-finternal-test-driver'], cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--entry', required=True)
    parser.add_argument('--group', action='append', help="Run a subset of the candidate’s declared groups")
    args = parser.parse_args()
    matrix = json.loads((ROOT / 'test/compatibility/clickhouse-matrix.json').read_text())
    matches = [entry for entry in matrix['entries'] if entry['id'] == args.entry]
    if len(matches) != 1:
        raise SystemExit('Exactly one declared matrix candidate is required')
    entry = matches[0]
    declared = entry.get('groups')
    if not isinstance(declared, list) or not declared or not all(isinstance(g, str) and g for g in declared) or len(declared) != len(set(declared)):
        raise SystemExit('Expected nonempty unique declared groups: ' + entry['id'])
    if 'image' in entry:
        context = os.environ.get('CLICKHOUSE_MIGRATE_DOCKER_CONTEXT')
        if not context:
            raise SystemExit('Set CLICKHOUSE_MIGRATE_DOCKER_CONTEXT to an isolated local Docker context')
        subprocess.run(['docker', '--context', context, 'image', 'inspect', entry['image']],
                       check=True, capture_output=True)
    parent = ROOT / '.dev/candidates'
    parent.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix=args.entry + '-', dir=parent))
    suite = binary('clickhouse-migrate-test-support:test:clickhouse-migrate-integration')
    env = dict(os.environ,
               CLICKHOUSE_MIGRATE_CANDIDATE=args.entry,
               CLICKHOUSE_MIGRATE_TEST_DRIVER=binary('clickhouse-migrate:exe:clickhouse-migrate-test-driver'),
               CLICKHOUSE_MIGRATE_EXAMPLE=binary('clickhouse-migrate-example:exe:clickhouse-migrate-example'),
               clickhouse_migrate_test_support_datadir=str(ROOT / 'clickhouse-migrate-test-support'))
    print('Required candidate:', entry['version'], entry.get('image', entry.get('sha256')), flush=True)
    print('Private evidence:', evidence, flush=True)
    groups = args.group or entry['groups']
    if any(group not in entry['groups'] for group in groups):
        raise SystemExit('Requested group is not declared for this candidate')
    for group in groups:
        print('Required group:', group, flush=True)
        result = subprocess.run([suite, group], cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=660 if group in ['consumer', 'replicated'] else 240)
        (evidence / (group + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode:
            print((result.stdout + result.stderr)[-4000:], flush=True)
            result.check_returncode()
        if 'Candidate ClickHouse ' + entry['version'] not in result.stdout:
            raise RuntimeError('Group did not identify the exact candidate')
        print(group + ': passed', flush=True)
    print(str(len(groups)) + ' required candidate groups passed; managed-cloud and packaged-consumer acceptance remain separate', flush=True)


if __name__ == '__main__':
    main()
