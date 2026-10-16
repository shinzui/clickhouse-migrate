#!/usr/bin/env python3
"""Record explicit native assertion and local-policy adaptations of mori://shinzui/kansoku assertions.

Original source files/ranges remain untouched. The library does no SQL splitting
or assertion inference. Review these two checked-in translations before use.
"""
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent / 'clickhouse-migrate-test-support/test/fixtures/kansoku'
provenance = json.loads((root / 'provenance.json').read_text())
if 'nativeAdaptations' in provenance:
    raise SystemExit('Native adaptations already recorded; never silently regenerate')
manifest = json.loads((root / 'manifest.json').read_text())
selected = next(migration for migration in manifest['migrations'] if migration['name'] == '0017_replay_safe_sources')
adaptations = []
steps = []
for step in selected['steps']:
    if step['name'] not in ['statement-13', 'statement-14']:
        steps.append(step)
        continue
    original = (root / step['file']).read_bytes()
    if not re.sub(rb'--[^\n]*', b'', original).lstrip().startswith(b'SELECT throwIf('):
        raise SystemExit('Assertion source changed; review required')
    table = 'analytics.__chm_legacy_assert_0017_' + step['name'][-2:]
    transformations = [
        ('prepare', f'CREATE TABLE {table} (result UInt8) ENGINE=Memory;\n'.encode()),
        ('check', f'INSERT INTO {table}\n'.encode() + original),
        ('cleanup', f'DROP TABLE {table} SYNC;\n'.encode()),
    ]
    files = []
    for suffix, sql in transformations:
        name = step['name'] + '-' + suffix
        file = 'native-assertions/' + name + '.sql'
        (root / 'native-assertions').mkdir(exist_ok=True)
        (root / file).write_bytes(sql)
        steps.append({'name': name, 'file': file})
        files.append({'name': name, 'file': file, 'sha256': hashlib.sha256(sql).hexdigest()})
    adaptations.append({'sourceStep': step, 'sourceStepSha256': hashlib.sha256(original).hexdigest(), 'nativeSteps': files, 'reason': 'Standalone SELECT is outside v1. Preserve the exact throwIf query as INSERT SELECT into a named application Memory table, with explicit prepare and cleanup steps. A failure stops before cleanup and requires ordinary explicit recovery; there is no automatic SQL cleanup.'})
selected['steps'] = steps
policy_migration = next(migration for migration in manifest['migrations'] if migration['name'] == '0018_conservative_identity_resolution')
policy_step = next(step for step in policy_migration['steps'] if step['name'] == 'statement-02')
policy_original = (root / policy_step['file']).read_bytes()
if policy_original.count(b' SETTINGS mutations_sync=2') != 1:
    raise SystemExit('Protected-setting source changed; review required')
policy_sql = policy_original.replace(b' SETTINGS mutations_sync=2', b'')
policy_file = 'native-assertions/local-materialize-policy.sql'
(root / policy_file).write_bytes(policy_sql)
policy_native = {'name': policy_step['name'], 'file': policy_file}
adaptations.append({'sourceStep': dict(policy_step), 'sourceStepSha256': hashlib.sha256(policy_original).hexdigest(), 'nativeSteps': [dict(policy_native, sha256=hashlib.sha256(policy_sql).hexdigest())], 'reason': 'Remove the query-level mutations_sync=2 override. The qualified native target is one non-replicated local server and v1 always supplies its immutable mutations_sync=1 policy. This makes no replica-completion claim.'})
policy_step.update(policy_native)
provenance['nativeAdaptations'] = adaptations
provenance['nativeManifestPolicy'] = 'Original source byte ranges remain exact. The native manifest references those chunks except the three explicitly recorded native adaptations. Current native hashes establish the accepted baseline onward, never historical source-checksum verification.'
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(root / 'manifest-first.json').write_text(json.dumps(dict(manifest, migrations=manifest['migrations'][:1]), indent=2) + '\n')
(root / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
print('Recorded two assertion adaptations and one local-policy adaptation; originals unchanged')
