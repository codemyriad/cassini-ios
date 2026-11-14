#!/usr/bin/env python3
"""Compile the pinned shared Phase 1 meeting and speaker strings into native localization assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path('Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges')
OUTPUT = Path('Cassini/Resources/Strings/MeetingPhase1.xcstrings')
LOOKUP = Path('Cassini/Strings/MeetingPhase1Copy.swift')
STRINGS_PIN = Path('contracts/shared-strings/UPSTREAM.json')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
ENTRIES = {
    'common.cancel': ('cancel', None),
    'common.quote': ('quote', 'quote'),
    'common.savedVoices': ('savedVoices', None),
    'common.stop': ('stop', None),
    'library.allMeetings': ('allMeetings', None),
    'library.backToAllMeetings': ('backToAllMeetings', None),
    'meeting.find.placeholder': ('findPlaceholder', None),
    'phone.row.resume': ('resume', None),
    'player.pause': ('pause', None),
    'speakers.dialog.a11y': ('speakerDialogLabel', None),
    'speakers.duplicate.notice': ('speakerDuplicateNotice', 'name'),
    'speakers.duplicate.samePerson': ('speakerSamePerson', None),
    'speakers.duplicate.someoneElse': ('speakerSomeoneElse', None),
    'speakers.mergeInto': ('speakerMergeInto', None),
    'speakers.nameLabel': ('speakerNameLabel', None),
    'speakers.playSample': ('speakerPlaySample', None),
    'speakers.rememberVoice.cardBody.iphone': ('speakerRememberBody', 'name'),
    'speakers.rememberVoice.cardBody.iphone.unnamed': ('speakerRememberUnnamed', None),
    'speakers.rememberVoice.modelsNeeded': ('speakerRememberModelsNeeded', None),
    'speakers.rememberVoice.title': ('speakerRememberTitle', None),
    'speakers.rememberVoice.tooShort': ('speakerRememberTooShort', None),
    'speakers.saveName': ('speakerSaveName', None),
    'speakers.savedVoices.heading': ('speakerVoicesRanked', None),
    'speakers.savedVoices.likely': ('speakerLikely', None),
    'speakers.talkTime': ('speakerTalkTime', 'talkTime'),
}


def outputs(root=ROOT):
    folder = root / SOURCE
    pin = json.loads((folder / 'UPSTREAM.json').read_text())
    if pin['repository'] != 'https://github.com/codemyriad/cassini-ux' or not re.fullmatch(r'[a-f0-9]{40}', pin['commit']):
        raise ValueError('Invalid immutable meeting-string pin')
    source = folder / 'strings/strings.json'
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    shared = json.loads((root / STRINGS_PIN).read_text())
    if (digest != pin['sha256']['strings/strings.json']
            or shared.get('repository') != pin['repository']
            or shared.get('commit') != pin['commit']
            or shared.get('path') != 'strings/strings.json'
            or shared.get('sha256') != digest
            or shared.get('vendored_path') != (SOURCE / 'strings/strings.json').as_posix()):
        raise ValueError('Meeting-string pin/hash mismatch')
    selected = [entry for entry in json.loads(source.read_text())['entries'] if entry['id'] in ENTRIES]
    if len(selected) != len(ENTRIES) or {entry['id'] for entry in selected} != set(ENTRIES):
        raise ValueError('Missing or duplicate Phase 1 string IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        _, argument = ENTRIES[entry['id']]
        expected_placeholders = {f'{{{argument}}}'} if argument else set()
        locales = {}
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            found_placeholders = set(re.findall(r'\{\w+\}', value)) if isinstance(value, str) else None
            if (not isinstance(value, str) or not value.strip()
                    or found_placeholders != expected_placeholders
                    or translation.get('plural')):
                raise ValueError(f'Phase 1 string invalid or placeholder drift: {entry["id"]} {language}')
            locales[language] = {'stringUnit': {'state': 'translated', 'value': value}}
        comment_tail = '; named placeholders stay verbatim.' if argument else '.'
        strings[entry['id']] = {
            'comment': f'Generated from cassini-ux {pin["commit"]}, {entry["id"]}{comment_tail}',
            'extractionState': 'manual', 'localizations': locales,
        }
    catalog = (json.dumps({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'},
                          ensure_ascii=False, indent=2) + '\n').encode()
    lines = [f'// Generated from cassini-ux {pin["commit"]}; do not edit.', 'import Foundation', '',
             '/// Shared Phase 1 meeting and speaker copy, resolved using the current app language.',
             'enum MeetingPhase1Copy {']
    for key, (name, argument) in sorted(ENTRIES.items()):
        if argument is None:
            lines += [f'    static var {name}: String {{',
                      f'        String(localized: "{key}", table: "MeetingPhase1")', '    }']
        else:
            lines += [f'    static var {name}Template: String {{',
                      f'        String(localized: "{key}", table: "MeetingPhase1")', '    }',
                      f'    static func {name}(_ {argument}: String) -> String {{',
                      f'        {name}Template.replacingOccurrences(of: "{{{argument}}}", with: {argument})',
                      '    }']
    lines += ['', '    static func template(_ key: String, language: String, bundle: Bundle = .main) -> String {',
              '        let locale = Locale(identifier: language)',
              '        let selected = Bundle.preferredLocalizations(from: bundle.localizations,',
              '            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"',
              '        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle',
              '        switch key {']
    for key in sorted(ENTRIES):
        lines += [f'        case "{key}":',
                  f'            return String(localized: "{key}", table: "MeetingPhase1", bundle: localized, locale: locale)']
    lines += ['        default:', r'            preconditionFailure("Unknown shared meeting key: \(key)")',
              '        }', '    }', '}', '']
    return {OUTPUT: catalog, LOOKUP: '\n'.join(lines).encode()}


def check(root=ROOT):
    for path, expected in outputs(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != expected:
            raise ValueError(f'Generated {path.name} drift; run scripts/generate-meeting-strings.py')


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
