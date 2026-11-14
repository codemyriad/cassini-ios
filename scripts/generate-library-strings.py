#!/usr/bin/env python3
"""Compile the pinned shared Phase 1 library strings into native localization assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path('Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges')
OUTPUT = Path('Cassini/Resources/Strings/LibraryPhase1.xcstrings')
LOOKUP = Path('Cassini/Strings/LibraryPhase1Copy.swift')
STRINGS_PIN = Path('contracts/shared-strings/UPSTREAM.json')
LANGUAGES = ('en', 'it', 'fr', 'es', 'pt-BR', 'pt-PT')
PROPERTIES = {
    'phone.row.noSpeech': 'noSpeech',
    'phone.row.transcribed.a11y': 'transcribedAccessibilityLabel',
    'search.field.placeholder': 'searchPlaceholder',
    'search.field.a11y': 'searchAccessibilityLabel',
    'search.results.a11y': 'searchResultsAccessibilityLabel',
    'import.button.mobile': 'importAudio',
    'common.record': 'record',
    'common.close': 'close',
    'search.title': 'searchTitle',
}
PLURALS = {'phone.row.speakerCount', 'format.searchCount.places', 'format.searchCount.meetings'}
JOIN = 'format.searchCount.join'
IDS = set(PROPERTIES) | PLURALS | {JOIN}


def outputs(root=ROOT):
    folder = root / SOURCE
    pin = json.loads((folder / 'UPSTREAM.json').read_text())
    if pin['repository'] != 'https://github.com/codemyriad/cassini-ux' or not re.fullmatch(r'[a-f0-9]{40}', pin['commit']):
        raise ValueError('Invalid immutable library-string pin')
    source = folder / 'strings/strings.json'
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    shared = json.loads((root / STRINGS_PIN).read_text())
    if (digest != pin['sha256']['strings/strings.json']
            or shared.get('repository') != pin['repository']
            or shared.get('commit') != pin['commit']
            or shared.get('path') != 'strings/strings.json'
            or shared.get('sha256') != digest
            or shared.get('vendored_path') != (SOURCE / 'strings/strings.json').as_posix()):
        raise ValueError('Library-string pin/hash mismatch')
    selected = [entry for entry in json.loads(source.read_text())['entries'] if entry['id'] in IDS]
    if len(selected) != len(IDS) or {entry['id'] for entry in selected} != IDS:
        raise ValueError('Missing or duplicate Phase 1 library string IDs')
    strings = {}
    for entry in sorted(selected, key=lambda item: item['id']):
        locales = {}
        for language in LANGUAGES:
            translation = entry if language == 'en' else entry['l10n'][language]
            value = entry['en'] if language == 'en' else translation['text']
            placeholders = set(re.findall(r'\{\w+\}', value))
            expected = {'{n}'} if entry['id'] in PLURALS else ({'{places}', '{meetings}'} if entry['id'] == JOIN else set())
            if not isinstance(value, str) or not value.strip() or placeholders != expected or '%' in value:
                raise ValueError(f'Placeholder drift: {entry["id"]} {language}')
            forms = translation.get('plural', {})
            if entry['id'] in PLURALS:
                if not {'one', 'other'} <= set(forms) or not set(forms) <= {'one', 'many', 'other'}:
                    raise ValueError(f'Unexpected plural forms: {entry["id"]} {language}')
                variations = {}
                for category, form in sorted(forms.items()):
                    found = set(re.findall(r'\{\w+\}', form))
                    if not form.strip() or found not in ({'{n}'}, set()) or '%' in form:
                        raise ValueError(f'Plural placeholder drift: {entry["id"]} {language}/{category}')
                    if not found and (category != 'one' or not form.startswith('1 ')):
                        raise ValueError(f'Plural form loses its count: {entry["id"]} {language}/{category}')
                    variations[category] = {'stringUnit': {'state': 'translated', 'value': form.replace('{n}', '%lld')}}
                locales[language] = {'variations': {'plural': variations}}
            else:
                if forms:
                    raise ValueError(f'Unexpected plural requirement: {entry["id"]} {language}')
                locales[language] = {'stringUnit': {'state': 'translated', 'value': value}}
        strings[entry['id']] = {
            'comment': f'Generated from cassini-ux {pin["commit"]}, {entry["id"]}.',
            'extractionState': 'manual', 'localizations': locales,
        }
    catalog = (json.dumps({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'},
                          ensure_ascii=False, indent=2) + '\n').encode()
    lines = [f'// Generated from cassini-ux {pin["commit"]}; do not edit.', 'import Foundation', 'import CassiniNotebook', '',
             '/// Shared library copy, resolved using the current app language.', 'enum LibraryPhase1Copy {']
    for key, name in sorted(PROPERTIES.items()):
        lines += [f'    static var {name}: String {{',
                  f'        String(localized: "{key}", table: "LibraryPhase1")', '    }']
    lines += ['', '    static func speakerCount(_ count: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {',
              '        template("phone.row.speakerCount", count: count, language: language, bundle: bundle)', '    }', '',
              '    static func searchCount(results: Int, meetings: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {',
              '        template("format.searchCount.join", language: language, bundle: bundle)',
              '            .replacingOccurrences(of: "{places}", with: template("format.searchCount.places", count: results, language: language, bundle: bundle))',
              '            .replacingOccurrences(of: "{meetings}", with: template("format.searchCount.meetings", count: meetings, language: language, bundle: bundle))',
              '    }', '',
              '    static func template(_ key: String, count: Int = 0, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {',
              '        let locale = Locale(identifier: language)',
              '        let selected = Bundle.preferredLocalizations(from: bundle.localizations,',
              '            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"',
              '        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle',
              '        switch key {']
    by_id = {entry['id']: entry for entry in selected}
    for key in sorted(IDS):
        lines += [f'        case "{key}":']
        if key in PLURALS:
            default = by_id[key]['en'].replace('{n}', r'\(count)')
            lines += [f'            return String(localized: "{key}", defaultValue: "{default}", table: "LibraryPhase1", bundle: localized, locale: locale)']
        else:
            lines += [f'            return String(localized: "{key}", table: "LibraryPhase1", bundle: localized, locale: locale)']
    lines += ['        default:', r'            preconditionFailure("Unknown shared library key: \(key)")',
              '        }', '    }', '}', '']
    return {OUTPUT: catalog, LOOKUP: '\n'.join(lines).encode()}


def check(root=ROOT):
    for path, expected in outputs(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != expected:
            raise ValueError(f'Generated {path.name} drift; run scripts/generate-library-strings.py')


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
