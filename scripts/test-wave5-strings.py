#!/usr/bin/env python3
"""Offline pin, locale-preservation and generated-output fault controls for Wave 5 strings."""
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
spec = importlib.util.spec_from_file_location('wave5_strings', ROOT / 'scripts/generate-wave5-strings.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class Wave5StringGenerationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for rel in (generator.STRINGS_PIN, generator.SOURCE):
            target = self.root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, target)

    def test_outputs_preserve_every_wave5_key_in_six_locales(self):
        output = generator.outputs(self.root)
        source = json.loads((self.root / generator.SOURCE).read_text())
        entries = {entry['id']: entry for entry in source['entries']}
        catalog = json.loads(output[generator.OUTPUT])['strings']
        self.assertEqual(set(catalog), generator.IDS)
        for key, item in catalog.items():
            self.assertEqual(set(item['localizations']), set(generator.LANGUAGES))
            for language, localized in item['localizations'].items():
                expected = entries[key]['en'] if language == 'en' else entries[key]['l10n'][language]['text']
                self.assertEqual(localized['stringUnit']['value'], expected)
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

    def test_source_hash_and_commit_pin_are_checked(self):
        source = self.root / generator.SOURCE
        original = source.read_bytes()
        source.write_bytes(original + b' ')
        with self.assertRaisesRegex(ValueError, 'pin/hash mismatch'):
            generator.outputs(self.root)
        source.write_bytes(original)
        pin_path = self.root / generator.STRINGS_PIN
        pin = json.loads(pin_path.read_text())
        pin['commit'] = 'z' * 40
        pin_path.write_text(json.dumps(pin))
        with self.assertRaisesRegex(ValueError, 'Invalid immutable Wave 5 string pin'):
            generator.outputs(self.root)

    def repin(self, mutate):
        source = self.root / generator.SOURCE
        catalog = json.loads(source.read_text())
        mutate(catalog['entries'])
        source.write_text(json.dumps(catalog))
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        pin_path = self.root / generator.STRINGS_PIN
        pin = json.loads(pin_path.read_text())
        pin['sha256'] = digest
        pin_path.write_text(json.dumps(pin))

    def test_repin_cannot_duplicate_or_drop_key_or_locale(self):
        def duplicate(entries):
            item = next(e for e in entries if e['id'] == 'firstRun.hero.title')
            entries.append(item.copy())
        self.repin(duplicate)
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            generator.outputs(self.root)

    def test_repin_rejects_placeholder_or_non_ios_entry(self):
        def add_placeholder(entries):
            item = next(e for e in entries if e['id'] == 'firstRun.hero.subtitle')
            item['l10n']['fr']['text'] = 'Rien {extra}'
        self.repin(add_placeholder)
        with self.assertRaisesRegex(ValueError, 'Placeholder drift'):
            generator.outputs(self.root)


if __name__ == '__main__':
    unittest.main()
