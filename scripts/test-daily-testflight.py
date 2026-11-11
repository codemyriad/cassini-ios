#!/usr/bin/env python3
"""No signing/network/GUI: exercise release decisions, durable upload intent and finalization."""
import datetime as dt
import contextlib
import io
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch, mock_open

SPEC = importlib.util.spec_from_file_location('daily', Path(__file__).with_name('daily-testflight.py'))
daily = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(daily)
HEAD = 'a' * 40
PREVIOUS = 'b' * 40


def build(number, version='0.1.0'):
    return {'id': str(number), 'marketingVersion': version, 'attributes': {'version': str(number),
        'processingState': 'VALID', 'expired': False, 'buildAudienceType': 'INTERNAL_ONLY'}}


class FakeApple:
    key_path = Path('/private/existing.p8')
    key_id = 'existing'
    issuer_id = 'existing'

    def __init__(self):
        self.uploads = []
        self.finished = []
        self.remote = [build(11), build(900, '0.0.1')]

    def auth(self):
        return []

    def guard(self):
        pass

    def builds(self):
        return self.remote

    def finish(self, pending):
        self.finished.append(pending)
        if not any(b['attributes']['version'] == pending['build'] for b in self.remote):
            raise RuntimeError('ambiguous upload')
        return pending['build']


