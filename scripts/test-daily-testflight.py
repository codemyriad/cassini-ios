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
import sys
import shutil
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

    def test_testflight_sink_rejects_developer_or_unsafe_text(self):
        for raw in ['Developer title (#10)', 'D95: CI fixes', 'Fix <Settings>', 'Text\x00.', 'Text\u202e.', 'Source.swift']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                daily.testflight_notes(raw)
        self.assertEqual(daily.testflight_notes('Your notes keep their names. Café voices 😀.'),
                         'Your notes keep their names. Café voices 😀.')

    def test_testflight_sink_rejects_overflow_instead_of_cutting_a_fragment(self):
        self.assertEqual(daily.testflight_notes('a' * 497 + '😀'), 'a' * 497 + '😀')
        for raw in ['a' * 498 + '😀', 'a' * 500]:
            with self.assertRaises(ValueError): daily.testflight_notes(raw)

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
        self.origin_head = HEAD
        self.non_ancestor = set()
        self.now = 0.0
        self.sleeps = []
        self.sleep_hook = None
        self.after_validation_hook = None
        self.worker_failure = False
        self.upload_failure = False
        self.upload_stdout = json.dumps({'details': {'delivery-uuid': '12345678-1234-1234-1234-123456789abc'}})
        self.upload_stderr = ''
        self.mounted = True
        self.red_after_validation = False
        self.assert_upload_intent = True
        self.raw_notes = '- Developer title from CI (#10), D95'
        directory = self.source/'release-notes.d'
        directory.mkdir()
        self.fragment = directory/'english-feature.md'
        self.fragment.write_text('kind: new\n---\nYou can now export a transcript.\n')
        self.fragment_hash = hashlib.sha256(self.fragment.read_bytes()).hexdigest()

    def clock(self):
        return self.now

    def fake_sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds
        if self.sleep_hook is not None:
            self.sleep_hook(seconds)

    def command(self, args, cwd=None):
        self.calls.append(args)
        if args[:3] == ['git', 'rev-parse', 'origin/main']:
            return self.origin_head
        if args[:3] == ['git', 'merge-base', '--is-ancestor']:
            if (args[3], args[4]) in self.non_ancestor:
                raise RuntimeError('git merge-base failed (exit 1); inspect retained run logs')
            return ''
        if args[:3] == ['git', 'worktree', 'add']:
            checkout = Path(args[4])
            checkout.mkdir()
            if (self.source/'release-notes.d').exists():
                shutil.copytree(self.source/'release-notes.d', checkout/'release-notes.d')
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
        if '--validate-app' in args and self.after_validation_hook is not None:
            self.after_validation_hook()
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
        self.assertEqual(parameters.get('head_sha'), HEAD)
        return {'workflow_runs': self.ci}

    def publish(self):
        with patch.object(daily, 'command', self.command), \
             patch.object(daily, 'gh', self.gh), \
             patch.object(daily, 'release_notes', side_effect=lambda *a: self.raw_notes), \
             patch.object(daily.os.path, 'ismount', side_effect=lambda *_: self.mounted), \
             patch.object(daily.Path, 'is_relative_to', return_value=True), \
             patch.object(daily.subprocess, 'run', self.fake_run), contextlib.redirect_stdout(io.StringIO()):
            daily.publish(self.config, self.state, self.source, self.apple,
                          clock=self.clock, sleep=self.fake_sleep)

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
                self.now = 0.0
                self.sleeps.clear()
                self.ci = [nightly, main_run()]
                self.publish()
                self.assertFalse(self.state.exists())
                self.assertFalse(any('worktree' in c for c in self.calls))
                self.assertEqual(self.apple.uploads, [])
                if nightly['status'] == 'completed':
                    self.assertEqual(self.sleeps, [])
                else:
                    self.assertEqual(sum(self.sleeps), daily.CI_WAIT_SECONDS)
        # Conversely, a newer green nightly clears an older failed push on the same SHA.
        self.ci = [main_run(event='schedule'), main_run(conclusion='failure')]
        self.publish()
        self.assertEqual(self.apple.uploads, ['12'])

    def test_slot_waits_bounded_for_in_progress_ci_and_publishes_when_green(self):
        for event in ('push', 'workflow_dispatch', 'schedule'):
            with self.subTest(event=event):
                self.setUp()
                self.ci = [main_run(event=event, status='queued', conclusion=None)]
                transitions = [main_run(event=event, status='in_progress', conclusion=None),
                               main_run(event=event, status='completed', conclusion='success')]

                def advance(_seconds, transitions=transitions):
                    if transitions:
                        self.ci = [transitions.pop(0)]

                self.sleep_hook = advance
                self.publish()
                self.assertEqual(self.sleeps, [30, 30])
                self.assertEqual(self.apple.uploads, ['12'])
                self.assertEqual(json.loads(self.state.read_text())['head'], HEAD)

    def test_in_progress_ci_finishing_red_stops_immediately_without_uploading(self):
        self.ci = [main_run(status='in_progress', conclusion=None)]
        self.sleep_hook = lambda _seconds: setattr(
            self, 'ci', [main_run(status='completed', conclusion='failure')])
        self.publish()
        self.assertEqual(self.sleeps, [30])
        self.assertFalse(self.state.exists())
        self.assertEqual(self.apple.uploads, [])

    def test_wait_main_ci_green_clamps_final_sleep_at_deadline(self):
        self.ci = [main_run(status='in_progress', conclusion=None)]
        with patch.object(daily, 'gh', self.gh):
            self.assertFalse(daily.wait_main_ci_green(HEAD, deadline=45.0,
                                                     clock=self.clock, sleep=self.fake_sleep))
        self.assertEqual(self.sleeps, [30, 15.0])
        self.assertEqual(self.now, 45.0)

    def test_main_fast_forwarding_during_archive_still_publishes_admitted_head(self):
        newer = 'c' * 40

        def advance_main_during_validation():
            self.origin_head = newer
            self.canonical_head = newer

        self.after_validation_hook = advance_main_during_validation
        self.publish()
        state = json.loads(self.state.read_text())
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(state['head'], HEAD)
        self.assertNotEqual(state['head'], newer)
        self.assertIn(['git', 'merge-base', '--is-ancestor', HEAD, newer], self.calls)

    def test_post_validation_fetch_race_and_in_progress_ci_wait_still_publish_admitted_head(self):
        newer = 'e' * 40
        post_fetches = [0]
        original_command = self.command

        def racing_command(args, cwd=None):
            if args[:3] == ['git', 'fetch', 'origin'] and any('--validate-app' in c for c in self.calls):
                post_fetches[0] += 1
                if post_fetches[0] == 2:
                    self.origin_head = newer
            return original_command(args, cwd=cwd)

        def after_validation():
            # Canonical GitHub main advances right after the first post-validation fetch,
            # and a scheduled CI run on HEAD starts in_progress before finishing green.
            self.canonical_head = newer
            self.ci = [main_run(event='schedule', status='in_progress', conclusion=None), main_run()]
            self.sleep_hook = lambda _s: setattr(
                self, 'ci', [main_run(event='schedule', status='completed', conclusion='success'), main_run()])

        self.command = racing_command
        self.after_validation_hook = after_validation
        self.publish()
        self.assertEqual(post_fetches[0], 2)
        self.assertEqual(self.sleeps, [30])
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(json.loads(self.state.read_text())['head'], HEAD)

    def test_rewritten_non_ancestor_main_after_validation_stops_before_upload_intent(self):
        rewritten = 'd' * 40
        self.non_ancestor.add((HEAD, rewritten))

        def rewrite_main_during_validation():
            self.origin_head = rewritten
            self.canonical_head = rewritten

        self.after_validation_hook = rewrite_main_during_validation
        self.publish()
        state = json.loads(self.state.read_text())
        self.assertNotIn('head', state)
        self.assertNotIn('pending', state)
        self.assertEqual(self.apple.uploads, [])

    def test_main_rewritten_during_post_validation_ci_wait_stops_before_upload_intent(self):
        rewritten = 'f' * 40
        self.non_ancestor.add((HEAD, rewritten))

        def start_post_validation_wait():
            self.ci = [main_run(event='schedule', status='in_progress', conclusion=None), main_run()]

            def rewrite_during_wait(_seconds):
                self.origin_head = rewritten
                self.canonical_head = rewritten
                self.ci = [main_run(event='schedule', status='completed', conclusion='success'), main_run()]

            self.sleep_hook = rewrite_during_wait

        self.after_validation_hook = start_post_validation_wait
        self.publish()
        self.assertEqual(self.sleeps, [30])
        state = json.loads(self.state.read_text())
        self.assertNotIn('head', state)
        self.assertNotIn('pending', state)
        self.assertEqual(self.apple.uploads, [])
        self.assertIn(['git', 'merge-base', '--is-ancestor', HEAD, rewritten], self.calls)

    def test_developer_titles_stay_in_audit_and_fold_but_never_reach_testflight(self):
        self.raw_notes = '- Developer CI refactor (#10), D95 </details><script>bad</script>\x1b\u202e\ud800'
        self.publish()
        pending = self.apple.finished[0]
        output = Path(pending['output'])
        plan = json.loads((output/'release-plan.json').read_text())
        self.assertEqual(plan['raw_notes'], self.raw_notes)
        self.assertEqual(plan['testflight_notes'], 'New: You can now export a transcript.')
        self.assertEqual(pending['notes'], plan['testflight_notes'])
        for forbidden in ['Developer', '#10', 'D95', 'CI', '<script>', 'refactor']:
            self.assertNotIn(forbidden, pending['notes'])
        self.assertIn('Developer CI refactor (#10)', (output/'release-notes.txt').read_text())
        body = (output/'release-notes-github.md').read_text()
        self.assertIn('<summary>Developer changelog</summary>', body)
        self.assertIn('&lt;/details&gt;&lt;script&gt;', body)
        self.assertEqual(body.count('</details>'), 1)
        self.assertEqual(plan['fragments'], {'english-feature.md': self.fragment_hash})
        self.assertEqual(json.loads(self.state.read_text())['published_fragments'], plan['fragments'])

    def test_no_user_change_has_the_honest_fallback_and_still_keeps_developer_detail(self):
        self.fragment.unlink()
        self.publish()
        self.assertEqual(self.apple.finished[0]['notes'], daily.FALLBACK_NOTES)
        self.assertEqual(json.loads(self.state.read_text())['published_fragments'], {})

    def test_invalid_user_fragment_fails_before_reserving_or_archiving(self):
        self.fragment.write_text('kind: fixed\n---\nCI refactor for D95 (#123).\n')
        with self.assertRaises(ValueError): self.publish()
        self.assertFalse(self.state.exists())
        self.assertEqual(self.apple.uploads, [])
        self.assertFalse(any('run-in-gui.py' in str(c) for c in self.calls))

    def test_overflow_is_summarized_and_all_covered_fragments_commit_together(self):
        directory = self.source/'release-notes.d'
        for index, area in enumerate(['exported', 'imported', 'shared', 'restored', 'downloaded', 'saved', 'selected', 'older']):
            (directory/f'fix-{index}.md').write_text('kind: fixed\n---\n'
                + f'Your {area} notes keep their original speaker names and recording dates.\n')
        self.publish()
        pending = self.apple.finished[0]
        self.assertTrue(pending['notes'].endswith('and smaller fixes'))
        self.assertIn('You can now export a transcript.', pending['notes'])
        self.assertLess(len(pending['notes']), 500)
        ledger = json.loads(self.state.read_text())['published_fragments']
        self.assertEqual(len(ledger), 9)
        self.assertEqual(ledger, pending['fragments'])

    def finish_pending(self):
        output = io.StringIO()
        with patch.object(daily, 'command', self.command), patch.object(daily, 'gh', self.gh), \
             patch.object(daily.os.path, 'ismount', side_effect=lambda *_: self.mounted), \
             patch.object(daily.Path, 'is_relative_to', return_value=True), \
             patch.object(daily.subprocess, 'run', self.fake_run), contextlib.redirect_stdout(output):
            finished = daily.finish_pending(self.state, self.apple)
        return finished, output.getvalue()

    def test_an_upload_apple_has_not_opened_to_internal_testers_waits_and_the_hourly_check_finishes_it(self):
        original = self.apple.finish
        not_ready = daily.NotReadyYet('Internal TestFlight testing is not ready (PROCESSING)')
        with patch.object(self.apple, 'finish', side_effect=not_ready):
            self.publish()  # The slot: uploaded, Apple not ready. Not an error, and the intent stays.
            waiting = json.loads(self.state.read_text())
            self.assertEqual(waiting['pending']['build'], '12')
            self.assertNotIn('head', waiting)
            self.assertNotIn('published_fragments', waiting)
            archives = sum('worktree' in call for call in self.calls)
            # An hourly check while Apple is still not ready, then the next slot: nothing is fetched, archived or
            # uploaded while that build waits.
            self.calls.clear()
            finished, said = self.finish_pending()
            self.assertFalse(finished)
            self.assertIn('TestFlight 0.1.0 (12)', said)
            self.assertIn('no new upload', said)
            self.assertIn('Apple reports PROCESSING', said)
            self.assertNotIn('failed', said)
            self.publish()
            self.assertEqual([call for call in self.calls if call[0] == 'git'], [])
            self.assertEqual(self.apple.uploads, ['12'])
            self.assertEqual(json.loads(self.state.read_text())['pending'], waiting['pending'])
        self.assertEqual(archives, 1)
        self.apple.finish = original
        finished, said = self.finish_pending()
        self.assertTrue(finished)
        self.assertIn('resumed TestFlight 0.1.0 (12)', said)
        state = json.loads(self.state.read_text())
        self.assertNotIn('pending', state)
        self.assertEqual((state['head'], state['build']), (HEAD, '12'))
        self.assertEqual(state['published_fragments'], {'english-feature.md': self.fragment_hash})
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(self.finish_pending(), (True, ''), 'nothing pending: nothing to do')

    def test_failed_finalization_reloads_frozen_notes_and_only_then_advances_fragment_ledger(self):
        original = self.apple.finish
        with patch.object(self.apple, 'finish', side_effect=RuntimeError('not ready')):
            with self.assertRaises(RuntimeError): self.publish()
        before = json.loads(self.state.read_text())
        self.assertNotIn('published_fragments', before)
        self.fragment.write_text('kind: new\n---\nYou can now rename a transcript.\n')
        self.apple.finish = original
        self.publish()
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(self.apple.finished[-1]['notes'], 'New: You can now export a transcript.')
        self.assertEqual(json.loads(self.state.read_text())['published_fragments'],
                         {'english-feature.md': self.fragment_hash})

    def test_old_pending_developer_notes_are_migrated_without_a_second_upload(self):
        original = self.apple.finish
        with patch.object(self.apple, 'finish', side_effect=RuntimeError('not ready')):
            with self.assertRaises(RuntimeError): self.publish()
        state = json.loads(self.state.read_text())
        del state['pending']['notes_format']
        state['pending']['notes'] = 'CI developer title (#123), D95'
        daily.save(self.state, state)
        self.apple.finish = original
        self.publish()
        self.assertEqual(self.apple.uploads, ['12'])
        self.assertEqual(self.apple.finished[-1]['notes'], daily.FALLBACK_NOTES)
        self.assertEqual(self.apple.finished[-1]['legacy_developer_notes'], 'CI developer title (#123), D95')

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

    def test_developer_audit_also_includes_direct_main_commits(self):
        with patch.object(daily, 'command', side_effect=['', 'c1', 'Improve a user-facing detail']), \
             patch.object(daily, 'gh', return_value=[]):
            self.assertEqual(daily.release_notes(self.source, PREVIOUS, HEAD),
                             '- Improve a user-facing detail (c1)')

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
            self.assertEqual(apple.finish(dict(build='12', version='0.1.0', notes='New: You can export your notes.')), '12')
            endpoint, method, payload = request.call_args.args
            self.assertEqual((endpoint, method), ('/v1/betaBuildLocalizations', 'POST'))
            self.assertEqual(payload['data']['attributes'], {'locale': 'en-US', 'whatsNew': 'New: You can export your notes.'})
            self.assertEqual(payload['data']['relationships']['build']['data']['id'], '12')

    def apple_reporting(self, internal):
        # The real Apple.finish over a processed, internal-only build whose internal state Apple reports as given.
        apple = daily.Apple.__new__(daily.Apple)
        detail = {'data': {'attributes': {} if internal is None else {'internalBuildState': internal}}}
        return apple, [patch.object(apple, 'guard'), patch.object(apple, 'builds', return_value=[build(12)]),
                       patch.object(apple, 'request', return_value=detail)]

    def test_only_states_apple_leaves_on_its_own_are_a_wait_every_other_state_is_an_error_naming_it(self):
        pending = dict(build='12', version='0.1.0', notes='New: You can export your notes.')
        for internal in ['PROCESSING', 'READY_FOR_BETA_TESTING']:
            apple, patches = self.apple_reporting(internal)
            with self.subTest(internal=internal), patches[0], patches[1], patches[2] as request:
                with self.assertRaises(daily.NotReadyYet) as raised:
                    apple.finish(pending)
                self.assertIn(internal, str(raised.exception))
                self.assertTrue(all(len(call.args) == 1 for call in request.call_args_list), 'no write')
        for internal in ['MISSING_EXPORT_COMPLIANCE', 'IN_EXPORT_COMPLIANCE_REVIEW', 'PROCESSING_EXCEPTION', 'EXPIRED',
                         'A_STATE_APPLE_ADDS_LATER', None]:
            apple, patches = self.apple_reporting(internal)
            with self.subTest(internal=internal), patches[0], patches[1], patches[2] as request:
                with self.assertRaises(RuntimeError) as raised:
                    apple.finish(pending)
                self.assertNotIsInstance(raised.exception, daily.NotReadyYet)
                self.assertIn(f'Apple reports {internal}', str(raised.exception))
                self.assertTrue(all(len(call.args) == 1 for call in request.call_args_list), 'no write')

    def test_a_build_missing_export_compliance_fails_every_wake_and_keeps_its_intent(self):
        # Through the real Apple.finish and the real main(): two hourly wakes between slots each end with a
        # failure line that names Apple's state; neither says the build will finish by itself.
        root = self.root
        state_dir = root/'hourly-state'
        state_dir.mkdir()
        waiting = dict(pending=dict(version='0.1.0', build='12', head=HEAD, output=str(root), notes='New: You can export your notes.',
                                    notes_format=daily.NOTES_FORMAT, fragments={}))
        (state_dir/'state.json').write_text(json.dumps(waiting))
        config = root/'hourly-config.json'
        config.write_text(json.dumps(dict(state_dir=str(state_dir), source=str(self.source), notification_file=str(root/'inbox'))))
        config.chmod(0o600)
        apple, patches = self.apple_reporting('MISSING_EXPORT_COMPLIANCE')
        for wake in (1, 2):
            said, complained = io.StringIO(), io.StringIO()
            with self.subTest(wake=wake), patches[0], patches[1], patches[2], \
                 patch.object(daily, 'Apple', return_value=apple), patch.object(daily, 'wait_processing'), \
                 patch.object(daily, 'external_output'), patch.object(daily, 'scheduled', return_value=False), \
                 patch.object(daily.platform, 'node', return_value='drmeyers'), patch.object(daily.platform, 'system', return_value='Darwin'), \
                 patch.object(daily.sys, 'argv', ['daily-testflight.py', '--scheduled', '--refresh-control', '--config', str(config)]), \
                 contextlib.redirect_stdout(said), contextlib.redirect_stderr(complained):
                self.assertEqual(daily.main(), 1)
            self.assertIn('daily test release failed', complained.getvalue())
            self.assertIn('Apple reports MISSING_EXPORT_COMPLIANCE', complained.getvalue())
            self.assertNotIn('hourly check finishes it', said.getvalue() + complained.getvalue())
            self.assertEqual(json.loads((state_dir/'state.json').read_text()), waiting)
        self.assertEqual((root/'inbox').read_text().count('Apple reports MISSING_EXPORT_COMPLIANCE'), 2)

    def test_persisted_developer_text_cannot_reach_the_beta_notes_write(self):
        apple = daily.Apple.__new__(daily.Apple)
        with patch.object(apple, 'guard'), patch.object(apple, 'builds', return_value=[build(12)]), \
             patch.object(apple, 'request', side_effect=[
                 {'data': {'attributes': {'internalBuildState': 'IN_BETA_TESTING'}}}, {'data': []}]) as request:
            with self.assertRaises(ValueError):
                apple.finish(dict(build='12', version='0.1.0', notes='CI developer title (#123), D95'))
            self.assertTrue(all(len(call.args) == 1 for call in request.call_args_list))

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
        self.assertEqual(plist['ProgramArguments'], ['/usr/bin/python3', '__CONTROL__/scripts/run-in-gui.py',
            '/usr/bin/env', 'DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer',
            'CASSINI_RELEASE_STDERR_RELAY=1', '__CONTROL__/scripts/scheduled-testflight.sh'])
        workflow = (scripts.parent/'.github/workflows/daily-testflight.yml').read_text()
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn('[self-hosted, macOS, ARM64, cassini-ios-release-drmeyers]', workflow)
        self.assertNotIn('cm-mac-m4', workflow.split('runs-on:')[1])
        self.assertIn('cancel-in-progress: false', workflow)


