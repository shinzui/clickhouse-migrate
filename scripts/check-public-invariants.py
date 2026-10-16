#!/usr/bin/env python3
"""Compile a real exposed-module consumer and reject representation bypasses."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
fixtures = root / 'clickhouse-migrate/test/public'
subprocess.run(['cabal', 'build', 'clickhouse-migrate'], cwd=root, check=True)
with tempfile.TemporaryDirectory(prefix='clickhouse-migrate-public-') as directory:
    common = ['cabal', 'exec', '--', 'ghc', '-XGHC2024', '-XOverloadedStrings',
              '-package', 'clickhouse-migrate', '-outputdir', directory]
    executable = str(Path(directory) / 'consumer')
    subprocess.run([*common, str(fixtures / 'Valid.hs'), '-o', executable], cwd=root, check=True)
    subprocess.run([executable], check=True)
    for file, expected in [
        ('Constructor.hs', 'SqlStep'), ('Coercion.hs', 'Coercible'),
        ('Generic.hs', 'Generic'), ('Deserialize.hs', 'Read SqlStep'),
        ('Optic.hs', 'stepSql'), ('Private.hs', 'hidden module'),
        ('LedgerConstructor.hs', 'LedgerPosition'), ('PrivateLedger.hs', 'hidden module'),
        ('MissingProvider.hs', 'ExclusiveAccess'), ('MissingQuiescence.hs', 'QuiescenceEvidence'),
    ]:
        result = subprocess.run([*common, '-fno-code', str(fixtures / file)],
                                cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        # GHC's coercion error may report mismatching representations without
        # spelling the Coercible constraint. Both establish the intended failure.
        alternatives = [expected] if file != 'Coercion.hs' else ['Coercible', 'representation', 'match type']
        if result.returncode == 0 or not any(term in result.stdout for term in alternatives):
            raise SystemExit(f'{file}: expected invariant failure, got:\n{result.stdout}')
        print(f'{file}: rejected as expected')
print('Public composition runs; all ten core/ledger invariant bypasses rejected')
