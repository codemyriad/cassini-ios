#!/usr/bin/env python3
"""Compile the pinned shared Wave 6 iOS backup and voice strings into native localization assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
STRINGS_PIN = Path('contracts/wave5-strings/UPSTREAM.json')
SOURCE = Path('contracts/wave5-strings/strings.json')
OUTPUT = Path('Cassini/Resources/Strings/Wave6.xcstrings')
LOOKUP = Path('Cassini/Strings/Wave6Copy.swift')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
PROPERTIES = {
    'backup.phoneOnlyCard.close.a11y': 'backupPhoneOnlyCardCloseA11y',
    'backup.includeSavedVoices.title': 'backupIncludeSavedVoicesTitle',
    'backup.settings.heading': 'backupSettingsHeading',
    'backup.settings.learnMore': 'backupSettingsLearnMore',
    'backup.info.title': 'backupInfoTitle',
    'backup.info.what.body': 'backupInfoWhatBody',
    'backup.info.icloud.heading': 'backupInfoIcloudHeading',
    'backup.info.icloud.body': 'backupInfoIcloudBody',
    'backup.info.icloud.computerHeading': 'backupInfoIcloudComputerHeading',
    'backup.info.icloud.computerBody': 'backupInfoIcloudComputerBody',
    'backup.info.manualCopy.heading': 'backupInfoManualCopyHeading',
    'voices.setup.title': 'voicesSetupTitle',
    'voices.setup.body': 'voicesSetupBody',
    'voices.setup.privacy.phone': 'voicesSetupPrivacyPhone',
    'voices.setup.enable': 'voicesSetupEnable',
    'voices.enroll.addAction': 'voicesEnrollAddAction',
    'voices.enroll.title': 'voicesEnrollTitle',
    'voices.enroll.instructions': 'voicesEnrollInstructions',
    'voices.enroll.testPhraseLabel': 'voicesEnrollTestPhraseLabel',
    'voices.enroll.testPhrase': 'voicesEnrollTestPhrase',
    'voices.enroll.record': 'voicesEnrollRecord',
    'voices.enroll.recording': 'voicesEnrollRecording',
    'voices.enroll.tooShort': 'voicesEnrollTooShort',
    'voices.enroll.ready': 'voicesEnrollReady',
    'voices.enroll.save': 'voicesEnrollSave',
    'voices.enroll.fromTranscriptHint': 'voicesEnrollFromTranscriptHint',
    'common.notNow': 'commonNotNow',
    'common.cancel': 'commonCancel',
    'common.stop': 'commonStop',
    'settings.transfer.exportHint': 'settingsTransferExportHint',
    'savedVoices.privacy.phone': 'savedVoicesPrivacyPhone',
    'savedVoices.row.status.ready': 'savedVoicesRowStatusReady',
    'savedVoices.row.play': 'savedVoicesRowPlay',
    'savedVoices.row.stopSample': 'savedVoicesRowStopSample',
    'savedVoices.row.stale': 'savedVoicesRowStale',
    'savedVoices.row.rename': 'savedVoicesRowRename',
    'savedVoices.row.forget': 'savedVoicesRowForget',
    'savedVoices.row.sampleCount.one': 'savedVoicesRowSampleCountOne',
    'savedVoices.row.sampleCount.other': 'savedVoicesRowSampleCountOther',
}
IDS = set(PROPERTIES)


def outputs(root=ROOT):
    pin_path = root / STRINGS_PIN
    pin = json.loads(pin_path.read_text())
    if (pin.get('repository') != 'https://github.com/codemyriad/cassini-ux'
            or not re.fullmatch(r'[a-f0-9]{40}', pin.get('commit', ''))
            or pin.get('path') != 'strings/strings.json'
            or pin.get('vendored_path') != SOURCE.as_posix()):
        raise ValueError('Invalid immutable Wave 6 string pin')
    source = root / SOURCE
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != pin.get('sha256'):
        raise ValueError('Wave 6 string pin/hash mismatch')
    entries = json.loads(source.read_text())['entries']
    sample_count = next(entry for entry in entries if entry['id'] == 'savedVoices.row.sampleCount')
    for language in LANGUAGES:
        forms = sample_count['plural'] if language == 'en' else sample_count['l10n'][language]['plural']
        if forms.get('many', forms['other']) != forms['other']:
            raise ValueError('Distinct many form needs native CLDR routing')
    for form in ('one', 'other'):
        entries.append({
            'id': f'savedVoices.row.sampleCount.{form}', 'platforms': ['ios'],
            'en': sample_count['plural'][form],
            'l10n': {language: {'text': sample_count['l10n'][language]['plural'][form]}
                     for language in LANGUAGES if language != 'en'},
        })
    selected = [entry for entry in entries if entry['id'] in IDS]
    if len(selected) != len(IDS) or {entry['id'] for entry in selected} != IDS:
        raise ValueError('Missing or duplicate Wave 6 string IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        if 'ios' not in entry.get('platforms', []):
            raise ValueError(f'Entry is not declared for iOS: {entry["id"]}')
        locales = {}
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            placeholders = set(re.findall(r'\{\w+\}', value))
            if not isinstance(value, str) or not value.strip() or '%' in value:
                raise ValueError(f'Placeholder drift: {entry["id"]} {language}')
            if (placeholders != set(re.findall(r'\{\w+\}', entry['en']))
                    and not (entry['id'] == 'savedVoices.row.sampleCount.one' and placeholders <= {'{n}'})):
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
        '/// Shared Wave 6 iOS backup and saved-voice copy, resolved using the current app language.',
        'enum Wave6Copy {',
    ]
    for key, name in sorted(PROPERTIES.items()):
        lines += [
            f'    static var {name}: String {{',
            f'        String(localized: "{key}", table: "Wave6")',
            '    }',
        ]
    lines += [
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
            f'            return String(localized: "{key}", table: "Wave6", bundle: localized, locale: locale)',
        ]
    lines += [
        '        default:',
        r'            preconditionFailure("Unknown shared Wave 6 key: \(key)")',
        '        }',
        '    }',
        '}',
        '',
    ]
    return {OUTPUT: catalog, LOOKUP: '\n'.join(lines).encode()}


def check(root=ROOT):
    for path, expected in outputs(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != expected:
            raise ValueError(f'Generated {path.name} drift; run scripts/generate-wave6-strings.py')


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
