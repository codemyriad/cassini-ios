#!/usr/bin/env python3
"""No signing/network/GUI: exercise release decisions, durable upload intent and finalization."""
import datetime as dt
import contextlib
import io
import os
import fcntl
from types import SimpleNamespace
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


def main_run(**changes):
    return dict(dict(head_sha=HEAD, head_branch='main', head_repository={'full_name': daily.REPOSITORY},
                     event='push', status='completed', conclusion='success'), **changes)


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
        good = main_run()
        self.assertTrue(daily.green([good], HEAD))
        for changes in [dict(head_sha=PREVIOUS), dict(status='in_progress'), dict(conclusion='failure')]:
            self.assertFalse(daily.green([dict(good, **changes)], HEAD))
        self.assertFalse(daily.green([], HEAD))

    def test_pr_and_fork_runs_neither_approve_red_main_nor_block_green_main(self):
        invalid = [main_run(event='pull_request'), main_run(event='pull_request_target'),
                   main_run(head_repository={'full_name': 'fork/cassini-ios'}),
                   main_run(head_repository=None), main_run(head_branch='feature'),
                   main_run(event='schedule', head_repository={'full_name': 'fork/cassini-ios'}),
                   main_run(event='schedule', head_repository=None),
                   main_run(event='schedule', head_sha=PREVIOUS),
                   main_run(event='schedule', head_branch='feature')]
        for run in invalid:
            self.assertFalse(daily.green([run, main_run(conclusion='failure')], HEAD))
            self.assertTrue(daily.green([dict(run, conclusion='failure'), main_run()], HEAD))
        for event in ('workflow_dispatch', 'schedule'):
            for pending_or_failed in [dict(status='in_progress', conclusion=None),
                                      dict(status='queued', conclusion=None),
                                      dict(status='completed', conclusion='failure'),
                                      dict(status='completed', conclusion='cancelled')]:
                self.assertFalse(daily.green([main_run(event=event, **pending_or_failed), main_run()], HEAD))
            self.assertTrue(daily.green([main_run(event=event), main_run(conclusion='failure')], HEAD))

    def test_main_ci_search_paginates_past_pr_runs_and_fails_closed_without_a_match(self):
        excluded = [main_run(event='pull_request') for _ in range(100)]
        with patch.object(daily, 'gh', side_effect=[{'workflow_runs': excluded},
                                                  {'workflow_runs': [main_run(conclusion='failure')]}]) as api:
            self.assertFalse(daily.main_ci_green(HEAD))
            self.assertEqual([call.kwargs['page'] for call in api.call_args_list], [1, 2])
        with patch.object(daily, 'gh', side_effect=[{'workflow_runs': excluded},
                                                  {'workflow_runs': [main_run(event='workflow_dispatch')]}]):
            self.assertTrue(daily.main_ci_green(HEAD))
        with patch.object(daily, 'gh', return_value={'workflow_runs': [main_run(event='pull_request')]}):
            self.assertFalse(daily.main_ci_green(HEAD))

    def test_testflight_text_sanitizes_markup_controls_and_surrogates_but_keeps_unicode(self):
        raw = 'Fix Flow<Settings> & voices 😀\x00\t\r\u202eevil\ud800\nNext line café'
        clean = daily.testflight_notes(raw)
        self.assertEqual(clean, 'Fix Flow‹Settings› & voices 😀    evil \nNext line café')
        self.assertEqual(daily.testflight_notes(clean), clean)
        self.assertEqual(daily.testflight_notes('Family 👩\u200d👩'), 'Family 👩\u200d👩')

    def test_testflight_limit_counts_utf16_and_never_splits_a_supplementary_character(self):
        exact = 'a' * 3998 + '😀'
        self.assertEqual(daily.testflight_notes(exact), exact)
        for raw in [exact + 'x', '😀' * 2001, 'a' * 3997 + '😀xx']:
            clean = daily.testflight_notes(raw)
            self.assertLessEqual(len(clean.encode('utf-16-le')) // 2, 4000)
            self.assertTrue(clean.endswith('\n…'))
            self.assertEqual(clean.encode('utf-16-le').decode('utf-16-le'), clean)

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
        self.ci = [main_run()]
        self.canonical_head = HEAD
        self.worker_failure = False
        self.upload_failure = False
        self.upload_stdout = json.dumps({'details': {'delivery-uuid': '12345678-1234-1234-1234-123456789abc'}})
        self.upload_stderr = ''
        self.mounted = True
        self.red_after_validation = False
        self.assert_upload_intent = True
        self.raw_notes = '- An English improvement (#10)'

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
            return subprocess.CompletedProcess(args, 0, self.upload_stdout, self.upload_stderr)
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
             patch.object(daily, 'release_notes', side_effect=lambda *a: self.raw_notes), \
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

    def test_publish_ignores_pr_ci_but_cannot_upload_when_real_main_is_red(self):
        self.ci = [main_run(event='pull_request'), main_run(conclusion='failure')]
        self.publish()
        self.assertFalse(self.state.exists())
        self.assertEqual(self.apple.uploads, [])
        self.ci = [main_run(event='pull_request', conclusion='failure'), main_run()]
        self.publish()
        self.assertEqual(self.apple.uploads, ['12'])

    def test_newer_failed_or_pending_scheduled_run_blocks_publication(self):
        for nightly in [main_run(event='schedule', conclusion='failure'),
                        main_run(event='schedule', status='in_progress', conclusion=None),
                        main_run(event='schedule', status='queued', conclusion=None),
                        main_run(event='schedule', conclusion='cancelled')]:
            with self.subTest(status=nightly['status'], conclusion=nightly['conclusion']):
                self.calls.clear()
                self.ci = [nightly, main_run()]
                self.publish()
                self.assertFalse(self.state.exists())
                self.assertFalse(any('worktree' in c for c in self.calls))
                self.assertEqual(self.apple.uploads, [])
        # Conversely, a newer green nightly clears an older failed push on the same SHA.
        self.ci = [main_run(event='schedule'), main_run(conclusion='failure')]
        self.publish()
        self.assertEqual(self.apple.uploads, ['12'])

    def test_raw_release_artifacts_survive_while_testflight_receives_sanitized_bounded_text(self):
        self.raw_notes = '- Fix Flow<English>\x1b\u202e\ud800 ' + '😀' * 2001
        self.publish()
        pending = self.apple.finished[0]
        output = Path(pending['output'])
        plan = json.loads((output/'release-plan.json').read_text())
        self.assertEqual(plan['raw_notes'], self.raw_notes)
        self.assertEqual((output/'release-notes.txt').read_text(),
                         (self.raw_notes + '\n').encode('utf-8', errors='backslashreplace').decode('utf-8'))
        self.assertEqual(plan['testflight_notes'], pending['notes'])
        self.assertIn('Flow‹English›', pending['notes'])
        self.assertNotIn('\x1b', pending['notes'])
        self.assertNotIn('\u202e', pending['notes'])
        self.assertLessEqual(len(pending['notes'].encode('utf-16-le')) // 2, 4000)
        self.assertTrue(pending['notes'].endswith('\n…'))

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

    def test_upload_json_is_parsed_from_stdout_only_with_noisy_stderr(self):
        self.upload_stderr = 'ContentDelivery { dictionary = value; }\ntrailing diagnostic after JSON'
        self.publish()
        pending = self.apple.finished[0]
        self.assertEqual(pending['delivery'], '12345678-1234-1234-1234-123456789abc')
        log = (Path(pending['output'])/'upload.log').read_text()
        self.assertIn(self.upload_stdout, log)
        self.assertIn(self.upload_stderr, log)
        self.assertEqual(self.apple.uploads, ['12'])

    def test_upload_app_without_details_finishes_in_same_run_via_stderr_or_build_query(self):
        self.upload_stdout = json.dumps({'tool-version': '1', 'os-version': 'macOS', 'success-message': 'Upload succeeded'})
        self.upload_stderr = 'ContentDelivery { log = metadata; }\nDelivery UUID: 12345678-1234-1234-1234-123456789abc'
        self.publish()
        self.assertEqual(self.apple.finished[0]['delivery'], '12345678-1234-1234-1234-123456789abc')
        self.assertEqual(json.loads(self.state.read_text())['head'], HEAD)
        self.assertEqual(self.apple.uploads, ['12'])

    def test_successful_upload_without_any_json_or_uuid_uses_build_query_immediately(self):
        self.upload_stdout = 'Upload succeeded (no machine-readable metadata)'
        self.upload_stderr = 'ContentDelivery { log = metadata; }'
        self.publish()
        pending = self.apple.finished[0]
        self.assertIsNone(pending['delivery'])
        wait = next(c for c in self.calls if '--build-status' in c)
        self.assertNotIn('--delivery-id', wait)
        for field in ['--apple-id', '--bundle-version', '--bundle-short-version-string', '--wait']:
            self.assertIn(field, wait)
        self.assertEqual(json.loads(self.state.read_text())['head'], HEAD)
        self.assertEqual(self.apple.uploads, ['12'])

    def test_optional_upload_metadata_never_turns_success_into_a_parse_failure(self):
        for stdout in ['{}', '{"details": null}', '{"details": []}', '{"details": {"delivery-uuid": "bad"}}',
                       'prefix\n{"success-message":"Uploaded"}\ntrailing status', '{broken json']:
            self.assertIsNone(daily.delivery_uuid(stdout, '{"details":{"delivery-uuid":"12345678-1234-1234-1234-123456789abc"}}'))
        self.assertEqual(daily.delivery_uuid('prefix\n{"details":{"delivery-uuid":"12345678-1234-1234-1234-123456789abc"}}\nstatus', ''),
                         '12345678-1234-1234-1234-123456789abc')

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
            self.assertEqual(apple.finish(dict(build='12', version='0.1.0', notes='- English<Flow>\x00 (#10)')), '12')
            endpoint, method, payload = request.call_args.args
            self.assertEqual((endpoint, method), ('/v1/betaBuildLocalizations', 'POST'))
            self.assertEqual(payload['data']['attributes'], {'locale': 'en-US', 'whatsNew': '- English‹Flow›  (#10)'})
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


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root/'state'
        self.state.mkdir()
        self.config = self.root/'config.json'
        self.config.write_text(json.dumps(dict(state_dir=str(self.state), source=str(self.root/'source'),
                                              notification_file=str(self.root/'inbox'))))
        self.config.chmod(0o600)

    def invoke(self, in_slot=True, inherited=None):
        arguments = ['daily-testflight.py', '--scheduled', '--refresh-control', '--config', str(self.config)]
        if inherited is not None:
            arguments += ['--release-lock-fd', str(inherited)]
        with patch.object(daily.sys, 'argv', arguments), patch.object(daily.platform, 'node', return_value='drmeyers'), \
             patch.object(daily.platform, 'system', return_value='Darwin'), patch.object(daily, 'scheduled', return_value=in_slot), \
             patch.object(daily, 'command') as command, patch.object(daily, 'refresh_control') as refresh, \
             patch.object(daily, 'publish') as publish, contextlib.redirect_stdout(io.StringIO()):
            result = daily.main()
        return result, command, refresh, publish

    def test_non_slot_hour_performs_no_ref_or_release_work(self):
        result, command, refresh, publish = self.invoke(in_slot=False)
        self.assertEqual(result, 0)
        command.assert_not_called()
        refresh.assert_not_called()
        publish.assert_not_called()

    def test_active_manual_release_prevents_hourly_refresh_using_process_events(self):
        for reexecute in (False, True):
            with self.subTest(reexecute=reexecute):
                ready_read, ready_write = os.pipe()
                stop_read, stop_write = os.pipe()
                code = "import fcntl,os,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); "
                if reexecute:
                    child = "import fcntl,os,sys; fcntl.flock(int(sys.argv[1]),fcntl.LOCK_EX|fcntl.LOCK_NB); os.write(int(sys.argv[2]),b'R'); os.read(int(sys.argv[3]),1)"
                    code += ("os.set_inheritable(f.fileno(),True); os.set_inheritable(int(sys.argv[2]),True); "
                             "os.set_inheritable(int(sys.argv[3]),True); "
                             "os.execv(sys.executable,[sys.executable,'-c'," + repr(child)
                             + ",str(f.fileno()),sys.argv[2],sys.argv[3]])")
                else:
                    code += "os.write(int(sys.argv[2]),b'R'); os.read(int(sys.argv[3]),1)"
                process = subprocess.Popen([daily.sys.executable, '-c', code, str(self.state/'release.lock'),
                                            str(ready_write), str(stop_read)], pass_fds=(ready_write, stop_read))
                os.close(ready_write)
                os.close(stop_read)
                try:
                    self.assertEqual(os.read(ready_read, 1), b'R')  # lock-acquired/exec-completed event
                    result, command, refresh, publish = self.invoke()
                    self.assertEqual(result, 0)
                    command.assert_not_called()
                    refresh.assert_not_called()
                    publish.assert_not_called()
                finally:
                    os.write(stop_write, b'X')
                    os.close(stop_write)
                    os.close(ready_read)
                    process.wait(timeout=30)  # outer hang guard only
                self.assertEqual(process.returncode, 0)

    def test_inherited_mutex_survives_controller_reexec_without_reacquiring_another_file(self):
        with (self.state/'release.lock').open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            inherited = os.dup(held.fileno())
            result, command, refresh, publish = self.invoke(inherited=inherited)
            self.assertEqual(result, 0)
            command.assert_not_called()
            self.assertEqual(refresh.call_count, 1)
            self.assertEqual(publish.call_count, 1)
            with self.assertRaises(OSError):
                os.fstat(inherited)  # controller closed only its inherited descriptor on exit

    def test_refresh_execs_updated_controller_with_the_same_locked_descriptor(self):
        source = self.root/'source'
        (source/'scripts').mkdir(parents=True)
        script = source/'scripts/daily-testflight.py'
        arguments = SimpleNamespace(config=self.config)
        with (self.state/'release.lock').open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with patch.object(daily, '__file__', str(script)), \
                 patch.object(daily, 'command', side_effect=['main', '', 'old', '', '', 'new']) as command, \
                 patch.object(daily.os, 'execv') as execute:
                daily.refresh_control(dict(source=str(source)), arguments, held)
                self.assertTrue(os.get_inheritable(held.fileno()))
                executable, argv = execute.call_args.args
                self.assertEqual(executable, daily.sys.executable)
                self.assertEqual(argv[-2:], ['--release-lock-fd', str(held.fileno())])
                self.assertIn('--scheduled', argv)
                self.assertEqual(command.call_args_list[3].args[0][:3], ['git', 'fetch', 'origin'])
                os.set_inheritable(held.fileno(), False)

    def test_launchd_stderr_inbox_does_not_duplicate_the_same_failure_line(self):
        inbox_path = self.root/'inbox'
        with inbox_path.open('w') as stream, contextlib.redirect_stderr(stream):
            daily.notify_failure('[iOS] daily test release failed: controlled fixture', inbox_path)
        self.assertEqual(inbox_path.read_text(), '[iOS] daily test release failed: controlled fixture\n')


if __name__ == '__main__':
    unittest.main()
