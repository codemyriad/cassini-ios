#!/usr/bin/env python3
"""Compile the pinned shared Wave 5 / Phase 2 strings into native localization assets."""
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
SAVED_VOICES_OUTPUT = Path('Cassini/Resources/Strings/SavedVoicesPhase2.xcstrings')
SAVED_VOICES_LOOKUP = Path('Cassini/Strings/SavedVoicesPhase2Copy.swift')
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
SAVED_VOICES_PROPERTIES = {
    'savedVoices.howToAdd': 'howToAdd',
    'savedVoices.row.stale': 'stale',
}
SAVED_VOICES_PLURALS = {'savedVoices.row.meetingCount'}
SAVED_VOICES_META = 'savedVoices.row.meta'
SAVED_VOICES_IDS = set(SAVED_VOICES_PROPERTIES) | SAVED_VOICES_PLURALS | {SAVED_VOICES_META}


# Keep existing native lookup keys stable while deriving all Phase 2 values from the shared catalog.
PHASE2_TABLES = {
    'Speakers': {
        'Cassini stops recognising this voice. Names already in your meetings stay.': 'android.savedVoices.forget.body',
        'Cassini stops recognising all %lld saved voices and deletes the voiceprints from every meeting. Names already in your meetings stay.': 'android.savedVoices.forgetEveryone.body',
        'Deletes the voiceprints of every meeting. Names already in your meetings stay.': 'ios.savedVoices.forgetAllData.body',
        # D98 backup-aware Remember copy is maintained in Speakers.xcstrings directly until cassini-ux updates
        # ios.speakers.{remember,suggest}Voice.description*.
        'People in this meeting': 'ios.speakers.peopleInMeeting',
        'The meeting could not be saved. Nothing was changed.': 'ios.speakers.meetingSaveFailed',
    },
    'Trash': {
        '%lld meetings could not be deleted. They stay in Recently Deleted.': 'ios.trash.deleteManyFailed',
        'Delete %lld meetings for good?': 'android.trash.deleteAll.title',
        'Its audio, transcripts and voiceprints from this meeting are deleted. This can’t be undone.': 'android.trash.delete.body',
        'Meetings here are deleted for good after 30 days, with their audio, transcripts and voiceprints from those meetings.': 'android.trash.retentionNote',
        'Meetings you delete stay here for 30 days.': 'android.trash.empty.body',
        '“%@” could not be deleted. It stays in Recently Deleted.': 'ios.trash.deleteFailed',
    },
    'Failures': {
        'This meeting’s details are not supported or are damaged. Its files have been kept.': 'ios.failure.meetingDetails',
    },
}


def _load_verified_entries(root):
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
    return pin, json.loads(source.read_text())['entries']


def _library_outputs(pin, all_entries):
    selected = [entry for entry in all_entries if entry['id'] in IDS]
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


