#!/usr/bin/env python3
"""Generate the W0.4 catalog table, preserving shared named placeholders verbatim."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path('Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges')
OUTPUT = Path('Cassini/Resources/Strings/StatusBadge.xcstrings')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
IDS = {'states.badge.' + key for key in ('recording', 'importing', 'saving', 'transcribing', 'needsAttention',
       'interrupted', 'received', 'transcribing.noEta', 'transcribing.underMinute')} | {'meeting.interruptedAt'}


def render(root=ROOT):
    folder = root / SOURCE
    pin = json.loads((folder / 'UPSTREAM.json').read_text())
    if pin['repository'] != 'https://github.com/codemyriad/cassini-ux' or not re.fullmatch(r'[a-f0-9]{40}', pin['commit']):
        raise ValueError('Invalid immutable W0.4 pin')
    for path, expected in pin['sha256'].items():
        if hashlib.sha256((folder / path).read_bytes()).hexdigest() != expected:
            raise ValueError('W0.4 pin/hash mismatch: ' + path)
    catalog = json.loads((folder / 'strings/strings.json').read_text())
    selected = [entry for entry in catalog['entries'] if entry['id'].startswith('states.badge.') or entry['id'] == 'meeting.interruptedAt']
    if {entry['id'] for entry in selected} != IDS or len(selected) != len(IDS):
        raise ValueError('Unexpected W0.4 catalog IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        locales = {}
        placeholders = set(re.findall(r'\{\w+\}', entry['en']))
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            if set(re.findall(r'\{\w+\}', value)) != placeholders:
                raise ValueError(f'Placeholder drift: {entry["id"]} {language}')
            # The current compact ETA forms produce identical text from the named template.
            # Refuse a future pin requiring argument-aware plural selection; never silently lose a form.
            for category, form in translation.get('plural', {}).items():
                for count in ([1] if category == 'one' else [2, 1_000_000]):
                    if form.replace('{n}', str(count)) != value.replace('{n}', str(count)):
                        raise ValueError(f'New plural needs runtime count selection: {entry["id"]} {language}/{category}')
            locales[language] = {'stringUnit': {'state': 'translated', 'value': value}}
        strings[entry['id']] = {'comment': f'Generated from cassini-ux {pin["commit"]}, {entry["id"]}; named placeholders stay verbatim.',
                                'extractionState': 'manual', 'localizations': locales}
    return (json.dumps({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'}, ensure_ascii=False, indent=2) + '\n').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        expected = render()
        if args.check:
            if not (ROOT / OUTPUT).exists() or (ROOT / OUTPUT).read_bytes() != expected:
                raise ValueError('Generated StatusBadge.xcstrings drift; run scripts/generate-status-badge-strings.py')
        else:
            (ROOT / OUTPUT).write_bytes(expected)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
