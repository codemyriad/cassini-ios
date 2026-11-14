#!/usr/bin/env python3
"""Compile the pinned shared Wave 5 first-run hero and privacy strings into native localization assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
STRINGS_PIN = Path('contracts/wave5-strings/UPSTREAM.json')
SOURCE = Path('contracts/wave5-strings/strings.json')
OUTPUT = Path('Cassini/Resources/Strings/LibraryWave5.xcstrings')
LOOKUP = Path('Cassini/Strings/LibraryWave5Copy.swift')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
PROPERTIES = {
    'firstRun.hero.title': 'heroTitle',
    'firstRun.hero.subtitle': 'heroSubtitle',
    'firstRun.hero.phoneBackupQualifier': 'heroPhoneBackupQualifier',
    'firstRun.hero.subtitlePhoneNote': 'heroSubtitlePhoneNote',
    'privacy.onDevice.iphone.withBackup': 'iphonePrivacyWithBackup',
    'privacy.onDevice.iphone.backupExcluded': 'iphonePrivacyBackupExcluded',
    'privacy.onDevice.ipad.withBackup': 'ipadPrivacyWithBackup',
    'privacy.onDevice.ipad.backupExcluded': 'ipadPrivacyBackupExcluded',
}
IDS = set(PROPERTIES)


def outputs(root=ROOT):
    pin_path = root / STRINGS_PIN
    pin = json.loads(pin_path.read_text())
    if (pin.get('repository') != 'https://github.com/codemyriad/cassini-ux'
            or not re.fullmatch(r'[a-f0-9]{40}', pin.get('commit', ''))
            or pin.get('path') != 'strings/strings.json'
            or pin.get('vendored_path') != SOURCE.as_posix()):
        raise ValueError('Invalid immutable Wave 5 string pin')
    source = root / SOURCE
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != pin.get('sha256'):
        raise ValueError('Wave 5 string pin/hash mismatch')
    selected = [entry for entry in json.loads(source.read_text())['entries'] if entry['id'] in IDS]
    if len(selected) != len(IDS) or {entry['id'] for entry in selected} != IDS:
        raise ValueError('Missing or duplicate Wave 5 library string IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        if 'ios' not in entry.get('platforms', []):
            raise ValueError(f'Entry is not declared for iOS: {entry["id"]}')
        locales = {}
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            placeholders = set(re.findall(r'\{\w+\}', value))
            if not isinstance(value, str) or not value.strip() or placeholders or '%' in value:
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
        '/// Shared Wave 5 first-run hero and backup-gated privacy copy, resolved using the current app language.',
        'enum LibraryWave5Copy {',
    ]
    for key, name in sorted(PROPERTIES.items()):
        lines += [
            f'    static var {name}: String {{',
            f'        String(localized: "{key}", table: "LibraryWave5")',
            '    }',
        ]
    lines += [
        '',
        '    static func privacyLine(_ privacy: FirstRunPrivacy, device: FirstRunDevice) -> String {',
        '        switch (device, privacy) {',
        '        case (.phone, .withBackup): iphonePrivacyWithBackup',
        '        case (.phone, .backupExcluded): iphonePrivacyBackupExcluded',
        '        case (.pad, .withBackup): ipadPrivacyWithBackup',
        '        case (.pad, .backupExcluded): ipadPrivacyBackupExcluded',
        '        }',
        '    }',
        '',
        '    static func template(_ key: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {',
        '        let locale = Locale(identifier: language)',
        '        let selected = Bundle.preferredLocalizations(from: bundle.localizations,',
        '            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"',
        '        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle',
        '        switch key {',
    ]
    for key in sorted(IDS):
        lines += [
            f'        case "{key}":',
            f'            return String(localized: "{key}", table: "LibraryWave5", bundle: localized, locale: locale)',
        ]
    lines += [
        '        default:',
        r'            preconditionFailure("Unknown shared Wave 5 library key: \(key)")',
        '        }',
        '    }',
        '}',
        '',
    ]
    return {OUTPUT: catalog, LOOKUP: '\n'.join(lines).encode()}


def check(root=ROOT):
    for path, expected in outputs(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != expected:
            raise ValueError(f'Generated {path.name} drift; run scripts/generate-wave5-strings.py')


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
