#!/usr/bin/env python3
"""Independent SHA-256 v1 reference; regenerate only for deliberate contract edits."""
import argparse
import hashlib
from pathlib import Path
import struct

POLICY = b'clickhouse-migrate/local-sync-v1;async_insert=0;mutations_sync=1;alter_sync=1'


def field(value):
    return struct.pack('>Q', len(value)) + value


def step(component, migration, name, sql):
    return (b'clickhouse-migrate/step\0v1\0' + field(POLICY)
            + field(component.encode()) + field(migration.encode())
            + field(name.encode()) + field(sql))


def migration(component, name, steps):
    return (b'clickhouse-migrate/migration\0v1\0' + field(POLICY)
            + field(component.encode()) + field(name.encode())
            + struct.pack('>Q', len(steps))
            + b''.join(field(step(component, name, key, sql)) for key, sql in steps))


def render():
    create = ('create', b'CREATE TABLE app.events (id UInt64) ENGINE=MergeTree ORDER BY id')
    insert = ('seed', b"INSERT INTO app.events VALUES (1)")
    cases = [
        ('baseline', 'analytics', '0001', [create]),
        ('whitespace', 'analytics', '0001', [(create[0], create[1] + b'\n')]),
        ('component', 'analytics2', '0001', [create]),
        ('migration', 'analytics', '0002', [create]),
        ('step-name', 'analytics', '0001', [('create2', create[1])]),
        ('two-steps', 'analytics', '0001', [create, insert]),
        ('reordered', 'analytics', '0001', [insert, create]),
        ('boundary-a', 'analytics', '0001', [(create[0], create[1] + b'\n'), insert]),
        ('boundary-b', 'analytics', '0001', [create, (insert[0], b'\n' + insert[1])]),
        ('ambiguous-a', 'a', 'bc', [create]),
        ('ambiguous-b', 'ab', 'c', [create]),
        ('unicode', 'analytics', '0001', [('seed', "INSERT INTO app.text VALUES ('雪;')".encode())]),
    ]
    lines = ['# label\tkind\tcomponent\tmigration\tsteps(name:sql-hex,...)\tinput-hex\tsha256-hex']
    for label, component, name, steps in cases:
        for kind in ['step', 'migration']:
            selected = steps[:1] if kind == 'step' else steps
            encoded = step(component, name, *selected[0]) if kind == 'step' else migration(component, name, selected)
            source = ','.join(key + ':' + sql.hex() for key, sql in selected)
            lines.append('\t'.join([label, kind, component, name, source, encoded.hex(), hashlib.sha256(encoded).hexdigest()]))
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = Path(__file__).resolve().parent.parent / 'clickhouse-migrate/test/vectors/checksum-v1.tsv'
    if args.check:
        if target.read_text() != render():
            raise SystemExit('Checksum reference vectors differ')
        print('24 independent checksum vectors verified')
    else:
        target.write_text(render())
