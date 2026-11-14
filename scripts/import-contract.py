#!/usr/bin/env python3
"""Vendor immutable import policy; --update REF reads origin/main, never working-tree bytes."""
import argparse, hashlib, importlib.util, json, plistlib, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
RESOURCE = Path('Packages/CassiniEngine/Sources/CassiniEngine/Resources/import-types.json')
PIN = ROOT / 'contracts/import-types/UPSTREAM.json'
VALIDATOR = ROOT / 'contracts/import-types/validate_import_types.py'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--update', type=Path)
a = p.parse_args()
if a.update:
    commit = subprocess.check_output(['git', '-C', str(a.update), 'rev-parse', 'origin/main'], text=True).strip()
    payload = subprocess.check_output(['git', '-C', str(a.update), 'show', commit + ':contract/import-types.json'])
    (ROOT / RESOURCE).parent.mkdir(parents=True, exist_ok=True)
    (ROOT / RESOURCE).write_bytes(payload)
    PIN.parent.mkdir(parents=True, exist_ok=True)
    validator = subprocess.check_output(['git', '-C', str(a.update), 'show', commit + ':contract/validate_import_types.py'])
    VALIDATOR.write_bytes(validator)
    PIN.write_text(json.dumps(dict(repository='https://github.com/codemyriad/cassini-ux', commit=commit,
        path='contract/import-types.json', sha256=hashlib.sha256(payload).hexdigest(),
        validator_path='contract/validate_import_types.py', validator_sha256=hashlib.sha256(validator).hexdigest()), indent=2) + '\n')
payload = (ROOT / RESOURCE).read_bytes()
assert hashlib.sha256(payload).hexdigest() == json.loads(PIN.read_text())['sha256'], 'import policy pin drift'
policy = json.loads(payload)
assert policy['version'] == '2026-11-14.3', 'import policy version drift'
assert hashlib.sha256(VALIDATOR.read_bytes()).hexdigest() == json.loads(PIN.read_text())['validator_sha256'], 'import validator pin drift'
spec = importlib.util.spec_from_file_location('import_types', VALIDATOR)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
assert validator.validate(policy) == [], validator.validate(policy)
# This import release and the current full catalogs are one coordinated upstream pin.
import_pin = json.loads(PIN.read_text())
shared = json.loads((ROOT / 'contracts/shared-strings/UPSTREAM.json').read_text())
wave5 = json.loads((ROOT / 'contracts/wave5-strings/UPSTREAM.json').read_text())
markdown = json.loads((ROOT / 'Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/markdown/UPSTREAM.json').read_text())['files']['strings.json']
assert shared['commit'] == wave5['commit'] == markdown['source_commit'] == import_pin['commit'], 'current contract/string commits differ'
assert shared['sha256'] == wave5['sha256'] == markdown['source_sha256'], 'current full string hashes differ'
utis = list(dict.fromkeys(u for t in policy['types'] if t['status'] == 'decided' for u in t['utis']))
info_path = ROOT / 'Cassini/Resources/Info.plist'
info = plistlib.loads(info_path.read_bytes())
declarations = []
for entry in policy['types']:
    if entry['status'] != 'decided':
        continue
    for index, uti in enumerate(entry['utis']):
        if not uti.startswith('org.xiph.'):
            continue
        declarations.append(dict(UTTypeIdentifier=uti, UTTypeDescription=entry['label'],
            UTTypeConformsTo=['public.audio'], UTTypeTagSpecification={
                'public.filename-extension': [entry['extensions'][index].lstrip('.')],
                'public.mime-type': entry['mimeTypes']}))
if a.update:
    info['CFBundleDocumentTypes'][0]['LSItemContentTypes'] = utis
    info['UTImportedTypeDeclarations'] = declarations
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
assert info['CFBundleDocumentTypes'][0]['LSItemContentTypes'] == utis, 'Open-with declarations drift'
assert info['UTImportedTypeDeclarations'] == declarations, 'Imported audio declarations drift'
print('import contract pin and Open-with declarations: OK')
