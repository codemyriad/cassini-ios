#!/usr/bin/env python3
"""Real temporary Git worktrees, without archives, network, signing or simulators."""
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location('archive_worker', SCRIPTS / 'testflight-archive.py')
archive_worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive_worker)


class FrozenSourceTests(unittest.TestCase):
    def git(self, *arguments, source=None):
        return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null',
            '-c', 'commit.gpgsign=false', *arguments], cwd=source or self.control,
            text=True, stderr=subprocess.PIPE).strip()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cassini-testflight-git-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.control = self.root / 'control'
        self.control.mkdir()
        self.git('init', '--quiet', '-b', 'main')
        self.git('config', 'user.name', 'English Tester')
        self.git('config', 'user.email', 'tester@example.invalid')
        (self.control / 'meeting.txt').write_text('An English recording\n')
        self.git('add', 'meeting.txt')
        self.git('commit', '--quiet', '-m', 'Initial synthetic source')
        self.head = self.git('rev-parse', 'HEAD')
        self.git('update-ref', 'refs/remotes/origin/main', self.head)
        self.checkout = self.root / 'frozen'
        self.git('worktree', 'add', '--quiet', '--detach', str(self.checkout), self.head)

    def advance_main(self):
        (self.control / 'meeting.txt').write_text('A later English recording\n')
        self.git('commit', '--quiet', '-am', 'Advance the control source')
        latest = self.git('rev-parse', 'HEAD')
        self.git('update-ref', 'refs/remotes/origin/main', latest)
        return latest

    def test_clean_frozen_head_is_accepted(self):
        archive_worker.frozen_source(self.checkout, self.head)

    def test_shared_origin_main_can_advance_without_invalidating_the_frozen_checkout(self):
        latest = self.advance_main()
        self.assertNotEqual(latest, self.head)
        self.assertEqual(self.git('rev-parse', 'origin/main', source=self.checkout), latest)
        self.assertEqual(self.git('rev-parse', 'HEAD', source=self.checkout), self.head)
        archive_worker.frozen_source(self.checkout, self.head)

    def test_changing_the_release_checkout_head_is_rejected(self):
        latest = self.advance_main()
        self.git('checkout', '--quiet', '--detach', latest, source=self.checkout)
        with self.assertRaisesRegex(RuntimeError, 'frozen main head'):
            archive_worker.frozen_source(self.checkout, self.head)

    def test_tracked_or_untracked_changes_are_rejected(self):
        for tracked in (True, False):
            with self.subTest(tracked=tracked):
                file = self.checkout / ('meeting.txt' if tracked else 'unexpected.txt')
                file.write_text('A local change must not be released\n')
                with self.assertRaisesRegex(RuntimeError, 'dirty'):
                    archive_worker.frozen_source(self.checkout, self.head)
                if tracked:
                    self.git('restore', 'meeting.txt', source=self.checkout)
                else:
                    file.unlink()


class MainCITriggerTests(unittest.TestCase):
    def test_every_main_push_has_ci_while_pull_requests_keep_the_path_filter(self):
        workflow = (SCRIPTS.parent / '.github/workflows/ci.yml').read_text()

        def event(name):
            match = re.search(r'^  ' + name + r':\n(.*?)(?=^  [a-z_]+:|^\S|\Z)',
                              workflow, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(match, name)
            return match.group(1)

        push = event('push')
        self.assertIn('branches: [main]', push)
        self.assertNotRegex(push, re.compile(r'^\s+paths(?:-ignore)?:', re.MULTILINE))
        self.assertRegex(event('pull_request'), r'^    paths:')
        self.assertIn('python3 scripts/test-testflight-archive.py', workflow)


if __name__ == '__main__':
    unittest.main()
