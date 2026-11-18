#!/usr/bin/env python3
"""Wave 6: every compiled locale is verbatim, and iOS cannot select Android-only exclusion claims."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wave6', ROOT / 'scripts/generate-wave6-strings.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.check()
source = {e['id']: e for e in json.loads((ROOT / module.SOURCE).read_text())['entries']}
catalog = json.loads((ROOT / module.OUTPUT).read_text())['strings']
for key, entry in catalog.items():
    original = key.rsplit('.', 1)[0] if key.startswith('savedVoices.row.sampleCount.') else key
    for language in module.LANGUAGES:
        if original != key:
            form = key.rsplit('.', 1)[1]
            expected = source[original]['plural'][form] if language == 'en' else source[original]['l10n'][language]['plural'][form]
        else:
            expected = source[key]['en'] if language == 'en' else source[key]['l10n'][language]['text']
        assert entry['localizations'][language]['stringUnit']['value'] == expected, (key, language)
    assert 'this phone only' not in source[original]['en'].lower(), key
assert {'backup.phoneOnlyCard.close.a11y', 'voices.setup.title', 'voices.setup.enable',
        'voices.setup.privacy.phone', 'voices.enroll.testPhrase'} <= catalog.keys()
assert all(key not in catalog for key in ['backup.phoneOnly.body', 'backup.phoneOnlyCard.title',
           'backup.phoneOnlyCard.title.ios', 'backup.phoneOnlyCard.body', 'backup.phoneOnlyCard.action',
           'backup.phoneOnlyCard.action.ios', 'backup.phoneOnlyCard.dismiss', 'backup.cloud.title',
           'backup.cloud.body.on', 'backup.cloud.body.off.ios', 'backup.includeSavedVoices.subtitle.off',
           'backup.includeSavedVoices.subtitle.ios', 'backup.includeSavedVoices.subtitle.off.ios',
           'voices.setup.privacy.desktop'])
print('Wave 6: verbatim six-language catalog, honest iOS exclusion and one-question voice setup verified')
