#!/usr/bin/env python3
"""Local render lifecycle/manifest regressions. Fake renderers, real git worktrees; no simulators."""
import importlib.util
import contextlib
import hashlib
import fnmatch
import json
import os
import re
from pathlib import Path
import signal
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent

def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result

manifest = module("manifest", "screenshot-manifest.py")
local = module("local", "pr-shots-local.py")
events = module("events", "test-events.py")
RENDER = '''#!/usr/bin/env python3
import json,os,sys,subprocess,signal,struct,zlib,re,importlib.util
from pathlib import Path
sys.dont_write_bytecode=True
out=Path(sys.argv[sys.argv.index('--output')+1]);out.mkdir(parents=True)
sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
capture=(Path.cwd()/'CassiniUITests/ScreenshotTests.swift').read_text()
assert (Path.cwd()/'navigation.txt').read_text() in capture
logs=Path.cwd()/'DerivedData.noindex/screenshots';logs.mkdir(parents=True,exist_ok=True)
(logs/'fixture.log').write_text('renderer diagnostic')
if os.environ.get('WAIT_RENDER'):
 Path(os.environ['READY']).write_text(str(os.getpid()));signal.pause()
if sha==os.environ.get('FAIL_SHA'):sys.exit(7)
m=dict(source_sha=sha,renderer_sha=os.environ['CASSINI_SHOTS_RENDERER_SHA'],capture=capture,lock=os.environ.get('CASSINI_HEAVY_LOCK') or str(Path.home()/'.cassini-heavy.lock'),xcode='fixture Xcode',image_version='fixture OS',devices=dict(prefix=os.environ['CASSINI_SIM_PREFIX']),quantize=os.environ['CASSINI_SHOTS_QUANTIZE'])
files=[]
for name in re.findall(r'// shot ([a-z0-9-]+)',capture):
 for scheme,level in [('light',255),('dark',0)]:
  def chunk(tag,data):return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data))
  file=out/scheme/(name+'.png');file.parent.mkdir(exist_ok=True);file.write_bytes(bytes.fromhex('89504e470d0a1a0a')+chunk(b'IHDR',struct.pack('>IIBBBBB',10,10,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\\x00'+bytes([level])*30)*10))+chunk(b'IEND',b''));files.append(file)
spec=importlib.util.spec_from_file_location('manifest',Path.cwd()/'scripts/screenshot-manifest.py');helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
m['shots']=helper.inventory(out,files,'en','en_US')
(out/'shots.json').write_text(json.dumps(m))
if os.environ.get('CHANGE_HEAD'):(Path.cwd()/'untracked-ui.swift').touch()
'''
CLEAN = '''#!/usr/bin/env python3
import os,sys
from pathlib import Path
assert sys.argv[1:]==['clean']
if os.environ.get('WAIT_CLEAN'):
 Path(os.environ['CLEAN_READY']).touch();assert sys.stdin.buffer.read(1)==b'x'
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
        for name, source in (("screenshots.sh", RENDER), ("test.sh", CLEAN), ("screenshot-manifest.py", (ROOT/'scripts/screenshot-manifest.py').read_text())):
            file = scripts / name; file.write_text(source); file.chmod(0o755)
        captures = self.repo / 'CassiniUITests'; captures.mkdir()
        (captures / 'ScreenshotTests.swift').write_text('// base capture old navigation\n// shot 01-library')
        (self.repo/'navigation.txt').write_text('old navigation')
        self.git("add", "."); self.git("commit", "-qm", "base")
        (scripts / "screenshots.sh").write_text(RENDER)
        (captures / 'ScreenshotTests.swift').write_text('// head capture new navigation\n// shot 01-library')
        (self.repo/'navigation.txt').write_text('new navigation')
        self.git("commit", "-qam", "head")
        self.env = dict(os.environ, CLEAN_LOG=str(self.root / "clean"), READY=str(self.root / "ready"), CLEAN_READY=str(self.root/'clean-ready'))
        self.env.pop("CASSINI_HEAVY_LOCK_HELD", None)
        self.env.pop('CASSINI_HEAVY_LOCK', None)
        self.command = [sys.executable, str(ROOT / "scripts/pr-shots-local.py"), "--head", str(self.repo),
                        "--base", "HEAD~1", "--out", str(self.root / "output")]

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def tearDown(self):
        self.remove_private_worktrees()

    def remove_private_worktrees(self):
        # Fault controls can kill the wrapper before it removes its private registration.
        for line in self.git('worktree','list','--porcelain').splitlines():
            if line.startswith('worktree ') and Path(line[9:]).resolve()!=self.repo.resolve():
                path=Path(line[9:]);self.assertTrue(path.parent.name.startswith('cassini-prshots-'))
                self.git('worktree','remove','--force','--force',str(path));shutil.rmtree(path.parent,ignore_errors=True)

    def check_cleanup(self):
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertRegex((self.root / "clean").read_text(), r"^ts-prshots-[a-f0-9]{12}$")

    def run_tool(self):
        return subprocess.run(self.command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)

    def test_pair_preserves_each_sources_capture_and_renderer_with_same_devices(self):
        result = self.run_tool(); self.assertEqual(result.returncode, 0, result.stdout)
        out = self.root / "output"
        before = json.loads((out / "before/shots.json").read_text()); after = json.loads((out / "after/shots.json").read_text())
        self.assertEqual(before['source_sha'], self.git('rev-parse', 'HEAD~1'))
        self.assertEqual(after['source_sha'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(before['devices'], after['devices']); self.assertEqual(before['quantize'], '0')
        self.assertIn('old navigation',before['capture']); self.assertIn('new navigation',after['capture'])
        self.assertEqual(before['renderer_sha'],before['source_sha']); self.assertEqual(after['renderer_sha'],after['source_sha'])
        self.assertIn('pending canonical', json.loads((out / 'render.json').read_text())['diff'])
        self.check_cleanup()

    def test_default_repo_lock_and_explicit_host_override(self):
        for override in (None, str(self.root/'host.lock')):
            if override: self.env['CASSINI_HEAVY_LOCK'] = override
            result=self.run_tool(); self.assertEqual(result.returncode,0,result.stdout)
            for side in ('before','after'):
                self.assertEqual(json.loads((self.root/'output'/side/'shots.json').read_text())['lock'],override or str(Path.home()/'.cassini-heavy.lock'))
            self.check_cleanup(); shutil.rmtree(self.root/'output')

    def test_legacy_base_gets_only_missing_tools(self):
        self.git('rm','scripts/screenshot-manifest.py'); self.git('commit','-qm','legacy base')
        shutil.copy2(ROOT/'scripts/screenshot-manifest.py',self.repo/'scripts/screenshot-manifest.py')
        self.git('add','.'); self.git('commit','-qm','add manifest tooling')
        result=self.run_tool(); self.assertEqual(result.returncode,0,result.stdout)
        before=json.loads((self.root/'output/before/shots.json').read_text())
        self.assertEqual(before['renderer_sha'],self.git('rev-parse','HEAD'))
        self.check_cleanup()

    def test_real_canonical_diff_preserves_old_navigation_and_reports_added_shots(self):
        shutil.copy2(ROOT/'scripts/pr-shots.py',self.repo/'scripts/pr-shots.py')
        file=self.repo/'CassiniUITests/ScreenshotTests.swift';file.write_text(file.read_text()+'\n// shot 10-first-run')
        self.git('add','.'); self.git('commit','-qm','new navigation and shot')
        self.command[self.command.index('--base')+1]='HEAD~2'
        self.command += ['--pr','125']
        result=self.run_tool(); self.assertEqual(result.returncode,0,result.stdout)
        out=self.root/'output'
        self.assertEqual({r['screen'] for r in json.loads((out/'before/shots.json').read_text())['shots']},{'library'})
        self.assertEqual({r['screen'] for r in json.loads((out/'after/shots.json').read_text())['shots']},{'library','first-run'})
        rows=json.loads((out/'pr-shots/changes.json').read_text())['rows'];self.assertEqual(len(rows),4)
        self.assertTrue(all(r['status']==('added' if r['screen']=='first-run' else 'unchanged') for r in rows))
        self.assertIn('First run',(out/'pr-shots/block.md').read_text());self.check_cleanup()

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
        self.assertEqual(args[args.index('--pr')+1], '123'); self.assertIn('--base-sha', args)
        self.assertIn('--head-sha', args); self.assertNotIn('--before-sha', args)
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
        self.env.update(WAIT_RENDER='1',WAIT_CLEAN='1')
        signals = (signal.SIGHUP, signal.SIGTERM, signal.SIGINT)
        for number in signals:
            with self.subTest(signal=number), events.Events() as queue:
                queue.file(self.root)
                process = subprocess.Popen(self.command, env=self.env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                queue.process(process.pid)
                try:
                    for marker in ('ready','clean-ready'):
                        while not (self.root/marker).exists():
                            self.assertIsNone(process.poll());self.assertTrue(queue.until(time.monotonic()+60),'readiness hang guard')
                        if marker=='ready': process.send_signal(number)
                    with self.assertRaises(ProcessLookupError):os.kill(int((self.root/'ready').read_text()),0)
                    for repeated in signals:process.send_signal(repeated)
                    process.stdin.write(b'x');process.stdin.flush()
                    self.assertEqual(process.wait(timeout=60),128+number)
                    self.check_cleanup()
                finally:
                    if process.poll() is None: process.kill(); process.wait()
                    process.stdin.close()
                    if (self.root/'ready').exists():
                        with contextlib.suppress(ProcessLookupError):os.killpg(int((self.root/'ready').read_text()),signal.SIGKILL)
                    self.remove_private_worktrees();shutil.rmtree(self.root/'output',ignore_errors=True)
                    for marker in ('ready','clean-ready'):(self.root/marker).unlink(missing_ok=True)


class ManifestTests(unittest.TestCase):
    def test_ci_paths_cover_all_screenshot_tools(self):
        workflow=(ROOT/'.github/workflows/ci.yml').read_text().split('  push:')[0]
        patterns=re.findall(r"^\s+- '([^']+)'",workflow,re.M)
        for file in ('pr-shots.sh','pr-shots-local.py','pr-shots.py','screenshot-manifest.py','screenshots.sh','test-pr-shots-local.py'):
            self.assertTrue(any(fnmatch.fnmatch('scripts/'+file,pattern) for pattern in patterns),file)

    def test_vendor_is_exact_pinned_shared_script_below_provenance_header(self):
        lines = (ROOT/'scripts/pr-shots.py').read_bytes().splitlines(keepends=True)
        self.assertIn(b'5ca44dee12614990c833cc6f49017dac7e184ae8', lines[1])
        self.assertEqual(hashlib.sha256(lines[0]+b''.join(lines[2:])).hexdigest(),
                         '769d2f2d872f9621c83858a633255093739b24e47c88f99c909de42108a27c42')

    def test_missing_pair_and_dark_image_mislabelled_light_refuse(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            rows = [dict(path=scheme+'.png', screen='library', lang='en', device='iphone', scheme=scheme)
                    for scheme in ('light', 'dark')]
            for row in rows:
                Image.new('RGB', (10, 10), 'white' if row['scheme']=='light' else 'black').save(out/row['path'])
            local.verify_schemes(out, rows)
            with self.assertRaisesRegex(ValueError, 'light/dark pair'): local.verify_schemes(out, rows[:1])
            Image.new('RGB', (10, 10), 'black').save(out/'light.png')
            with self.assertRaisesRegex(ValueError, 'disagrees'): local.verify_schemes(out, rows)

    def test_rows_are_explicit_and_duplicate_or_outside_paths_refuse(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp); file = out / 'ipad/dark/01-split-landscape.png'; file.parent.mkdir(parents=True)
            file.write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', 1200, 900))
            row, = manifest.inventory(out, [file], 'en', 'en_US')
            self.assertEqual((row['screen'], row['scheme'], row['device'], row['board']), ('split-landscape', 'dark', 'ipad', 'Meeting'))
            self.assertEqual((row['pixel_width'], row['pixel_height']), (1200, 900))
            legacy=file.with_name('10-old-board.png');legacy.write_bytes(file.read_bytes())
            old,=manifest.inventory(out,[legacy],'en','en_US')
            self.assertEqual(old['screen'],'old-board');self.assertIsNone(old['test'])
            with self.assertRaises(ValueError): manifest.inventory(out, [file, file], 'en', 'en_US')
            with self.assertRaises(ValueError): manifest.inventory(out / 'other', [file], 'en', 'en_US')
            file.write_bytes(b'not an image')
            with self.assertRaises(ValueError): manifest.inventory(out, [file], 'en', 'en_US')


if __name__ == '__main__':
    unittest.main()
