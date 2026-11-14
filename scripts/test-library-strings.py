#!/usr/bin/env python3
"""Offline pin, plural-preservation and generated-output fault controls."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('library_strings', ROOT / 'scripts/generate-library-strings.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class LibraryStringGenerationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        shutil.copytree(ROOT / generator.SOURCE, self.root / generator.SOURCE)
        shared = self.root / generator.STRINGS_PIN
        shared.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / generator.STRINGS_PIN, shared)

    def test_outputs_preserve_all_shared_plural_categories_in_six_locales(self):
        output = generator.outputs(self.root)
        source = json.loads((self.root / generator.SOURCE / 'strings/strings.json').read_text())
        entries = {entry['id']: entry for entry in source['entries']}
        catalog = json.loads(output[generator.OUTPUT])['strings']
        self.assertEqual(set(catalog), generator.IDS)
        for key, item in catalog.items():
            self.assertEqual(set(item['localizations']), set(generator.LANGUAGES))
            for language, localized in item['localizations'].items():
                entry = entries[key] if language == 'en' else entries[key]['l10n'][language]
                if key in generator.PLURALS:
                    self.assertEqual(set(localized['variations']['plural']), set(entry['plural']))
                    for category, form in entry['plural'].items():
                        self.assertEqual(localized['variations']['plural'][category]['stringUnit']['value'],
                                         form.replace('{n}', '%lld'))
                else:
                    self.assertEqual(localized['stringUnit']['value'], entry['en'] if language == 'en' else entry['text'])
        for path, content in output.items():
            self.assertEqual(content, (ROOT / path).read_bytes())

    def test_both_generated_files_reject_drift(self):
        for path, content in generator.outputs(self.root).items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        for path, content in generator.outputs(self.root).items():
            (self.root / path).write_bytes(content + b' ')
            with self.assertRaisesRegex(ValueError, 'drift'):
                generator.check(self.root)
            (self.root / path).write_bytes(content)

    def test_source_hash_and_global_commit_are_checked(self):
        source = self.root / generator.SOURCE / 'strings/strings.json'
        original = source.read_bytes()
        source.write_bytes(original + b' ')
        with self.assertRaisesRegex(ValueError, 'pin/hash mismatch'):
            generator.outputs(self.root)
        source.write_bytes(original)
        path = self.root / generator.STRINGS_PIN
        shared = json.loads(path.read_text())
        shared['commit'] = '0' * 40
        path.write_text(json.dumps(shared))
        with self.assertRaisesRegex(ValueError, 'pin/hash mismatch'):
            generator.outputs(self.root)

    def repin(self, mutate):
        source = self.root / generator.SOURCE / 'strings/strings.json'
        catalog = json.loads(source.read_text())
        mutate(catalog['entries'])
        source.write_text(json.dumps(catalog))
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        for path in (self.root / generator.SOURCE / 'UPSTREAM.json', self.root / generator.STRINGS_PIN):
            pin = json.loads(path.read_text())
            if isinstance(pin['sha256'], dict):
                pin['sha256']['strings/strings.json'] = digest
            else:
                pin['sha256'] = digest
            path.write_text(json.dumps(pin))

    def test_repin_cannot_silently_drop_count_or_add_unhandled_plural(self):
        def mutate(entries):
            item = next(e for e in entries if e['id'] == 'phone.row.speakerCount')
            item['l10n']['fr']['plural']['other'] = 'intervenants'
        self.repin(mutate)
        with self.assertRaisesRegex(ValueError, 'loses its count'):
            generator.outputs(self.root)

    def test_repin_cannot_duplicate_a_key(self):
        def mutate(entries):
            item = next(e for e in entries if e['id'] == 'search.field.placeholder')
            entries.append(item.copy())
        self.repin(mutate)
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            generator.outputs(self.root)

    def test_repin_cannot_drop_a_locale(self):
        def mutate(entries):
            item = next(e for e in entries if e['id'] == 'search.field.placeholder')
            del item['l10n']['pt-PT']
        self.repin(mutate)
        with self.assertRaises(KeyError):
            generator.outputs(self.root)

    def test_repin_cannot_add_an_unhandled_plural_category(self):
        def mutate(entries):
            item = next(e for e in entries if e['id'] == 'phone.row.speakerCount')
            item['l10n']['fr']['plural']['few'] = '{n} intervenants'
        self.repin(mutate)
        with self.assertRaisesRegex(ValueError, 'Unexpected plural forms'):
            generator.outputs(self.root)

    def test_literal_native_lookup_uses_count_interpolation_and_search_parts(self):
        lookup = generator.outputs(self.root)[generator.LOOKUP].decode()
        for key in generator.PLURALS:
            self.assertIn(f'String(localized: "{key}", defaultValue: "\\(count)', lookup)
        self.assertIn('template("format.searchCount.places", count: results', lookup)
        self.assertIn('template("format.searchCount.meetings", count: meetings', lookup)
        self.assertNotIn('"format.searchCount",', lookup)


if __name__ == '__main__':
    unittest.main()
