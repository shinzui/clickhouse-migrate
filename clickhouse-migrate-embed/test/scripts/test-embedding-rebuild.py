#!/usr/bin/env python3
"""Incremental Cabal consumer builds against independent fresh GHC splice builds."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

EMBED_ROOT = Path(__file__).resolve().parents[2]
ROOT = EMBED_ROOT.parent
FIXTURES = EMBED_ROOT / 'test/fixtures'


def command(args, cwd, log, success=True):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    if success and result.returncode:
        raise RuntimeError(f'Command failed; see {log}\n{result.stdout[-2500:]}')
    return result


def main():
    subprocess.run(['cabal', 'build', 'clickhouse-migrate', 'clickhouse-migrate-embed', 'clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build'], cwd=ROOT, check=True)
    driver = subprocess.check_output(['cabal', 'list-bin', 'clickhouse-migrate-embed:exe:clickhouse-migrate-embed-build'], cwd=ROOT, text=True).strip()
    evidence = Path(tempfile.mkdtemp(prefix='clickhouse-migrate-embedding-', dir='/tmp'))
    fixture = evidence / 'consumer'
    shutil.copytree(FIXTURES, fixture)
    project = fixture / 'cabal.project'
    project.write_text('packages:\n  .\n  ' + str(ROOT / 'clickhouse-migrate') + '\n  ' + str(ROOT / 'clickhouse-migrate-embed') + '\nindex-state: 2026-10-15T00:00:00Z\n')
    manifest = fixture / 'component/manifest.json'
    seed = fixture / 'component/sql/seed.sql'
    previous = None
    count = 0

    def check(label, changed=None):
        nonlocal previous, count
        count += 1
        log = evidence / f'{count:02d}-{label}'
        build = [driver, '--input', str(fixture), 'component/manifest.json', '--', 'build', '--project-dir=' + str(fixture), 'exe:embedding-consumer']
        command(build, fixture, log.with_suffix('.cabal.log'))
        binary = command(['cabal', 'list-bin', '--project-dir=' + str(fixture), 'exe:embedding-consumer'], fixture, log.with_suffix('.bin.log')).stdout.strip()
        observed = command([binary], fixture, log.with_suffix('.run.log')).stdout
        oracle_dir = evidence / f'oracle-{count}'
        oracle_dir.mkdir()
        oracle = oracle_dir / 'consumer'
        command(['cabal', 'exec', '--', 'ghc', '--make', '-fforce-recomp', '-XGHC2024',
                 '-package', 'clickhouse-migrate', '-package', 'clickhouse-migrate-embed',
                 '-working-dir', str(fixture), 'Main.hs', '-outputdir', str(oracle_dir), '-o', str(oracle)],
                ROOT, log.with_suffix('.oracle-build.log'))
        expected = command([str(oracle)], fixture, log.with_suffix('.oracle-run.log')).stdout
        if observed != expected:
            raise RuntimeError(f'{label}: missed rebuild; evidence at {evidence}')
        if changed is not None and (observed != previous) != changed:
            raise RuntimeError(f'{label}: unexpected definition change; evidence at {evidence}')
        previous = observed
        print(f'{label}: incremental checksum/bytes match fresh build', flush=True)
        return binary

    try:
        check('baseline')
        check('unchanged-input', False)
        # Same-size, timestamp-preserving SQL edit is the hardest early rebuild case.
        timestamp = seed.stat()
        seed.write_bytes(seed.read_bytes().replace(b'(1)', b'(2)'))
        os.utime(seed, ns=(timestamp.st_atime_ns, timestamp.st_mtime_ns))
        check('sql-preserved-time-and-size', True)
        seed.write_bytes(seed.read_bytes() + b'\n')
        check('sql-whitespace', True)
        data = json.loads(manifest.read_text())
        data['migrations'][0]['steps'].reverse()
        manifest.write_text(json.dumps(data))
        check('manifest-step-reorder', True)
        extra = fixture / 'component/sql/extra.sql'
        extra.write_bytes(b'INSERT INTO app.events VALUES (3)\n')
        data['migrations'][0]['steps'].append({'name': 'extra', 'file': 'sql/extra.sql'})
        manifest.write_text(json.dumps(data))
        check('manifest-add-reference', True)
        extra.write_bytes(extra.read_bytes().replace(b'(3)', b'(4)'))
        check('new-reference-edit', True)
        data['migrations'][0]['steps'].pop()
        manifest.write_text(json.dumps(data))
        extra.unlink()
        check('manifest-remove-reference', True)
        manifest.write_text(json.dumps(data, indent=2))
        check('manifest-whitespace', False)
        relocated = fixture / 'component/sql/relocated.sql'
        seed.rename(relocated)
        for step in data['migrations'][0]['steps']:
            if step['file'] == 'sql/seed.sql':
                step['file'] = 'sql/relocated.sql'
        manifest.write_text(json.dumps(data, indent=2))
        check('sql-file-relocation', False)
        timestamp = manifest.stat()
        manifest.write_bytes(manifest.read_bytes().replace(b'analytics', b'analyticz'))
        os.utime(manifest, ns=(timestamp.st_atime_ns, timestamp.st_mtime_ns))
        binary = check('manifest-preserved-time-and-size', True)
        # Deployed artifact must execute without source and without env SQL replacement.
        shutil.rmtree(fixture / 'component')
        env = os.environ.copy()
        env['CLICKHOUSE_MIGRATE_SQL'] = 'different SQL'
        result = subprocess.run([binary], cwd=fixture, env=env, text=True, capture_output=True, check=True)
        if result.stdout != previous:
            raise RuntimeError('Artifact changed after removing sources')
        print('source-free execution: exact compiled definitions retained', flush=True)
    except BaseException:
        print(f'Embedding evidence retained at {evidence}', flush=True)
        raise
    else:
        shutil.rmtree(evidence)
        print('All embedding rebuild cases passed', flush=True)


if __name__ == '__main__':
    main()
