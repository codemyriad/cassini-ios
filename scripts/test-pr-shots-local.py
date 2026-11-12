#!/usr/bin/env python3
"""Local render lifecycle/manifest regressions. Fake renderers, real git worktrees; no simulators."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent

def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result

manifest = module("manifest", "screenshot-manifest.py")
events = module("events", "test-events.py")
RENDER = '''#!/usr/bin/env python3
import json,os,sys,subprocess,signal
from pathlib import Path
out=Path(sys.argv[sys.argv.index('--output')+1]);out.mkdir(parents=True)
sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
assert (Path.cwd()/'CassiniUITests/ScreenshotTests.swift').read_text()=='// head capture'
logs=Path.cwd()/'DerivedData.noindex/screenshots';logs.mkdir(parents=True,exist_ok=True)
(logs/'fixture.log').write_text('renderer diagnostic')
if os.environ.get('WAIT_RENDER'):
 Path(os.environ['READY']).touch();signal.pause()
if sha==os.environ.get('FAIL_SHA'):sys.exit(7)
m=dict(source_sha=sha,xcode='fixture Xcode',image_version='fixture OS',devices=dict(prefix=os.environ['CASSINI_SIM_PREFIX']),quantize=os.environ['CASSINI_SHOTS_QUANTIZE'])
(out/'shots.json').write_text(json.dumps(m))
if os.environ.get('CHANGE_HEAD'):(Path.cwd()/'untracked-ui.swift').touch()
'''
CLEAN = '''#!/usr/bin/env python3
import os,sys
from pathlib import Path
assert sys.argv[1:]==['clean']
Path(os.environ['CLEAN_LOG']).write_text(os.environ['CASSINI_SIM_PREFIX'])
sys.exit(3 if os.environ.get('FAIL_CLEAN') else 0)
'''


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pr shots fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.repo = self.root / "repo"
        self.repo.mkdir(); self.git("init", "-q")
        self.git("config", "user.name", "Fixture"); self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / '.gitignore').write_text('DerivedData.noindex/\n')
        scripts = self.repo / "scripts"; scripts.mkdir()
        for name, source in (("screenshots.sh", "#!/bin/sh\nexit 99\n"), ("test.sh", CLEAN), ("screenshot-manifest.py", "# fixture\n")):
            file = scripts / name; file.write_text(source); file.chmod(0o755)
        captures = self.repo / 'CassiniUITests'; captures.mkdir()
        (captures / 'ScreenshotTests.swift').write_text('// base capture')
        self.git("add", "."); self.git("commit", "-qm", "base")
        (scripts / "screenshots.sh").write_text(RENDER)
        (captures / 'ScreenshotTests.swift').write_text('// head capture')
        self.git("commit", "-qam", "head")
        self.env = dict(os.environ, CLEAN_LOG=str(self.root / "clean"), READY=str(self.root / "ready"))
        self.env.pop("CASSINI_HEAVY_LOCK_HELD", None)
        self.command = [sys.executable, str(ROOT / "scripts/pr-shots-local.py"), "--head", str(self.repo),
                        "--base", "HEAD~1", "--out", str(self.root / "output")]

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def check_cleanup(self):
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertRegex((self.root / "clean").read_text(), r"^ts-prshots-[a-f0-9]{12}$")

    def run_tool(self):
        return subprocess.run(self.command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)

    def test_pair_uses_head_renderer_and_same_devices_with_accurate_shas(self):
        result = self.run_tool(); self.assertEqual(result.returncode, 0, result.stdout)
        out = self.root / "output"
        before = json.loads((out / "before/shots.json").read_text()); after = json.loads((out / "after/shots.json").read_text())
        self.assertEqual(before['source_sha'], self.git('rev-parse', 'HEAD~1'))
        self.assertEqual(after['source_sha'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(before['devices'], after['devices']); self.assertEqual(before['quantize'], '0')
        self.assertIn('pending canonical', json.loads((out / 'render.json').read_text())['diff'])
        self.check_cleanup()

    def test_base_failure_preserves_logs_but_not_a_complete_report(self):
        self.env['FAIL_SHA'] = self.git('rev-parse', 'HEAD~1')
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertTrue((self.root / 'output/before.log').exists())
        self.assertEqual((self.root / 'output/logs/before/fixture.log').read_text(), 'renderer diagnostic')
        self.assertFalse((self.root / 'output/render.json').exists()); self.check_cleanup()

    def test_canonical_hook_invokes_only_diff(self):
        tool = self.root / 'canonical.py'
        tool.write_text("import json,sys\nfrom pathlib import Path\nassert sys.argv[1]=='diff'\nout=Path(sys.argv[sys.argv.index('--out')+1]);out.mkdir()\n(out/'changes.json').write_text(json.dumps(sys.argv[1:]))\n")
        self.command += ['--diff-tool', str(tool), '--pr', '123']
        result = self.run_tool(); self.assertEqual(result.returncode, 0, result.stdout)
        args = json.loads((self.root / 'output/pr-shots/changes.json').read_text())
        self.assertEqual(args[args.index('--pr')+1], '123'); self.assertIn('--before-sha', args)
        self.assertIn('--before-dir', args); self.assertIn('--after-dir', args); self.assertNotIn('publish', args)
        self.check_cleanup()

    def test_bad_inputs_fail_before_rendering(self):
        self.command += ['--diff-tool', str(self.root / 'missing.py')]
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertFalse((self.root / 'output').exists())
        self.command = self.command[:-2]
        (self.repo / 'untracked-ui.swift').touch()
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertFalse((self.root / 'output').exists())
        (self.repo / 'untracked-ui.swift').unlink()
        self.command[-1] = str(self.repo / 'generated')
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertFalse((self.repo / 'generated').exists())
        self.assertEqual(self.git('worktree', 'list', '--porcelain').count('worktree '), 1)

    def test_cleanup_failure_or_source_change_cannot_publish_complete_report(self):
        for reason in ('FAIL_CLEAN', 'CHANGE_HEAD'):
            with self.subTest(reason=reason):
                self.env[reason] = '1'
                self.assertNotEqual(self.run_tool().returncode, 0)
                self.assertFalse((self.root / 'output/render.json').exists())
                self.check_cleanup()
                self.env.pop(reason)
                shutil.rmtree(self.root / 'output')

    def test_registered_worktree_is_removed_if_add_reports_failure(self):
        binary = self.root / 'bin'; binary.mkdir(); real = shutil.which('git')
        shim = binary / 'git'
        shim.write_text('#!/usr/bin/env python3\nimport subprocess,sys\nrc=subprocess.call([' + repr(real) + ']+sys.argv[1:])\n'
                        'if rc==0 and "worktree" in sys.argv and "add" in sys.argv:\n'
                        ' subprocess.run([' + repr(real) + ',"-C",sys.argv[2],"worktree","lock",sys.argv[-2]],check=True)\n'
                        ' sys.exit(7)\nsys.exit(rc)\n')
        shim.chmod(0o755)
        self.env['PATH'] = str(binary) + os.pathsep + os.environ['PATH']
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertFalse((self.root / 'output/render.json').exists())
        self.check_cleanup()

    def test_signal_ends_renderer_then_removes_private_worktree_and_clones(self):
        self.env['WAIT_RENDER'] = '1'
        with events.Events() as queue:
            queue.file(self.root)
            process = subprocess.Popen(self.command, env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                while not (self.root / 'ready').exists():
                    self.assertTrue(queue.until(time.monotonic() + 60), 'renderer readiness hang guard')
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=60), 143)
            finally:
                if process.poll() is None: process.kill(); process.wait()
        self.check_cleanup()


class ManifestTests(unittest.TestCase):
    def test_rows_are_explicit_and_duplicate_or_outside_paths_refuse(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp); file = out / 'ipad/dark/01-split-landscape.png'; file.parent.mkdir(parents=True)
            file.write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', 1200, 900))
            row, = manifest.inventory(out, [file], 'en', 'en_US')
            self.assertEqual((row['screen'], row['scheme'], row['device'], row['board']), ('split-landscape', 'dark', 'ipad', 'Meeting'))
            self.assertEqual((row['pixel_width'], row['pixel_height']), (1200, 900))
            with self.assertRaises(ValueError): manifest.inventory(out, [file, file], 'en', 'en_US')
            with self.assertRaises(ValueError): manifest.inventory(out / 'other', [file], 'en', 'en_US')
            file.write_bytes(b'not an image')
            with self.assertRaises(ValueError): manifest.inventory(out, [file], 'en', 'en_US')


if __name__ == '__main__':
    unittest.main()
