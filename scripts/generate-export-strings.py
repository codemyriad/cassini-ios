#!/usr/bin/env python3
"""Compile the pinned shared Phase 2 export strings into native localization assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
STRINGS_PIN = Path('contracts/shared-strings/UPSTREAM.json')
SOURCE = Path('Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges/strings/strings.json')
OUTPUT = Path('Cassini/Resources/Strings/ExportPhase2.xcstrings')
LOOKUP = Path('Cassini/Strings/ExportPhase2Copy.swift')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
PROPERTIES = {
    'export.heading': 'heading',
    'export.otherFormats': 'otherFormats',
    'export.cassiniFile.label': 'cassiniFile',
    'export.cassiniFile.description.short': 'cassiniDescription',
    'export.markdown.label': 'markdown',
    'export.markdown.description.short': 'markdownDescription',
    'export.plainText.label': 'plainText',
    'export.plainText.description.short': 'plainTextDescription',
    'export.subtitles.label': 'subtitles',
    'export.srt.description.short': 'srtDescription',
    'export.vtt.description.short': 'vttDescription',
    'export.typeWithSize': 'typeWithSize',
    'export.originalAudio.label': 'originalAudio',
    'export.originalAudio.description': 'originalDescription',
    'export.audioOnly.note': 'audioOnlyNote',
    'export.exportButton': 'exportButton',
    'export.formatGroup.a11y': 'formatGroup',
}
IDS = set(PROPERTIES)


def outputs(root=ROOT):
    pin_path = root / STRINGS_PIN
    pin = json.loads(pin_path.read_text())
    if (pin.get('repository') != 'https://github.com/codemyriad/cassini-ux'
            or not re.fullmatch(r'[a-f0-9]{40}', pin.get('commit', ''))
            or pin.get('path') != 'strings/strings.json'
            or pin.get('vendored_path') != SOURCE.as_posix()):
        raise ValueError('Invalid immutable Phase 2 export string pin')
    source = root / SOURCE
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != pin.get('sha256'):
        raise ValueError('Phase 2 export string pin/hash mismatch')
    selected = [entry for entry in json.loads(source.read_text())['entries'] if entry['id'] in IDS]
    if len(selected) != len(IDS) or {entry['id'] for entry in selected} != IDS:
        raise ValueError('Missing or duplicate Phase 2 export string IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        if 'ios' not in entry.get('platforms', []):
            raise ValueError(f'Entry is not declared for iOS: {entry["id"]}')
        locales = {}
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            placeholders = set(re.findall(r'\{\w+\}', value))
            expected_placeholders = {'{type}', '{size}'} if entry['id'] == 'export.typeWithSize' else set()
            if (not isinstance(value, str) or not value.strip()
                    or placeholders != expected_placeholders or '%' in value):
                raise ValueError(f'Placeholder drift: {entry["id"]} {language}')
            if translation.get('plural'):
                raise ValueError(f'Unexpected plural requirement: {entry["id"]} {language}')
            locales[language] = {'stringUnit': {'state': 'translated', 'value': value}}
        strings[entry['id']] = {
            'comment': f'Generated from cassini-ux {pin["commit"]}, {entry["id"]}.',
            'extractionState': 'manual',
            'localizations': locales,
        }
    catalog = (json.dumps({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'},
                          ensure_ascii=False, indent=2) + '\n').encode()
    lines = [
        f'// Generated from cassini-ux {pin["commit"]}; do not edit.',
        'import Foundation',
        'import CassiniNotebook',
        '',
        '/// Shared Phase 2 export copy, resolved using the current app language.',
        'enum ExportPhase2Copy {',
    ]
    for key, name in sorted(PROPERTIES.items()):
        lines += [
            f'    static var {name}: String {{',
            f'        String(localized: "{key}", table: "ExportPhase2")',
            '    }',
        ]
    lines += [
        '',
        '    static func typeWithSize(_ type: String, size: String) -> String {',
        '        typeWithSize.replacingOccurrences(of: "{type}", with: type).replacingOccurrences(of: "{size}", with: size)',
        '    }',
        '}',
        '',
    ]
    return {OUTPUT: catalog, LOOKUP: '\n'.join(lines).encode()}


def check(root=ROOT):
    for path, expected in outputs(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != expected:
            raise ValueError(f'Generated {path.name} drift; run scripts/generate-export-strings.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if generated outputs are out of date')
    args = parser.parse_args()
    if args.check:
        check()
        return
    for path, content in outputs().items():
        target = ROOT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


if __name__ == '__main__':
    main()
