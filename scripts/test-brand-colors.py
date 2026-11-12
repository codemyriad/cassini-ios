#!/usr/bin/env python3
"""Fast generator/pin/guard fault controls; no Swift compiler or simulator."""
import hashlib
import importlib.util
import sys
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

# Fault controls must not dirty the source checkout with interpreter caches.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("brand", ROOT / "scripts/generate-brand-colors.py")
brand = importlib.util.module_from_spec(spec)
spec.loader.exec_module(brand)


class BrandGenerationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for path in (brand.TOKEN, brand.PIN, brand.APPLICATION):
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
        original = brand.baseline
        self.baseline = patch.object(brand, "baseline", side_effect=lambda path, root: original(path, ROOT))
        self.baseline.start()
        self.addCleanup(self.baseline.stop)

    def test_committed_outputs_are_exact_generator_output(self):
        for path, generated in brand.render(self.root).items():
            self.assertEqual((ROOT / path).read_bytes(), generated, path)
        brand.check_literals(ROOT)

    def test_pin_hash_fault_is_rejected(self):
        pin = self.root / brand.PIN
        value = json.loads(pin.read_text()); value["sha256"] = "0" * 64
        pin.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "pin/hash mismatch"):
            brand.render(self.root)

    def test_wrong_source_or_non_commit_pin_is_rejected(self):
        pin = self.root / brand.PIN
        value = json.loads(pin.read_text()); value["repository"] = "https://example.com/other"
        pin.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "source"):
            brand.render(self.root)
        value["repository"] = "https://github.com/codemyriad/cassini-ux"; value["commit"] = "main"
        pin.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "pin/hash mismatch"):
            brand.render(self.root)

    def test_role_value_changes_generated_rgba_even_with_matching_pin(self):
        path = self.root / brand.TOKEN
        sheet = json.loads(path.read_text()); sheet["tokens"]["accent"]["dark"] = "#010203"
        raw = json.dumps(sheet).encode(); path.write_bytes(raw)
        pin = self.root / brand.PIN
        value = json.loads(pin.read_text()); value["sha256"] = hashlib.sha256(raw).hexdigest()
        pin.write_text(json.dumps(value))
        changed = brand.render(self.root)[brand.OUTPUT]
        self.assertIn(b"0x010203FF", changed)
        self.assertNotEqual((ROOT / brand.OUTPUT).read_bytes(), changed)

    def test_missing_or_invalid_role_is_rejected(self):
        for mutation in (lambda s: s["tokens"].pop("accent"),
                         lambda s: s["tokens"]["accent"].update(light="red")):
            with self.subTest(mutation=mutation):
                token = self.root / brand.TOKEN
                sheet = json.loads((ROOT / brand.TOKEN).read_text()); mutation(sheet)
                raw = json.dumps(sheet).encode(); token.write_bytes(raw)
                pin = json.loads((ROOT / brand.PIN).read_text()); pin["sha256"] = hashlib.sha256(raw).hexdigest()
                (self.root / brand.PIN).write_text(json.dumps(pin))
                with self.assertRaises(ValueError): brand.render(self.root)

    def test_generated_drift_is_rejected(self):
        for path, data in brand.render(self.root).items():
            target = self.root / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        brand.check_generated(self.root)
        generated = self.root / brand.OUTPUT
        generated.write_bytes(generated.read_bytes().replace(b"0x007999FF", b"0x000000FF"))
        with self.assertRaisesRegex(ValueError, "generated drift: CassiniShared/CassiniTokens.swift"):
            brand.check_generated(self.root)

    def test_application_cannot_silently_activate_preview_or_change_baseline(self):
        for application in ({"mode": "preview", "compatibility_baseline": brand.BASELINE},
                            {"mode": "plumbing", "compatibility_baseline": "main"}):
            (self.root / brand.APPLICATION).write_text(json.dumps(application))
            with self.assertRaisesRegex(ValueError, "mode/baseline"):
                brand.render(self.root)

    def test_compatibility_is_extracted_exactly_from_frozen_source(self):
        generated = brand.render(self.root)[brand.OUTPUT].decode()
        for path in brand.SOURCES[:2]:
            self.assertIn(brand.extension(brand.baseline(path, self.root).decode()), generated)
        self.assertIn(brand.baseline(brand.SOURCES[2], self.root).decode().removeprefix("import SwiftUI\n").strip(), generated)
        metadata = json.loads(brand.render(self.root)[brand.META])
        self.assertEqual(metadata["baseline_commit"], brand.BASELINE)
        for path, digest in metadata["sources"].items():
            self.assertEqual(digest, hashlib.sha256(brand.baseline(path, self.root)).hexdigest())

    def test_new_colour_asset_requires_generator_ownership(self):
        path = self.root / "Cassini/Resources/New.colorset/Contents.json"
        path.parent.mkdir(parents=True); path.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'colour asset outside generated outputs'):
            brand.check_literals(self.root)

    def test_guard_rejects_fixed_colours_in_new_files_without_allowlist(self):
        examples = ('Color(red: 1, green: 0, blue: 0)', 'Color(\nred: 1, green: 0, blue: 0)', '.foregroundStyle(.white)',
                    'UIColor.systemRed', '.tint(.systemBlue)', 'Color.blue', 'Color(.red)', '.strokeBorder(.gray)', '.fill(.purple)',
                    'Color.init(red: 1, green: 0, blue: 0)', 'let c: UIColor = .init(red: 1, green: 0, blue: 0)',
                    'UIColor.init(white: 1, alpha: 1)', 'let c: CGColor = .init(gray: 0, alpha: 1)',
                    'Color.init(hue: 0, saturation: 1, brightness: 1)', 'Color.init(.sRGB, red: 1, green: 0, blue: 0)',
                    'CIColor(red: 1, green: 0, blue: 0)', 'CIColor.init(red: 1, green: 0, blue: 0)',
                    'CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)', 'let c: CGColor = .init(srgbRed: 1, green: 0, blue: 0, alpha: 1)',
                    'UIColor.magenta', 'UIColor.darkGray', 'CIColor.cyan', '.tint(.systemGray2)',
                    '#colorLiteral(red: 1, green: 0, blue: 0, alpha: 1)', 'let rgb = 0xFFEEDD', 'let hex = "#abcdef"')
        target = self.root / 'Cassini/NewView.swift'; target.parent.mkdir()
        for example in examples:
            with self.subTest(example=example):
                target.write_text(example)
                with self.assertRaisesRegex(ValueError, 'NewView.swift:1'):
                    brand.check_literals(self.root)
        target.write_text('''
.foregroundStyle(Color.ink.opacity(0.5))
// white #FFFFFF example
let tint = SpeakerTint.blue
switch tint { case .blue, .green, .red, .gray, .magenta: break }
let component = DomainComponent.red
''')
        brand.check_literals(self.root)


if __name__ == "__main__":
    unittest.main()
