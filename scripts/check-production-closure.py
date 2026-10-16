#!/usr/bin/env python3
"""Check component/derivation/path-info metadata; never inspect store files."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def run(args):
    return subprocess.check_output(args, cwd=ROOT, text=True)


subprocess.run(['cabal', 'build', 'clickhouse-migrate:lib:clickhouse-migrate', '-f-internal-test-driver'], cwd=ROOT, check=True)
plan = json.loads((ROOT / 'dist-newstyle/cache/plan.json').read_text())
nodes = {node['id']: node for node in plan['install-plan']}
roots = [node for node in nodes.values() if node['pkg-name'] == 'clickhouse-migrate' and node.get('component-name') == 'lib']
if len(roots) != 1:
    raise SystemExit('Expected exactly one configured production core library')
root = roots[0]
if root.get('flags', {}).get('internal-test-driver', False):
    raise SystemExit('Private driver enabled in production Cabal plan')
forbidden = {'clickhouse-migrate-embed', 'clickhouse-migrate-cli', 'clickhouse-migrate-test-support', 'postgresql-simple', 'postgresql-libpq', 'tmp-postgres', 'filelock', 'optparse-applicative'}
seen = set()
queue = [(root['id'], [])]
process_paths = []
while queue:
    identity, chain = queue.pop()
    if identity in seen:
        continue
    seen.add(identity)
    node = nodes[identity]
    name = node['pkg-name']
    if name in forbidden or name.startswith('clickhouse-migrate-example'):
        raise SystemExit('Forbidden production dependency: ' + ' -> '.join(chain + [name]))
    if name == 'process':
        process_paths.append(chain + [name])
    queue.extend((dep, chain + [name]) for dep in node.get('depends', []))
if any(nodes[dep]['pkg-name'] == 'process' for dep in root.get('depends', [])):
    raise SystemExit('Core must not directly depend on process')
print('Cabal core library:', len(seen), 'package units; optional tools excluded')
for chain in process_paths:
    print('Standard Haskell process library is transitive:', ' -> '.join(chain))

metadata = json.loads(run(['nix', 'eval', '--builders', '', '--json', '.#clickhouse-migrate', '--apply', '''p: {
  name = p.pname;
  library = map (d: d.pname or d.name) p.getCabalDeps.libraryHaskellDepends;
  flags = p.configureFlags or [];
  outputs = p.outputs;
  executable = p.isExecutable or false;
}''']))
if metadata['executable']:
    raise SystemExit('Normal core Nix output must not install an executable')
if forbidden.intersection(metadata['library']) or 'process' in metadata['library']:
    raise SystemExit('Forbidden direct Nix production library edge')
if any('internal-test-driver' in flag and not flag.startswith('-f-') for flag in metadata['flags']):
    raise SystemExit('Private driver enabled in normal Nix derivation')
subprocess.run(['nix', 'build', '--builders', '', '--no-link', '.#clickhouse-migrate'], cwd=ROOT, check=True)
# Nix supplies references as JSON. Paths are identifiers only: no path is opened,
# searched, globbed or traversed by this script.
closure = json.loads(run(['nix', 'path-info', '--recursive', '--json', '.#clickhouse-migrate']))
paths = [row['path'] for row in closure] if isinstance(closure, list) else list(closure)
excluded_fragments = ['-clickhouse-migrate-embed-', '-clickhouse-migrate-cli-', '-clickhouse-migrate-test-support-', '-clickhouse-migrate-example', '-postgresql-', '-libpq-', '-docker-', '-podman-', '-python3-', '-clickhouse-server-', '-clickhouse-migrate-test-driver']
for path in paths:
    if any(fragment in path for fragment in excluded_fragments):
        raise SystemExit('Test/optional tool in Nix production closure metadata: ' + path)
print('Nix production outputs:', ', '.join(metadata['outputs']))
print('Nix runtime closure:', len(paths), 'references; optional packages, DB/process harnesses and private driver excluded')
print('The standard transitive Haskell process library is not an installed process harness; see ADR 0009.')
