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

    def test_all_53_roles_and_decided_card_rest_are_generated(self):
        output = brand.render(self.root)[brand.OUTPUT].decode()
        sheet = json.loads((self.root / brand.TOKEN).read_text())
        self.assertEqual(len(sheet['tokens']), 53)
        for name in ('sidebar', 'sidebar-mac', 'field', 'field-line'):
            self.assertIn('case ' + brand.role_name(name) + ' = "' + name + '"', output)
        self.assertIn('static let cardRest = Color(light: rgba(0xFAFAFBFF)', output)
        self.assertIn('static let recordingButtonWash = CassiniTokens.color(.ink, forcedDark: true).opacity(0.1)', output)

    def test_derived_drift_and_provisional_marks_fail_closed(self):
        original = json.loads((ROOT / brand.TOKEN).read_text())
        def repin(sheet):
            raw = json.dumps(sheet).encode()
            (self.root / brand.TOKEN).write_bytes(raw)
            pin = json.loads((ROOT / brand.PIN).read_text()); pin['sha256'] = hashlib.sha256(raw).hexdigest()
            (self.root / brand.PIN).write_text(json.dumps(pin))
        import copy
        sheet = copy.deepcopy(original); sheet['derived']['card-rest']['light'] = '#010203'
        repin(sheet)
        self.assertIn(b'0x010203FF', brand.render(self.root)[brand.OUTPUT])
        for mutate in (lambda s: s['derived']['card-rest'].update(status='pending'),
                       lambda s: s['tokens']['field'].update(check=['L-42']),
                       lambda s: s['tokens']['field'].update(status='placeholder')):
            sheet = copy.deepcopy(original); mutate(sheet); repin(sheet)
            with self.assertRaises(ValueError): brand.render(self.root)

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
        generated.write_bytes(generated.read_bytes().replace(b"0x093351FF", b"0x000000FF"))
        with self.assertRaisesRegex(ValueError, "generated drift: CassiniShared/CassiniTokens.swift"):
            brand.check_generated(self.root)

    def test_application_cannot_silently_activate_preview_or_change_baseline(self):
        for application in ({"mode": "preview", "compatibility_baseline": brand.BASELINE},
                            {"mode": "plumbing", "compatibility_baseline": "main"}):
            (self.root / brand.APPLICATION).write_text(json.dumps(application))
            with self.assertRaisesRegex(ValueError, "mode/baseline"):
                brand.render(self.root)

    def test_compatibility_is_extracted_exactly_from_frozen_source(self):
        (self.root / brand.APPLICATION).write_text(json.dumps({"mode": "plumbing", "compatibility_baseline": brand.BASELINE}))
        generated = brand.render(self.root)[brand.OUTPUT].decode()
        for path in brand.SOURCES[:2]:
            self.assertIn(brand.extension(brand.baseline(path, self.root).decode()), generated)
        self.assertIn(brand.baseline(brand.SOURCES[2], self.root).decode().removeprefix("import SwiftUI\n").strip(), generated)
        metadata = json.loads(brand.render(self.root)[brand.META])
        self.assertEqual(metadata["baseline_commit"], brand.BASELINE)
        for path, digest in metadata["sources"].items():
            self.assertEqual(digest, hashlib.sha256(brand.baseline(path, self.root)).hexdigest())

    def test_preview_has_no_compatibility_or_baseline_dependency(self):
        (self.root / brand.APPLICATION).write_text('{"mode":"preview"}')
        with patch.object(brand, "baseline", side_effect=AssertionError("preview consulted legacy colours")):
            outputs = brand.render(self.root)
        self.assertNotIn(brand.META, outputs)
        text = outputs[brand.OUTPUT].decode()
        self.assertNotIn("compatibilityWhite", text)
        self.assertNotIn("Color.white", text)
        self.assertIn("static let recordingBackground = CassiniTokens.color(.ground, forcedDark: true)", text)
        self.assertIn("static let recordingSecondary = CassiniTokens.color(.ink2, forcedDark: true)", text)
        self.assertIn("static let speakerTints: [Color] = [speaker1, speaker2, speaker3, speaker4, speaker5, speaker6]", text)
        sheet = json.loads((self.root / brand.TOKEN).read_text())
        asset = json.loads(outputs[brand.ASSET])
        for color, mode in zip(asset["colors"], ("light", "dark")):
            parts = color["color"]["components"]
            rgb = "#" + "".join(parts[c].removeprefix("0x") for c in ("red", "green", "blue"))
            self.assertEqual(rgb, sheet["tokens"]["accent"][mode])

    def test_preview_refuses_lingering_compatibility_metadata(self):
        (self.root / brand.APPLICATION).write_text('{"mode":"preview"}')
        (self.root / brand.META).write_text('{}')
        with self.assertRaisesRegex(ValueError, "must not retain compatibility"):
            brand.check_generated(self.root)

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
                    'UIColor.magenta', 'UIColor.darkGray', 'UIColor.darkText', 'UIColor.lightText',
                    'CIColor.cyan', '.tint(.systemGray2)',
                    '.foregroundStyle(\n .red)', '.fill ( .blue )', 'UIColor . systemRed',
                    '.shadow(color: .purple, radius: 2)',
                    '.foregroundStyle(isSelected ? .red : .blue)',
                    '.background(active ? .green : .pink, in: Capsule())',
                    'with: .color(fresh ? .recordingAccent : .red)',
                    'text[range].foregroundColor = .red', 'let tint: Color = .red',
                    'let tints: [Color] = [.red, .blue]', '.listRowBackground(.red)',
                    '.activityBackgroundTint(.red)', '.keylineTint(.red)',
                    'Color(uiColor: .secondarySystemGroupedBackground)', 'Color(uiColor: .label)',
                    'Color(cgColor: existing)', 'Color(ciColor: existing)',
                    'UIColor(dynamicProvider: provider)', 'UIColor { traits in .red }',
                    'UIColor.init { traits in .green }', 'UIColor({ traits in .blue })',
                    'UIColor(_colorLiteralRed: 1, green: 0, blue: 0, alpha: 1)',
                    'CGColor(genericGrayGamma2_2Gray: 0.5, alpha: 1)',
                    *('Color(uiColor: .' + name + ')' for name in (
                        'systemMint', 'systemCyan', 'systemBackground', 'systemGroupedBackground', 'systemFill',
                        'secondarySystemFill', 'tertiarySystemGroupedBackground', 'quaternarySystemFill',
                        'quaternaryLabel', 'separator', 'opaqueSeparator', 'placeholderText', 'link')),
                    'let link = "https://example.test"; let tint = Color.red',
                    'let link = "cassini://example"; let tint: Color = .blue',
                    '#colorLiteral(red: 1, green: 0, blue: 0, alpha: 1)', 'let rgb = 0xFFEEDD', 'let hex = "#abcdef"')
        target = self.root / 'Cassini/NewView.swift'; target.parent.mkdir()
        for example in examples:
            with self.subTest(example=example):
                target.write_text(example)
                line = 2 if example == '.foregroundStyle(\n .red)' else 1
                with self.assertRaisesRegex(ValueError, f'NewView.swift:{line}'):
                    brand.check_literals(self.root)
        target.write_text('''
.foregroundStyle(Color.ink.opacity(0.5))
// white #FFFFFF example
let tint = SpeakerTint.blue
switch tint { case .blue, .green, .red, .gray, .magenta: break }
let component = DomainComponent.red
let named = SpeakerNaming.ui(value).label
let domainColor = palette[index].blue
let optionalLabel = optional?.label
let url = "https://example.test"
/* Color.red /* UIColor.systemFill */ Color.blue */
let action: OpenURLAction.Result = .systemAction
''')
        brand.check_literals(self.root)

    def test_comment_handling_preserves_swift_strings_and_literal_line_numbers(self):
        target = self.root / 'Cassini/NewView.swift'; target.parent.mkdir()
        for literal in ('"https://example.test"', '#"https://example.test"#',
                        '"""A quote " and https://example.test\ninside a multiline string"""',
                        '##"https://example.test/\\##"quoted"##'):
            with self.subTest(literal=literal):
                source = '/* Color.red\n /* nested Color.blue */\n*/\nlet url = ' + literal + '; let color: Color = .red'
                target.write_text(source)
                expected_line = source.count('\n') + 1
                with self.assertRaisesRegex(ValueError, f'NewView.swift:{expected_line}'):
                    brand.check_literals(self.root)

    def test_case_words_in_strings_and_where_conditions_cannot_hide_colours(self):
        target = self.root / 'Cassini/NewView.swift'; target.parent.mkdir()
        for example in ('let description = "case"; let tint = Color.red; let count: Int = 0',
                        'let description = #"case"#; let tint = UIColor.systemFill; let count: Int = 0',
                        'Text("case").foregroundStyle(.red); let count: Int = 0',
                        'let description = """case\ntext"""; let tint = Color.red; let count: Int = 0',
                        'switch mood { case .blue where tint == .red: break }',
                        'switch mood { case .blue: break }; let hex = "#FF0000"',
                        'enum State: String { case idle="idle"; static let tint=Color.red; static let n:Int=0 }',
                        'enum State: String {\ncase idle="idle"\nstatic let tint=Color.red; static let n:Int=0 }',
                        'enum State: String { case idle; static let tint=UIColor.systemMint; static let n:Int=0 }'):
            with self.subTest(example=example):
                target.write_text(example)
                with self.assertRaisesRegex(ValueError, f'NewView.swift:{example.count(chr(10)) + 1}'):
                    brand.check_literals(self.root)


if __name__ == "__main__":
    unittest.main()
