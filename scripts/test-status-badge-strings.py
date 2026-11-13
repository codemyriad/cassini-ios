#!/usr/bin/env python3
"""Offline catalog/pin/generated-table fault controls; no compiler or simulator."""
import importlib.util
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('badges', ROOT / 'scripts/generate-status-badge-strings.py')
generator = importlib.util.module_from_spec(spec); spec.loader.exec_module(generator)


class BadgeStringGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / generator.SOURCE, self.root / generator.SOURCE)
        target = self.root / generator.STRINGS_PIN
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / generator.STRINGS_PIN, target)

    def test_exact_output_has_all_six_locales_and_preserves_named_placeholders(self):
        expected = generator.render(self.root)
        self.assertEqual(expected, (ROOT / generator.OUTPUT).read_bytes())
        output = json.loads(expected)
        self.assertEqual(set(output['strings']), generator.IDS)
        for key, entry in output['strings'].items():
            self.assertEqual(set(entry['localizations']), set(generator.LANGUAGES))
            self.assertEqual(entry['extractionState'], 'manual')
        self.assertIn('{liveBadge}', output['strings']['states.badge.recording']['localizations']['en']['stringUnit']['value'])
        self.assertIn('{n}', output['strings']['states.badge.transcribing']['localizations']['fr']['stringUnit']['value'])
        self.assertIn('{position}', output['strings']['meeting.interruptedAt']['localizations']['it']['stringUnit']['value'])
        self.assertIn('{position}', output['strings']['states.phone.pausedAt']['localizations']['fr']['stringUnit']['value'])
        self.assertEqual(len(output['strings']), 17)

    def test_global_and_bundle_pins_cannot_diverge(self):
        path = self.root / generator.STRINGS_PIN
        pin = json.loads(path.read_text()); pin['commit'] = '0' * 40
        path.write_text(json.dumps(pin))
        with self.assertRaisesRegex(ValueError, 'Global shared-string pin'): generator.render(self.root)

    def test_generated_literal_calls_cover_every_key_and_both_outputs_reject_drift(self):
        import re
        generated = generator.render_lookup(self.root).decode()
        keys = re.findall(r'String\(localized: "([^"]+)", table: "StatusBadge"', generated)
        self.assertEqual(set(keys), generator.IDS)
        self.assertEqual(len(keys), len(generator.IDS))
        self.assertEqual(generated.encode(), (ROOT / generator.LOOKUP).read_bytes())
        for path, expected in generator.outputs(self.root).items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_bytes(expected)
        generator.check(self.root)
        for path, expected in generator.outputs(self.root).items():
            (self.root / path).write_bytes(expected + b' ')
            try:
                with self.assertRaisesRegex(ValueError, 'drift'): generator.check(self.root)
            finally: (self.root / path).write_bytes(expected)

    def test_pin_rejects_changed_catalog_or_related_vector(self):
        for path in ('strings/strings.json', 'vectors/states/states-vectors.json', 'vectors/library-vectors/expected/main.json'):
            file = self.root / generator.SOURCE / path
            original = file.read_bytes(); file.write_bytes(original + b' ')
            try:
                with self.assertRaisesRegex(ValueError, 'pin/hash mismatch'): generator.render(self.root)
            finally: file.write_bytes(original)

    def repin_catalog(self, mutate):
        folder = self.root / generator.SOURCE; path = folder / 'strings/strings.json'
        catalog = json.loads(path.read_text()); mutate(catalog)
        path.write_text(json.dumps(catalog))
        pin = json.loads((folder / 'UPSTREAM.json').read_text())
        pin['sha256']['strings/strings.json'] = hashlib.sha256(path.read_bytes()).hexdigest()
        (folder / 'UPSTREAM.json').write_text(json.dumps(pin))
        shared_path = self.root / generator.STRINGS_PIN
        shared = json.loads(shared_path.read_text())
        shared['sha256'] = pin['sha256']['strings/strings.json']
        shared_path.write_text(json.dumps(shared))

    def test_fresh_pin_cannot_silently_drop_placeholder(self):
        def mutate(catalog):
            item = next(e for e in catalog['entries'] if e['id'] == 'states.badge.recording')
            item['l10n']['fr']['text'] = 'Enregistrement'
        self.repin_catalog(mutate)
        with self.assertRaisesRegex(ValueError, 'Placeholder drift'): generator.render(self.root)

    def test_new_plural_requires_an_explicit_count_aware_api_change(self):
        def mutate(catalog):
            item = next(e for e in catalog['entries'] if e['id'] == 'states.badge.transcribing')
            item['l10n']['fr']['plural']['one'] = 'Une transcription'
        self.repin_catalog(mutate)
        with self.assertRaisesRegex(ValueError, 'plural needs runtime count'): generator.render(self.root)


if __name__ == '__main__': unittest.main()
