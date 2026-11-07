#!/usr/bin/env python3
"""Resolve an immutable Linux arm64 candidate; mutate only with --write."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MATRIX = ROOT / 'clickhouse-migrate-test-support/test/data/clickhouse-matrix.json'


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--id')
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    refs = dict((ref, sha) for sha, ref in (line.split() for line in output('git', 'ls-remote', '--tags', args.repo, args.tag, args.tag + '^{}').splitlines()))
    ref = 'refs/tags/' + args.tag
    if ref not in refs:
        raise SystemExit('Tag not found: ' + args.tag + '; use the exact published upstream tag')
    context = os.environ.get('CLICKHOUSE_MIGRATE_DOCKER_CONTEXT')
    if not context:
        raise SystemExit('Set CLICKHOUSE_MIGRATE_DOCKER_CONTEXT to the isolated qualification context')
    docker = ['docker', '--context', context, 'buildx', 'imagetools', 'inspect']
    index = json.loads(output(*docker, '--raw', args.image))
    manifests = [m for m in index['manifests'] if m['platform']['os'] == 'linux' and m['platform']['architecture'] == 'arm64']
    if len(manifests) != 1:
        raise SystemExit('Expected exactly one linux/arm64 manifest')
    digest = output(*docker, '--format', '{{.Manifest.Digest}}', args.image)
    version = args.image.rsplit(':', 1)[1]
    repository = args.image.rsplit(':', 1)[0]
    entry = dict(id=args.id or 'altinity-linux-arm64-' + version.split('.')[3], version=version,
                 platform='aarch64-linux', architecture='arm64',
                 image=repository + '@' + manifests[0]['digest'], indexDigest=digest,
                 status='candidate', scope='Owned single local-server Linux container; managed-cloud qualification remains separate',
                 tag=args.tag, commit=refs.get(ref + '^{}', refs[ref]), qualification={})
    if ref + '^{}' in refs:
        entry['tagObject'] = refs[ref]
    matrix = json.loads(MATRIX.read_text())
    template = next(e for e in reversed(matrix['entries']) if e.get('image') and e.get('groups'))
    entry['groups'] = template['groups']
    entry['scope'] = template['scope']
    print(json.dumps(entry, indent=2))
    print('\nCI: docker --context "$CLICKHOUSE_MIGRATE_DOCKER_CONTEXT" pull ' + entry['image'], file=sys.stderr)
    print('\nEvidence skeleton: record tag/commit/index/manifest above, host/compiler, both artifact variants, every declared group, failures and scope limits.', file=sys.stderr)
    if args.write:
        matrix = json.loads(MATRIX.read_text())
        if any(e['id'] == entry['id'] or e['version'] == version for e in matrix['entries']):
            raise SystemExit('Candidate ID or version already exists; matrix unchanged')
        matrix['entries'].append(entry)
        MATRIX.write_text(json.dumps(matrix, indent=2) + '\n')


if __name__ == '__main__':
    main()
