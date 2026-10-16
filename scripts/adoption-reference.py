#!/usr/bin/env python3
"""Independent adoption-v1 digest fixtures; no Haskell implementation is imported."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def u64(number):
    return struct.pack('>Q', number)


def field(value):
    return u64(len(value)) + value


def text(value):
    return field(value.encode())


def items(encode, values):
    return u64(len(values)) + b''.join(encode(value) for value in values)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def render():
    policy = b'clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1'
    sql = b'CREATE TABLE default.adoption (id UInt8) ENGINE=Memory'
    step = b'clickhouse-migrate/step\0v1\0' + field(policy) + text('app') + text('one') + text('create') + field(sql)
    migration = b'clickhouse-migrate/migration\0v1\0' + field(policy) + text('app') + text('one') + u64(1) + field(step)
    definition = {'ordinal': 0, 'componentIndex': 0, 'component': 'app', 'dependencies': [], 'migration': 'one', 'checksum': sha(migration), 'steps': [{'name': 'create', 'checksum': sha(step)}]}
    canonical = json.dumps(definition, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
    definitions = sha(b'[' + canonical + b']')
    result = []
    for verified in [False, True]:
        historical = sha(b'actual historical bytes')
        row = text('001.sql') + text('2020-01-01T00:00:00Z') + (u64(1) + text('sha256') + text(historical) if verified else u64(0))
        snapshot_bytes = b'clickhouse-migrate/adoption-snapshot\0v1\0' + text('legacy-fixture') + text('fixture:immutable-snapshot') + u64(1) + row
        snapshot = sha(snapshot_bytes)
        refs = ['source:legacy-fixture', 'snapshot-evidence:fixture:immutable-snapshot', 'source-row:001.sql']
        refs += ['historical-algorithm:sha256', 'historical-checksum:' + historical, 'fixture:predecessor-checksum'] if verified else ['fixture:reviewed-step-mapping']
        entry = text('001.sql') + field(canonical) + u64(1 if verified else 0) + items(text, refs)
        mapped_bytes = b'clickhouse-migrate/adoption-mapping\0v1\0' + text(snapshot) + u64(1) + entry
        result.append({'level': 'predecessor-checksum' if verified else 'operator-attestation', 'snapshotInputHex': snapshot_bytes.hex(), 'snapshot': snapshot, 'mappingInputHex': mapped_bytes.hex(), 'mapping': sha(mapped_bytes), 'definitionsInputHex': (b'[' + canonical + b']').hex(), 'definitions': definitions})
    return json.dumps(result, indent=2) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = Path(__file__).resolve().parent.parent / 'clickhouse-migrate/test/vectors/adoption-v1.json'
    if args.check:
        if target.read_text() != render():
            raise SystemExit('Adoption-v1 vectors differ')
        print('Two independent adoption-v1 snapshot/mapping/definition vectors verified')
    else:
        target.write_text(render())
