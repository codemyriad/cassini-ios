#!/usr/bin/env python3
"""Regressions of check-embedded-minos.py over synthesized app bundles: no Xcode, no build."""
import importlib.util
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / 'check-embedded-minos.py'
spec = importlib.util.spec_from_file_location('check_embedded_minos', SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
WHISTLE = 'Frameworks/CassiniWhistleRuntime.framework'


def encoded(text):
    major, minor, patch = checker.version(text)
    return major << 16 | minor << 8 | patch


def macho(minimum=None, legacy=False):
    """A thin arm64 Mach-O whose only load commands are a UUID and, if given, its minimum OS."""
    commands = [struct.pack('<II16s', 0x1b, 24, b'\0' * 16)]
    if minimum and legacy:
        commands.append(struct.pack('<IIII', 0x25, 16, encoded(minimum), encoded('27.0')))
    elif minimum:
        commands.append(struct.pack('<IIIIII', 0x32, 24, 7, encoded(minimum), encoded('27.0'), 0))
    body = b''.join(commands)
    return struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, len(commands), len(body), 0, 0) + body


def fat(*slices):
    header = struct.pack('>II', 0xcafebabe, len(slices))
    offset, entries, payload = 8 + 20 * len(slices), b'', b''
    for thin in slices:
        entries += struct.pack('>iiIII', 0x0100000c, 0, offset + len(payload), len(thin), 0)
        payload += thin
    return header + entries + payload


class EmbeddedMinimumTests(unittest.TestCase):
    def app(self, root, files, target='18.0'):
        app = Path(root) / 'Cassini.app'
        defaults = {'Info.plist': plistlib.dumps({'MinimumOSVersion': target}), 'Cassini': macho(target),
                    WHISTLE + '/CassiniWhistleRuntime': macho(target),
                    WHISTLE + '/Info.plist': plistlib.dumps({'MinimumOSVersion': target})}
        for relative, content in {**defaults, **files}.items():
            if content is None:
                continue
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        return app

    def check(self, files, target='18.0'):
        with tempfile.TemporaryDirectory(prefix='cassini minos ') as root:
            return checker.check(self.app(root, files, target))

    def test_an_app_whose_binaries_are_at_or_below_its_target_passes(self):
        target, problems = self.check({
            'PlugIns/CassiniActivity.appex/CassiniActivity': macho('18.0'),
            'PlugIns/CassiniActivity.appex/Info.plist': plistlib.dumps({'MinimumOSVersion': '18.0'}),
            'PlugIns/CassiniTests.xctest/CassiniTests': fat(macho('17.0'), macho('18.0', legacy=True)),
            'Frameworks/Old.framework/Old': macho('15.1'),
            'Whistle/whistle.cact': b'\xcf\xfa' + b'\0' * 64,  # Not a Mach-O: too short a magic.
            'Assets.car': b'BOMStore', 'Empty': b''})
        self.assertEqual(target, (18, 0, 0))
        self.assertEqual(problems, [])

    def test_a_newer_binary_or_plist_anywhere_else_fails_and_is_named(self):
        cases = {'PlugIns/CassiniActivity.appex/CassiniActivity': macho('26.0'),
                 'Frameworks/New.framework/New': fat(macho('18.0'), macho('18.4')),
                 'Frameworks/New.framework/Info.plist': plistlib.dumps({'MinimumOSVersion': '26.0'}),
                 'Cassini': macho('18.0.1'),
                 'PlugIns/Legacy.appex/Legacy': macho('26.0', legacy=True)}
        for relative, content in cases.items():
            with self.subTest(relative=relative):
                _, problems = self.check({relative: content})
                self.assertEqual(len(problems), 1, problems)
                self.assertTrue(problems[0].startswith(relative + ': minimum iOS '), problems)
                self.assertIn("above the app's 18.0", problems[0])

    def test_whistle_has_no_exception(self):
        """The private Whistle runtime is linked for the app's own target (Whistle/pins.json); one linked for iOS 26
        or for its source archives' 27 fails like any other binary, executable and plist alike."""
        for minimum in ['26.0', '27.0']:
            with self.subTest(minimum=minimum):
                _, problems = self.check({WHISTLE + '/CassiniWhistleRuntime': macho(minimum),
                                          WHISTLE + '/Info.plist': plistlib.dumps({'MinimumOSVersion': minimum})})
                self.assertEqual(problems, [f"{WHISTLE}/CassiniWhistleRuntime: minimum iOS {minimum} is above the app's 18.0",
                                            f"{WHISTLE}/Info.plist: minimum iOS {minimum} is above the app's 18.0"])

    def test_a_mach_o_without_a_minimum_fails(self):
        _, problems = self.check({'Frameworks/Bare.framework/Bare': macho()})
        self.assertEqual(problems, ['Frameworks/Bare.framework/Bare: a Mach-O without a minimum OS'])

    def test_the_command_line_reports_and_exits(self):
        with tempfile.TemporaryDirectory(prefix='cassini minos ') as root:
            good = subprocess.run([sys.executable, '-I', str(SCRIPT), str(self.app(root + '/good', {}))],
                                  capture_output=True, text=True)
            bad = subprocess.run([sys.executable, '-I', str(SCRIPT),
                                  str(self.app(root + '/bad', {'Cassini': macho('26.0')}))],
                                 capture_output=True, text=True)
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertIn('every embedded binary needs iOS 18.0 or older', good.stdout)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("error: Cassini: minimum iOS 26.0 is above the app's 18.0", bad.stderr)


if __name__ == '__main__':
    unittest.main()
