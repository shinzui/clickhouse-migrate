#!/usr/bin/env python3
"""Author a NEW frozen fixture from mori://shinzui/kansoku at an exact commit.

This review-time extraction is never run by embedding or migration execution.
Every byte range is recorded; reviewers must approve its statement boundaries.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def split_ranges(sql):
    """Find statement terminators outside quotes/comments, retaining every byte."""
    boundaries = []
    cursor = 0
    quote = None
    block = 0
    line = False
    while cursor < len(sql):
        char = sql[cursor:cursor + 1]
        pair = sql[cursor:cursor + 2]
        if line:
            if char == b'\n':
                line = False
        elif block:
            if pair == b'/*':
                block += 1
                cursor += 1
            elif pair == b'*/':
                block -= 1
                cursor += 1
        elif quote:
            if char == b'\\':
                cursor += 1
            elif char == quote:
                if sql[cursor + 1:cursor + 2] == quote:
                    cursor += 1
                else:
                    quote = None
        elif pair == b'--':
            line = True
            cursor += 1
        elif pair == b'/*':
            block = 1
            cursor += 1
        elif char in [b"'", b'"', b'`']:
            quote = char
        elif char == b';':
            boundaries.append(cursor + 1)
        cursor += 1
    if quote or block or not boundaries:
        raise ValueError('Unterminated source or no reviewed statement boundary')
    # The captured sources end in trivia after their last semicolon. Refuse any
    # executable suffix, rather than silently dropping an unterminated statement.
    suffix = sql[boundaries[-1]:]
    trivia = re.sub(rb'/\*.*?\*/|--[^\n]*', b'', suffix, flags=re.S)
    if trivia.strip():
        raise ValueError('Nontrivia after final statement terminator')
    boundaries[-1] = len(sql)
    return list(zip([0] + boundaries[:-1], boundaries))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-f0-9]{40}', args.revision):
        parser.error('revision must be an exact 40-character commit hash')
    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(args.source_root), *arguments])
    if git('rev-parse', args.revision + '^{commit}').decode().strip() != args.revision:
        parser.error('revision is not the exact source commit')
    if args.output.exists():
        parser.error('output already exists; never rewrite frozen evidence')
    args.output.mkdir(parents=True)
    source_paths = sorted(git('ls-tree', '-r', '--name-only', args.revision, 'db/clickhouse/migrations/').decode().splitlines())
    source_paths = [path for path in source_paths if path.endswith('.sql')]
    provenance = {'fixtureVersion': 1, 'sourceProject': 'mori://shinzui/kansoku', 'sourceRevision': args.revision, 'artifactUris': 'File-level URI pending; all source paths below are relative to sourceProject at sourceRevision.', 'evidenceLimit': 'Synthetic filename/time rows. The predecessor stored no checksums. All imported completion is operator-attested.', 'boundaryPolicy': 'Reviewed complete statements; contiguous original byte ranges, concatenating exactly to each original file. No runtime SQL splitting.', 'files': []}
    migrations = []
    rows = []
    script_path = 'db/clickhouse/migrate.sh'
    script = git('show', args.revision + ':' + script_path)
    (args.output / 'original').mkdir()
    (args.output / 'original' / 'migrate.sh').write_bytes(script)
    provenance['runner'] = {'sourcePath': script_path, 'sha256': hashlib.sha256(script).hexdigest(), 'fixturePath': 'original/migrate.sh'}
    for ordinal, path in enumerate(source_paths):
        sql = git('show', args.revision + ':' + path)
        filename = Path(path).name
        migration = Path(path).stem
        (args.output / 'original' / filename).write_bytes(sql)
        ranges = split_ranges(sql)
        directory = args.output / 'steps' / migration
        directory.mkdir(parents=True)
        steps = []
        evidence = []
        for index, (start, end) in enumerate(ranges, start=1):
            name = f'statement-{index:02}'
            relative = f'steps/{migration}/{name}.sql'
            chunk = sql[start:end]
            (args.output / relative).write_bytes(chunk)
            steps.append({'name': name, 'file': relative})
            evidence.append({'name': name, 'file': relative, 'byteStart': start, 'byteEndExclusive': end, 'sha256': hashlib.sha256(chunk).hexdigest()})
        provenance['files'].append({'sourcePath': path, 'original': 'original/' + filename, 'sha256': hashlib.sha256(sql).hexdigest(), 'migration': migration, 'steps': evidence})
        migrations.append({'name': migration, 'description': 'Reviewed complete source file ' + filename, 'steps': steps})
        rows.append({'filename': filename, 'appliedAt': f'2020-01-{ordinal + 1:02}T00:00:00Z', 'evidence': 'operator-attestation'})
        print(filename, len(steps), 'steps', flush=True)
    for name, value in [('manifest.json', {'manifestVersion': 1, 'component': 'kansoku', 'dependencies': [], 'migrations': migrations}), ('legacy-history.json', rows), ('provenance.json', provenance)]:
        (args.output / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
