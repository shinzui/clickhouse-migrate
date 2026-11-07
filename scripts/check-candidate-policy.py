#!/usr/bin/env python3
"""Fail closed when the runtime policy, matrix, CI pulls or guide drift."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def check():
    source = (ROOT / 'clickhouse-migrate/src/ClickHouseMigrate/Internal/ServerPolicy.hs').read_text()
    literal = re.search(r'^supportedVersions\s*=\s*\[([^]]*)\]', source, re.M)
    if not literal:
        raise SystemExit('Cannot parse supportedVersions')
    versions = re.findall(r'"([^"]+)"', literal[1])
    entries = json.loads((ROOT / 'clickhouse-migrate-test-support/test/data/clickhouse-matrix.json').read_text())['entries']
    expected = {e['version'] for e in entries}
    if len(versions) != len(set(versions)) or set(versions) != expected:
        raise SystemExit('Candidate policy mismatch: missing runtime versions ' + str(sorted(expected - set(versions))) + '; missing matrix versions ' + str(sorted(set(versions) - expected)))
    ci = (ROOT / '.github/workflows/ci.yml').read_text()
    pulls = [l for l in ci.splitlines() if re.search(r'\bdocker\b.*\bpull\s', l)]
    guide = (ROOT / 'docs/user/compatibility.md').read_text()
    for entry in entries:
        if entry.get('image') and not any(entry['image'] in line for line in pulls):
            raise SystemExit('Missing CI pull: ' + entry['image'])
        if entry['version'] not in guide:
            raise SystemExit('Missing compatibility documentation: ' + entry['version'])
        groups = entry.get('groups')
        if not groups or not all(isinstance(g, str) and g for g in groups) or len(groups) != len(set(groups)):
            raise SystemExit('Expected nonempty unique groups: ' + entry['id'])
    envelope = (ROOT / 'clickhouse-migrate/src/ClickHouseMigrate/Internal/SqlEnvelope.hs').read_text()
    engine_list = re.search(r'^replicatedEngines\s*=\s*\[([^]]*)\]', envelope, re.M)
    if not engine_list:
        raise SystemExit('Cannot parse replicatedEngines')
    documented = (ROOT / 'docs/user/contracts/sql-envelope-v2.md').read_text().upper()
    for engine in re.findall(r'"([^"]+)"', engine_list[1]):
        if engine not in documented:
            raise SystemExit('Missing SQL envelope engine documentation: ' + engine)
    print('Candidate policy agrees: ' + ', '.join(sorted(expected)))


if __name__ == '__main__':
    check()