class SchedulerTests(unittest.TestCase):
    def test_aqua_stderr_relay_is_the_single_coordinator_failure_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = Path(directory)/'inbox'
            stream = io.StringIO()
            with patch.dict(os.environ, CASSINI_RELEASE_STDERR_RELAY='1'), contextlib.redirect_stderr(stream):
                daily.notify_failure('[iOS] daily test release failed: English fixture', inbox)
            self.assertFalse(inbox.exists(), 'the bridge, not a second append, delivers stderr')
            self.assertEqual(stream.getvalue(), '[iOS] daily test release failed: English fixture\n')

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

    def test_between_slots_a_waiting_upload_is_finished_without_ref_or_release_work(self):
        (self.state/'state.json').write_text(json.dumps(dict(pending=dict(version='0.1.0', build='12', head=HEAD))))
        with patch.object(daily, 'finish_pending', return_value=True) as finish:
            result, command, refresh, publish = self.invoke(in_slot=False)
        self.assertEqual(result, 0)
        finish.assert_called_once_with(self.state/'state.json')
        command.assert_not_called()
        refresh.assert_not_called()
        publish.assert_not_called()

    def test_between_slots_a_waiting_upload_is_left_alone_while_another_release_holds_the_mutex(self):
        (self.state/'state.json').write_text(json.dumps(dict(pending=dict(version='0.1.0', build='12', head=HEAD))))
        with (self.state/'release.lock').open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with patch.object(daily, 'finish_pending') as finish:
                result, _, _, publish = self.invoke(in_slot=False)
        self.assertEqual(result, 0)
        finish.assert_not_called()
        publish.assert_not_called()

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

    def test_starting_the_controller_leaves_a_real_control_clone_clean_for_its_own_check(self):
        # A real clone on main with a real origin and no ignore rules. The controller is started as launchd starts
        # it (a fresh interpreter, bytecode writing not turned off by the environment); then the real
        # refresh_control runs its `git status --porcelain` check on what that start left behind.
        scripts = Path(__file__).resolve().parent
        origin, clone = self.root/'origin.git', self.root/'control'
        git = lambda *args, cwd=None: subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True, text=True)
        git('init', '--bare', '--initial-branch=main', str(origin))
        git('clone', str(origin), str(clone))
        (clone/'scripts').mkdir()
        for name in ['daily-testflight.py', 'testflight_notes.py']:
            shutil.copy(scripts/name, clone/'scripts'/name)
        git('add', '-A', cwd=clone)
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'Control clone', cwd=clone)
        git('push', 'origin', 'HEAD:main', cwd=clone)
        # Bytecode goes beside the module, as on a Python without a separate cache folder (Apple's keeps one
        # outside the source tree, which would hide the problem on this Mac).
        environment = {key: value for key, value in os.environ.items()
                       if key not in ('PYTHONDONTWRITEBYTECODE', 'PYTHONPYCACHEPREFIX')}
        started = subprocess.run([sys.executable, '-X', 'pycache_prefix=', 'scripts/daily-testflight.py', '--help'],
                                 cwd=clone, env=environment, capture_output=True, text=True)
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertEqual(git('status', '--porcelain', '--ignored', cwd=clone).stdout, '')
        driver = ('import importlib.util, sys; sys.dont_write_bytecode = True\n'
                  'spec = importlib.util.spec_from_file_location("control", "scripts/daily-testflight.py")\n'
                  'control = importlib.util.module_from_spec(spec); spec.loader.exec_module(control)\n'
                  'control.refresh_control(dict(source="."), None, None)\n')
        checked = subprocess.run([sys.executable, '-c', driver], cwd=clone, env=environment, capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_launchd_stderr_inbox_does_not_duplicate_the_same_failure_line(self):
        inbox_path = self.root/'inbox'
        with inbox_path.open('w') as stream, contextlib.redirect_stderr(stream):
            daily.notify_failure('[iOS] daily test release failed: controlled fixture', inbox_path)
        self.assertEqual(inbox_path.read_text(), '[iOS] daily test release failed: controlled fixture\n')

    def test_external_tcc_and_gui_preflight_failures_report_remediation_without_burning_builds(self):
        # 1. Scheduled controller (inside run-in-gui.py): PermissionError creating output directory reports
        #    actionable ~/bin/gui-tmux.command remediation before reserving a build number.
        outputs = self.root/'outputs'
        outputs.mkdir()
        with patch.object(Path, 'mkdir', side_effect=PermissionError(1, 'Operation not permitted', str(outputs/'x'))):
            with self.assertRaisesRegex(RuntimeError, r'~/bin/gui-tmux\.command'):
                daily.create_output_directory(outputs)
        # 2. Hourly finish_pending: PermissionError opening processing.log preserves pending state for the next wake.
        pending_state = self.root/'pending-state.json'
        pending = dict(version='0.1.0', build='17', head=HEAD, output=str(outputs),
                       notes='New: You can export your notes.', notes_format=daily.NOTES_FORMAT, fragments={})
        daily.save(pending_state, dict(pending=pending))
        original_open = Path.open
        def deny_processing_log(path_self, *args, **kwargs):
            if path_self.name == 'processing.log':
                raise PermissionError(1, 'Operation not permitted', str(path_self))
            return original_open(path_self, *args, **kwargs)
        with patch.object(daily, 'external_output', return_value=outputs), \
             patch.object(Path, 'open', deny_processing_log):
            with self.assertRaisesRegex(RuntimeError, r'~/bin/gui-tmux\.command'):
                daily.finish_pending(pending_state, FakeApple())
        self.assertEqual(json.loads(pending_state.read_text())['pending'], pending)
        # 3. Manual publish (outside GUIRUN_INSIDE=1): preflight_gui_output probes run-in-gui.py BEFORE git worktree
        #    or next_build(), removes the empty output folder on failure, and never reserves a build number.
        runner = self.root/'source/scripts/run-in-gui.py'
        runner.parent.mkdir(parents=True)
        runner.write_text('#!/usr/bin/env python3\n')
        for code, stderr, pattern in [
            (2, "PermissionError: [Errno 1] Operation not permitted: '/Volumes/DrMeyers2/cassini-ios-daily/x'\n", r'~/bin/gui-tmux\.command'),
            (69, 'GUI tmux session is unavailable. In the Mac\'s logged-in GUI Terminal, run ~/bin/gui-tmux.command\n', r'GUI archive session preflight failed'),
        ]:
            with self.subTest(code=code):
                probe_dir = outputs/f'probe-{code}'
                probe_dir.mkdir()
                fake_probe = subprocess.CompletedProcess(['python3'], code, '', stderr)
                with patch.dict(os.environ, {'GUIRUN_INSIDE': ''}), \
                     patch.object(daily.subprocess, 'run', return_value=fake_probe):
                    with self.assertRaisesRegex(RuntimeError, pattern):
                        daily.preflight_gui_output(runner, probe_dir)
                self.assertFalse(probe_dir.exists(), 'failed GUI preflight cleans up empty output directory')
        # 4. Inside GUIRUN_INSIDE=1, preflight_gui_output skips spawning a nested tmux probe.
        probe_dir = outputs/'already-inside-gui'
        probe_dir.mkdir()
        with patch.dict(os.environ, {'GUIRUN_INSIDE': '1'}), \
             patch.object(daily.subprocess, 'run', side_effect=AssertionError('must not spawn nested run-in-gui')):
            daily.preflight_gui_output(runner, probe_dir)
        self.assertTrue(probe_dir.is_dir())


# CI runs this file; the fragment renderer's own tests and the repository's real fragments are checked with it, so
# a fragment that could not be published fails the pull request that adds it.
_NOTES_SPEC = importlib.util.spec_from_file_location('testflight_notes_tests', Path(__file__).with_name('test-testflight-notes.py'))
_notes_tests = importlib.util.module_from_spec(_NOTES_SPEC)
_NOTES_SPEC.loader.exec_module(_notes_tests)
UserReleaseNotesTests = _notes_tests.UserReleaseNotesTests


class RepositoryFragmentTests(unittest.TestCase):
    def test_every_fragment_in_the_repository_can_be_published(self):
        notes = _notes_tests.notes
        text = notes.render_test_notes(notes.collect_fragments(Path(__file__).resolve().parent.parent, {}))
        self.assertEqual(notes.validate_test_notes(text), text)


if __name__ == '__main__':
    unittest.main()
