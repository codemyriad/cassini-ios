#!/usr/bin/env python3
import hashlib
import base64
import importlib.util
import sys
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

# Fault controls must not dirty the source checkout with interpreter caches.
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('brand_upstream', Path(__file__).with_name('check-brand-upstream.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpstreamTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'CassiniShared/Brand'
        self.folder.mkdir(parents=True)
        self.raw = b'{"tokens": {}}\n'
        self.pin = dict(repository='https://github.com/codemyriad/cassini-ux', path='brand/tokens.json',
                        commit='e' * 40, sha256=hashlib.sha256(self.raw).hexdigest())
        self.write_pin()
        (self.folder / 'tokens.json').write_bytes(self.raw)

    def write_pin(self):
        (self.folder / 'UPSTREAM.json').write_text(json.dumps(self.pin))

    def test_fetches_the_exact_commit_and_compares_bytes(self):
        endpoints = []
        module.check(self.root, lambda endpoint: endpoints.append(endpoint) or self.raw)
        self.assertEqual(endpoints, ['repos/codemyriad/cassini-ux/contents/brand/tokens.json?ref=' + 'e' * 40])

    def test_equivalent_json_with_different_bytes_is_rejected(self):
        (self.folder / 'tokens.json').write_bytes(b'{ "tokens": {} }\n')
        with self.assertRaisesRegex(ValueError, 'byte-identical'):
            module.check(self.root, lambda _: self.raw)

    def test_replacing_both_local_bytes_and_local_hash_does_not_pass(self):
        local = b'{"tokens": {"invented": {}}}\n'
        self.pin['sha256'] = hashlib.sha256(local).hexdigest()
        self.write_pin()
        (self.folder / 'tokens.json').write_bytes(local)
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            module.check(self.root, lambda _: self.raw)

    def test_floating_or_foreign_pins_are_rejected_before_fetch(self):
        for key, value in [('commit', 'main'), ('repository', 'https://example.com'), ('path', '../tokens.json')]:
            with self.subTest(key=key):
                old = self.pin[key]
                self.pin[key] = value
                self.write_pin()
                with self.assertRaisesRegex(ValueError, 'immutable'):
                    module.check(self.root, lambda _: self.fail('invalid source was fetched'))
                self.pin[key] = old

    def test_authentication_errors_are_fail_closed_without_echoing_credentials(self):
        with patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='', stderr='secret')):
            with self.assertRaisesRegex(ValueError, 'existing read-only CI credentials') as result:
                module.check(self.root)
            self.assertNotIn('secret', str(result.exception))

    def test_real_gh_path_decodes_multiline_base64_without_reformatting(self):
        encoded = base64.b64encode(self.raw).decode()
        payload = json.dumps({'encoding': 'base64', 'content': encoded[:8] + '\n' + encoded[8:] + '\n'})
        with patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=payload)) as run:
            module.check(self.root)
        self.assertEqual(run.call_args.args[0], ['gh', 'api',
                         'repos/codemyriad/cassini-ux/contents/brand/tokens.json?ref=' + 'e' * 40])

    def test_private_upstream_step_skips_forks_and_foreign_repositories(self):
        workflow = Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml'
        step = workflow.read_text().split('      - name: Compare brand bytes with pinned cassini-ux source\n', 1)[1]
        step = step.split('      - name:', 1)[0]
        self.assertIn('run: python3 scripts/check-brand-upstream.py', step)
        condition = next(line.strip()[4:] for line in step.splitlines() if line.strip().startswith('if: '))
        expression = condition.replace('&&', ' and ').replace('||', ' or ')
        for event, repository, head, expected in [
            ('push', 'codemyriad/cassini-ios', None, True),
            ('schedule', 'codemyriad/cassini-ios', None, True),
            ('workflow_dispatch', 'codemyriad/cassini-ios', None, True),
            ('pull_request', 'codemyriad/cassini-ios', 'codemyriad/cassini-ios', True),
            ('pull_request', 'codemyriad/cassini-ios', 'outsider/cassini-ios', False),
            ('pull_request', 'codemyriad/cassini-ios', None, False),
            ('push', 'outsider/cassini-ios', None, False),
            ('issue_comment', 'codemyriad/cassini-ios', 'codemyriad/cassini-ios', False),
        ]:
            with self.subTest(event=event, repository=repository, head=head):
                github = SimpleNamespace(repository=repository, event_name=event,
                         event=SimpleNamespace(pull_request=SimpleNamespace(head=SimpleNamespace(repo=SimpleNamespace(full_name=head)))))
                self.assertEqual(eval(expression, {'__builtins__': {}}, {'github': github}), expected)


if __name__ == '__main__':
    unittest.main()