class ReleaseTests(unittest.TestCase):
    def test_berlin_slots_follow_winter_and_summer_not_the_host_zone(self):
        for month, utc_hours in [(1, (8, 13, 19)), (7, (7, 12, 18))]:
            for hour in range(24):
                now = dt.datetime(2026, month, 15, hour, tzinfo=dt.timezone.utc)
                self.assertEqual(daily.scheduled(now), hour in utc_hours, now)
        # Europe/Berlin's DST transition days use the named zone, not a cached fixed offset.
        self.assertTrue(daily.scheduled(dt.datetime(2026, 3, 29, 7, tzinfo=dt.timezone.utc)))
        self.assertTrue(daily.scheduled(dt.datetime(2026, 10, 25, 8, tzinfo=dt.timezone.utc)))

    def test_latest_exact_head_ci_must_be_green(self):
        good = dict(head_sha=HEAD, status='completed', conclusion='success')
        self.assertTrue(daily.green([good], HEAD))
        for changes in [dict(head_sha=PREVIOUS), dict(status='in_progress'), dict(conclusion='failure')]:
            self.assertFalse(daily.green([dict(good, **changes), good], HEAD))
        self.assertFalse(daily.green([], HEAD))

    def test_build_number_uses_current_version_and_keeps_failed_reservations(self):
        self.assertEqual(daily.next_build([build(11), build(900, '0.0.1')], '0.1.0', {}), '12')
        self.assertEqual(daily.next_build([build(11)], '0.1.0', {'0.1.0': 12}), '13')
        self.assertEqual(daily.next_build([], '0.2.0', {'0.1.0': 20}), '1')
        with self.assertRaisesRegex(RuntimeError, 'non-integer'):
            daily.next_build([build('1.2')], '0.1.0', {})

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root/'control'
        self.source.mkdir()
        self.state = self.root/'state.json'
        self.config = dict(initial_release_head=PREVIOUS, output_root=str(self.root/'outputs'))
        self.apple = FakeApple()
        self.calls = []
        self.ci = [dict(head_sha=HEAD, status='completed', conclusion='success')]
        self.canonical_head = HEAD
        self.worker_failure = False
        self.upload_failure = False
        self.mounted = True
        self.red_after_validation = False
        self.assert_upload_intent = True

    def command(self, args, cwd=None):
        self.calls.append(args)
        if args[:3] == ['git', 'rev-parse', 'origin/main']:
            return HEAD
        if args[:3] == ['git', 'worktree', 'add']:
            checkout = Path(args[4])
            checkout.mkdir()
            (checkout/'project.yml').write_text("MARKETING_VERSION: '0.1.0'\nMARKETING_VERSION: '0.1.0'\n")
        return ''

    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        if args[0].endswith('python3') or 'run-in-gui.py' in str(args):
            context = json.loads(Path(args[-1]).read_text())
            self.assertEqual(context['head'], HEAD)
            self.assertEqual(json.loads(self.state.read_text())['reserved']['0.1.0'], int(context['build']))
            self.assertIn('lockf', args)
            self.assertIn('CASSINI_HEAVY_LOCK_HELD=1', args)
            if self.worker_failure:
                raise RuntimeError('keychain locked')
            output = Path(context['output'])
            ipa = output/'app.ipa'
            ipa.write_bytes(b'controlled signed fixture')
            daily.save(output/'artifact.json', dict(head=HEAD, version='0.1.0', build=context['build'],
                ipa=str(ipa), bytes=ipa.stat().st_size, sha256=hashlib.sha256(ipa.read_bytes()).hexdigest()))
        if '--validate-app' in args and self.red_after_validation:
            self.ci[0]['conclusion'] = 'failure'
        if '--upload-app' in args:
            pending = json.loads(self.state.read_text())['pending']
            self.assertEqual(pending['head'], HEAD)  # intent must already be durable before the side effect
            self.apple.uploads.append(pending['build'])
            if self.upload_failure:
                raise RuntimeError('connection ended after upload started')
            self.apple.remote.append(build(pending['build']))
            kwargs['stdout'].write(json.dumps({'details': {'delivery-uuid': 'delivery'}}))
        if '--build-status' in args:
            self.assertIn('--wait', args)
        return subprocess.CompletedProcess(args, 0)

    def gh(self, endpoint, **parameters):
        if endpoint.endswith('/git/ref/heads/main'):
            return {'object': {'sha': self.canonical_head}}
        self.assertNotIn('event', parameters)  # A newer manual red/pending CI run must not be hidden.
        return {'workflow_runs': self.ci}

    def publish(self):
        with patch.object(daily, 'command', self.command), \
             patch.object(daily, 'gh', self.gh), \
             patch.object(daily, 'release_notes', return_value='- An English improvement (#10)'), \
             patch.object(daily.os.path, 'ismount', side_effect=lambda *_: self.mounted), \
             patch.object(daily.Path, 'is_relative_to', return_value=True), \
             patch.object(daily.subprocess, 'run', self.fake_run), contextlib.redirect_stdout(io.StringIO()):
            daily.publish(self.config, self.state, self.source, self.apple)

    def test_unchanged_and_red_main_never_build_or_upload(self):
        daily.save(self.state, dict(head=HEAD))
        self.publish()
        self.assertEqual(self.apple.uploads, [])
        self.assertFalse(any('worktree' in c for c in self.calls))
        self.state.unlink()
        self.ci[0]['conclusion'] = 'failure'
        self.publish()
        self.assertFalse(self.state.exists())
        self.assertEqual(self.apple.uploads, [])

    def test_success_advances_watermark_only_after_internal_confirmation(self):
        self.publish()
        state = json.loads(self.state.read_text())
        self.assertEqual((state['head'], state['version'], state['build']), (HEAD, '0.1.0', '12'))
        self.assertNotIn('pending', state)
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(len(self.apple.finished), 1)
        self.publish()
        self.assertEqual(self.apple.uploads, ['12'])

    def test_failed_archive_keeps_reservation_but_no_upload_intent(self):
        self.worker_failure = True
        with self.assertRaisesRegex(RuntimeError, 'keychain locked'):
            self.publish()
        state = json.loads(self.state.read_text())
        self.assertEqual(state['reserved']['0.1.0'], 12)
        self.assertNotIn('pending', state)
        self.worker_failure = False
        self.publish()
        self.assertEqual(self.apple.uploads, ['13'])

    def test_ambiguous_upload_is_never_automatically_submitted_twice(self):
        self.upload_failure = True
        with self.assertRaisesRegex(RuntimeError, 'connection ended'):
            self.publish()
        state = json.loads(self.state.read_text())
        self.assertIn('pending', state)
        self.assertNotIn('head', state)
        self.upload_failure = False
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            self.publish()
        self.assertEqual(self.apple.uploads, ['12'])
        self.apple.remote.append(build(12))
        self.publish()  # Finalize the existing upload, not another archive or submission.
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(json.loads(self.state.read_text())['head'], HEAD)

    def test_apple_rejects_foreign_pagination_and_any_non_beta_metadata_write(self):
        apple = daily.Apple.__new__(daily.Apple)
        for endpoint in ['https://foreign.example/v1/builds', '//foreign.example/v1/builds']:
            with self.assertRaisesRegex(RuntimeError, 'foreign'):
                apple.request(endpoint)
        for endpoint in ['/v1/betaGroups', '/v1/appStoreVersions', '/v1/betaTesters']:
            with self.assertRaisesRegex(RuntimeError, 'Only TestFlight'):
                apple.request(endpoint, 'POST', {})

    def test_existing_internal_group_is_required_without_mutating_membership(self):
        apple = daily.Apple.__new__(daily.Apple)
        for changed in [dict(isInternalGroup=False), dict(hasAccessToAllBuilds=False), dict(name='external')]:
            group = dict(name='cassini', isInternalGroup=True, hasAccessToAllBuilds=True, **{})
            group.update(changed)
            with patch.object(apple, 'request', side_effect=[
                    {'data': {'attributes': {'bundleId': 'io.codemyriad.cassini'}}},
                    {'data': {'attributes': group}}]) as request:
                with self.assertRaisesRegex(RuntimeError, 'Existing internal'):
                    apple.guard()
                self.assertEqual(len(request.call_args_list), 2)
                self.assertTrue(all(len(c.args) == 1 for c in request.call_args_list))

    def test_public_audience_and_failed_processing_cannot_advance_or_write_notes(self):
        for fields in [dict(buildAudienceType='APP_STORE_ELIGIBLE'), dict(processingState='FAILED'), dict(expired=True)]:
            apple = daily.Apple.__new__(daily.Apple)
            item = build(12)
            item['attributes'].update(fields)
            with patch.object(apple, 'guard'), patch.object(apple, 'builds', return_value=[item]), \
                 patch.object(apple, 'request') as request:
                with self.assertRaises(RuntimeError):
                    apple.finish(dict(build='12', version='0.1.0', notes='- English fixture (#10)'))
                request.assert_not_called()

    def test_failed_jwt_generation_never_echoes_captured_output(self):
        apple = daily.Apple.__new__(daily.Apple)
        apple.key_path = Path('/private/existing.p8')
        apple.key_id = apple.issuer_id = 'existing'
        with patch.object(daily.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 1, 'private-dummy-sentinel', 'private-dummy-sentinel')):
            with self.assertRaisesRegex(RuntimeError, 'authentication failed') as error:
                apple.request('/v1/builds')
        self.assertNotIn('private-dummy-sentinel', str(error.exception))

    def test_unchanged_or_red_skips_do_not_require_any_apple_credentials(self):
        with patch.object(daily, 'command', self.command), patch.object(daily, 'gh', self.gh), \
             patch.object(daily, 'Apple', side_effect=AssertionError('must not authenticate')) as apple, \
             contextlib.redirect_stdout(io.StringIO()):
            daily.save(self.state, dict(head=HEAD))
            daily.publish(self.config, self.state, self.source)
            self.state.unlink()
            self.ci[0]['conclusion'] = 'failure'
            daily.publish(self.config, self.state, self.source)
            apple.assert_not_called()

    def test_ci_that_turns_red_during_validation_stops_before_upload_intent(self):
        self.red_after_validation = True
        self.publish()
        state = json.loads(self.state.read_text())
        self.assertNotIn('head', state)
        self.assertNotIn('pending', state)
        self.assertEqual(self.apple.uploads, [])

    def test_historical_green_origin_cannot_replace_canonical_current_main(self):
        self.canonical_head = PREVIOUS
        self.publish()
        self.assertFalse(self.state.exists())
        self.assertFalse((self.root/'outputs').exists())
        self.assertEqual(self.apple.uploads, [])

    def test_missing_external_volume_blocks_pending_recovery_without_writing_it(self):
        self.upload_failure = True
        with self.assertRaises(RuntimeError):
            self.publish()
        self.mounted = False
        with patch.object(daily, 'wait_processing') as wait:
            with self.assertRaisesRegex(RuntimeError, 'stale mount-point'):
                self.publish()
            wait.assert_not_called()
        self.assertEqual(self.apple.uploads, ['12'])

    def test_absent_external_volume_is_refused_before_any_build_output(self):
        self.mounted = False
        with self.assertRaisesRegex(RuntimeError, 'stale mount-point'):
            self.publish()
        self.assertFalse((self.root/'outputs').exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.apple.uploads, [])

    def test_notes_keep_merged_main_titles_and_deduplicate_associated_prs(self):
        merged = dict(number=10, title='English improvement', merged_at='2026-11-11', base=dict(ref='main'))
        other = dict(number=11, title='Unmerged draft', merged_at=None, base=dict(ref='main'))
        with patch.object(daily, 'command', side_effect=['', 'c1\nc2']), \
             patch.object(daily, 'gh', side_effect=[[merged, other], [merged]]):
            notes = daily.release_notes(self.source, PREVIOUS, HEAD)
        self.assertEqual(notes, '- English improvement (#10)')

    def test_metadata_failure_keeps_intent_and_resume_does_not_reupload(self):
        original = self.apple.finish
        with patch.object(self.apple, 'finish', side_effect=RuntimeError('beta notes unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'beta notes'):
                self.publish()
        state = json.loads(self.state.read_text())
        self.assertNotIn('head', state)
        self.assertIn('delivery', state['pending'])
        self.apple.finish = original
        self.publish()
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(json.loads(self.state.read_text())['head'], HEAD)

    def test_success_writes_only_the_testflight_build_notes(self):
        apple = daily.Apple.__new__(daily.Apple)
        with patch.object(apple, 'guard'), patch.object(apple, 'builds', return_value=[build(12)]), \
             patch.object(apple, 'request', side_effect=[
                 {'data': {'attributes': {'internalBuildState': 'IN_BETA_TESTING'}}}, {'data': []}, {}]) as request:
            self.assertEqual(apple.finish(dict(build='12', version='0.1.0', notes='- English (#10)')), '12')
            endpoint, method, payload = request.call_args.args
            self.assertEqual((endpoint, method), ('/v1/betaBuildLocalizations', 'POST'))
            self.assertEqual(payload['data']['attributes'], {'locale': 'en-US', 'whatsNew': '- English (#10)'})
            self.assertEqual(payload['data']['relationships']['build']['data']['id'], '12')

    def test_wrong_host_fails_with_a_one_line_coordinator_notification(self):
        inbox = mock_open()
        with patch.object(daily.platform, 'node', return_value='rented-mac'), \
             patch.object(daily.platform, 'system', return_value='Darwin'), \
             patch.object(daily.sys, 'argv', ['daily-testflight.py', '--manual', '--config', '/unused']), \
             patch.object(daily.Path, 'open', inbox), patch('builtins.print'):
            self.assertEqual(daily.main(), 1)
        message = inbox().write.call_args.args[0]
        self.assertTrue(message.startswith('[iOS] daily test release failed: '))
        self.assertIn('only on drmeyers', message)
        self.assertEqual(message.count('\n'), 1)

    def test_launchd_uses_hourly_event_and_workflow_is_main_only_drmeyers_only(self):
        scripts = Path(__file__).parent
        plist = plistlib.loads((scripts/'launchd/io.codemyriad.cassini.daily-testflight.plist').read_bytes())
        self.assertEqual(plist['StartCalendarInterval'], {'Minute': 0})
        self.assertNotIn('StartInterval', plist)
        workflow = (scripts.parent/'.github/workflows/daily-testflight.yml').read_text()
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn('[self-hosted, macOS, ARM64, cassini-ios-release-drmeyers]', workflow)
        self.assertNotIn('cm-mac-m4', workflow.split('runs-on:')[1])
        self.assertIn('cancel-in-progress: false', workflow)


if __name__ == '__main__':
    unittest.main()
