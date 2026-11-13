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
LOOKUP = Path('Cassini/Strings/StatusBadgeStrings.swift')
STRINGS_PIN = Path('contracts/shared-strings/UPSTREAM.json')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
IDS = ({'states.badge.' + key for key in ('recording', 'importing', 'saving', 'transcribing', 'needsAttention',
        'interrupted', 'received', 'transcribing.noEta', 'transcribing.underMinute')} | {'meeting.interruptedAt'} |
       {'states.phone.' + key for key in ('audioOnly', 'cantPlay', 'cantReadTranscript', 'couldntTranscribe',
        'newerFormat', 'pausedAt', 'queued')})


def render(root=ROOT):
    folder = root / SOURCE
    pin = json.loads((folder / 'UPSTREAM.json').read_text())
    if pin['repository'] != 'https://github.com/codemyriad/cassini-ux' or not re.fullmatch(r'[a-f0-9]{40}', pin['commit']):
        raise ValueError('Invalid immutable W0.4 pin')
    for path, expected in pin['sha256'].items():
        if hashlib.sha256((folder / path).read_bytes()).hexdigest() != expected:
            raise ValueError('W0.4 pin/hash mismatch: ' + path)
    shared = json.loads((root / STRINGS_PIN).read_text())
    if (shared.get('repository') != pin['repository'] or shared.get('commit') != pin['commit']
            or shared.get('path') != 'strings/strings.json'
            or shared.get('sha256') != pin['sha256']['strings/strings.json']
            or shared.get('vendored_path') != (SOURCE / 'strings/strings.json').as_posix()):
        raise ValueError('Global shared-string pin differs from the vendored catalog pin')
    catalog = json.loads((folder / 'strings/strings.json').read_text())
    selected = [entry for entry in catalog['entries'] if entry['id'].startswith(('states.badge.', 'states.phone.'))
                or entry['id'] == 'meeting.interruptedAt']
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


def render_lookup(root=ROOT):
    pin = json.loads((root / SOURCE / 'UPSTREAM.json').read_text())
    lines = [f'// Generated from cassini-ux {pin["commit"]}; do not edit.',
             'import Foundation', '', '/// Literal call sites keep Xcode extraction and the compiled catalog in agreement.',
             'enum StatusBadgeStrings {',
             '    static func template(_ id: String, bundle: Bundle, locale: Locale) -> String {',
             '        switch id {']
    for key in sorted(IDS):
        lines += [f'        case "{key}":',
                  f'            return String(localized: "{key}", table: "StatusBadge", bundle: bundle, locale: locale)']
    lines += ['        default:', r'            preconditionFailure("Unknown shared status badge key: \(id)")',
              '        }', '    }', '}', '']
    return '\n'.join(lines).encode()


def outputs(root=ROOT):
    # Validate every source and template before producing either generated output.
    catalog = render(root)
    return {OUTPUT: catalog, LOOKUP: render_lookup(root)}


def check(root=ROOT):
    for path, expected in outputs(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != expected:
            raise ValueError(f'Generated {path.name} drift; run scripts/generate-status-badge-strings.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        if args.check:
            check()
        else:
            for path, expected in outputs().items():
                (ROOT / path).write_bytes(expected)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