def _saved_voices_outputs(pin, all_entries):
    selected = [entry for entry in all_entries if entry['id'] in SAVED_VOICES_IDS]
    if len(selected) != len(SAVED_VOICES_IDS) or {entry['id'] for entry in selected} != SAVED_VOICES_IDS:
        raise ValueError('Missing or duplicate Phase 2 saved voices string IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        if 'ios' not in entry.get('platforms', []):
            raise ValueError(f'Entry is not declared for iOS: {entry["id"]}')
        locales = {}
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            placeholders = set(re.findall(r'\{\w+\}', value)) if isinstance(value, str) else None
            expected = (
                {'{n}'} if entry['id'] in SAVED_VOICES_PLURALS
                else ({'{meetingCount}', '{confirmedSpeech}'} if entry['id'] == SAVED_VOICES_META else set())
            )
            if not isinstance(value, str) or not value.strip() or placeholders != expected or '%' in value:
                raise ValueError(f'Placeholder drift: {entry["id"]} {language}')
            forms = entry.get('plural', {}) if language == 'en' else translation.get('plural', {})
            if entry['id'] in SAVED_VOICES_PLURALS:
                if not {'one', 'other'} <= set(forms) or not set(forms) <= {'one', 'many', 'other'}:
                    raise ValueError(f'Unexpected plural forms: {entry["id"]} {language}')
                variations = {}
                for category, form in sorted(forms.items()):
                    found = set(re.findall(r'\{\w+\}', form))
                    if not form.strip() or found not in ({'{n}'}, set()) or '%' in form:
                        raise ValueError(f'Plural placeholder drift: {entry["id"]} {language}/{category}')
                    if not found and (category != 'one' or not form.startswith('1 ') or language in ('fr', 'pt-BR')):
                        raise ValueError(f'Plural form loses its count: {entry["id"]} {language}/{category}')
                    variations[category] = {'stringUnit': {'state': 'translated', 'value': form.replace('{n}', '%lld')}}
                locales[language] = {'variations': {'plural': variations}}
            else:
                if forms:
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
        '/// Shared Phase 2 Saved voices copy (`L-67`), resolved using the current app language.',
        'enum SavedVoicesPhase2Copy {',
    ]
    for key, name in sorted(SAVED_VOICES_PROPERTIES.items()):
        lines += [
            f'    static var {name}: String {{',
            f'        String(localized: "{key}", table: "SavedVoicesPhase2")',
            '    }',
        ]
    lines += [
        '',
        '    static func meetingCount(_ count: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {',
        '        template("savedVoices.row.meetingCount", count: count, language: language, bundle: bundle)',
        '    }',
        '',
        '    static func meta(meetings: Int, confirmedSpeech: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {',
        '        template("savedVoices.row.meta", language: language, bundle: bundle)',
        '            .replacingOccurrences(of: "{meetingCount}", with: meetingCount(meetings, language: language, bundle: bundle))',
        '            .replacingOccurrences(of: "{confirmedSpeech}", with: confirmedSpeech)',
        '    }',
        '',
        '    static func template(_ key: String, count: Int = 0, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {',
        '        let locale = Locale(identifier: language)',
        '        let selected = Bundle.preferredLocalizations(from: bundle.localizations,',
        '            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"',
        '        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle',
        '        switch key {',
    ]
    by_id = {entry['id']: entry for entry in selected}
    for key in sorted(SAVED_VOICES_IDS):
        lines += [f'        case "{key}":']
        if key in SAVED_VOICES_PLURALS:
            default = by_id[key]['en'].replace('{n}', r'\(count)')
            lines += [
                f'            return String(localized: "{key}", defaultValue: "{default}", table: "SavedVoicesPhase2", bundle: localized, locale: locale)',
            ]
        else:
            lines += [
                f'            return String(localized: "{key}", table: "SavedVoicesPhase2", bundle: localized, locale: locale)',
            ]
    lines += [
        '        default:',
        r'            preconditionFailure("Unknown shared Phase 2 saved voices key: \(key)")',
        '        }',
        '    }',
        '}',
        '',
    ]
    return {SAVED_VOICES_OUTPUT: catalog, SAVED_VOICES_LOOKUP: '\n'.join(lines).encode()}


def _phase2_outputs(root, pin, all_entries):
    ids = {shared_id for keys in PHASE2_TABLES.values() for shared_id in keys.values()}
    selected = [entry for entry in all_entries if entry['id'] in ids]
    if len(selected) != len(ids) or {entry['id'] for entry in selected} != ids:
        raise ValueError('Missing or duplicate Phase 2 string IDs')
    by_id = {entry['id']: entry for entry in selected}
    result = {}
    for table, keys in PHASE2_TABLES.items():
        path = Path(f'Cassini/Resources/Strings/{table}.xcstrings')
        catalog = json.loads((root / path).read_text())
        for key, shared_id in keys.items():
            entry = by_id[shared_id]
            if 'ios' not in entry.get('platforms', []):
                raise ValueError(f'Entry is not declared for iOS: {shared_id}')
            placeholders = set(entry.get('placeholders', {}))
            def compile_value(value):
                if set(re.findall(r'\{(\w+)\}', value)) != placeholders or '%' in value:
                    raise ValueError(f'Placeholder drift: {shared_id}')
                for name in placeholders:
                    value = value.replace('{' + name + '}', '%lld' if name == 'n' else '%@')
                return value
            if compile_value(entry['en']) != key:
                raise ValueError(f'Native lookup key drift: {shared_id}')
            locales = {}
            for language in LANGUAGES:
                translation = entry if language == 'en' else entry['l10n'][language]
                forms = translation.get('plural', {})
                if bool(forms) != bool(entry.get('plural')):
                    raise ValueError(f'Plural drift: {shared_id} {language}')
                if forms:
                    expected = {'one', 'other'} if language == 'en' else {'one', 'many', 'other'}
                    if set(forms) != expected:
                        raise ValueError(f'Plural category drift: {shared_id} {language}')
                    locales[language] = {'variations': {'plural': {
                        category: {'stringUnit': {'state': 'translated', 'value': compile_value(value)}}
                        for category, value in sorted(forms.items())
                    }}}
                else:
                    value = entry['en'] if language == 'en' else translation['text']
                    locales[language] = {'stringUnit': {'state': 'translated', 'value': compile_value(value)}}
            catalog['strings'][key] = {
                'comment': f'Generated from cassini-ux {pin["commit"]}, {shared_id}.',
                'extractionState': 'manual',
                'localizations': locales,
            }
        result[path] = (json.dumps(catalog, ensure_ascii=False, indent=2) + '\n').encode()
    return result


def outputs(root=ROOT):
    pin, entries = _load_verified_entries(root)
    result = _library_outputs(pin, entries)
    result.update(_saved_voices_outputs(pin, entries))
    result.update(_phase2_outputs(root, pin, entries))
    return result


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
