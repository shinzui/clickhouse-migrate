#!/usr/bin/env python3
"""Compile invalid manifests through the public splice; isolate all file edits."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

EMBED_ROOT = Path(__file__).resolve().parents[2]
ROOT = EMBED_ROOT.parent
FIXTURES = EMBED_ROOT / 'test/fixtures'


def main():
    evidence = Path(tempfile.mkdtemp(prefix='clickhouse-migrate-embed-errors-', dir='/tmp'))
    outside = evidence / 'outside'
    shutil.copytree(FIXTURES / 'component', outside)
    cases = ['duplicate-key', 'nested-duplicate', 'unknown-field', 'bad-version', 'empty-steps',
             'missing-file', 'parent-path', 'absolute-path', 'manifest-parent',
             'manifest-symlink', 'file-symlink', 'directory-symlink', 'escaping-ancestor-return']
    try:
        for case in cases:
            fixture = evidence / case
            shutil.copytree(FIXTURES, fixture)
            manifest = fixture / 'component/manifest.json'
            data = json.loads(manifest.read_text())
            expected = 'UnsafePath'
            if case == 'duplicate-key':
                manifest.write_text('{"component":"a","component":"b"}')
                expected = 'DuplicateKey'
            elif case == 'nested-duplicate':
                manifest.write_text('{"migrations":[{"name":"a","\\u006eame":"b"}]}')
                expected = 'DuplicateKey'
            elif case == 'unknown-field':
                data['migrations'][0]['steps'][0]['extra'] = 1
                expected = 'UnknownField'
            elif case == 'bad-version':
                data['manifestVersion'] = 2
                expected = 'UnsupportedManifestVersion'
            elif case == 'empty-steps':
                data['migrations'][0]['steps'] = []
                expected = 'InvalidDefinition'
            elif case == 'missing-file':
                data['migrations'][0]['steps'][0]['file'] = 'sql/missing.sql'
                expected = 'MissingFile'
            elif case == 'parent-path':
                data['migrations'][0]['steps'][0]['file'] = '../outside.sql'
            elif case == 'absolute-path':
                data['migrations'][0]['steps'][0]['file'] = str(fixture / 'component/sql/create.sql')
            elif case == 'manifest-parent':
                source = fixture / 'Main.hs'
                source.write_text(source.read_text().replace('component/manifest.json', '../outside/manifest.json'))
            elif case == 'manifest-symlink':
                manifest.unlink()
                manifest.symlink_to(outside / 'manifest.json')
            elif case == 'file-symlink':
                file = fixture / 'component/sql/create.sql'
                file.unlink()
                file.symlink_to(outside / 'sql/create.sql')
            elif case == 'directory-symlink':
                # Still in the package but outside the canonical manifest tree.
                (fixture / 'component/sql').rename(fixture / 'elsewhere')
                (fixture / 'component/sql').symlink_to(fixture / 'elsewhere', target_is_directory=True)
            elif case == 'escaping-ancestor-return':
                bridge = evidence / 'bridge'
                bridge.mkdir()
                (bridge / 'back').symlink_to(fixture / 'component', target_is_directory=True)
                (fixture / 'component/bridge').symlink_to(bridge, target_is_directory=True)
                data['migrations'][0]['steps'][0]['file'] = 'bridge/back/sql/create.sql'
            if case in ['unknown-field', 'bad-version', 'empty-steps', 'missing-file', 'parent-path', 'absolute-path', 'escaping-ancestor-return']:
                manifest.write_text(json.dumps(data))
            output = fixture / 'build'
            output.mkdir()
            result = subprocess.run(['cabal', 'exec', '--', 'ghc', '--make', '-fforce-recomp', '-XGHC2024',
                                     '-package', 'clickhouse-migrate', '-package', 'clickhouse-migrate-embed',
                                     '-working-dir', str(fixture), 'Main.hs', '-outputdir', str(output), '-o', str(fixture / 'consumer')],
                                    cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (fixture / 'compile.log').write_text(result.stdout)
            if result.returncode == 0 or expected not in result.stdout:
                raise RuntimeError(f'{case}: expected {expected}; see {fixture / "compile.log"}\n{result.stdout[-1500:]}')
            print(f'{case}: compilation rejects {expected}', flush=True)
    except BaseException:
        print(f'Compile-failure evidence retained at {evidence}', flush=True)
        raise
    else:
        shutil.rmtree(evidence)
        print('All 13 public manifest/path compile-failure cases passed', flush=True)


if __name__ == '__main__':
    main()
