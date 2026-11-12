#!/usr/bin/env python3
"""Main-only internal TestFlight releases on drmeyers; no automatic upload retries."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
from testflight_notes import (FALLBACK_NOTES, collect_fragments, github_release_body,
                                render_test_notes, validate_test_notes)

NOTES_FORMAT = 'user-fragments-v1'

REPOSITORY = 'codemyriad/cassini-ios'
APP = '6828353567'
GROUP = '9f906eb9-750a-47be-957f-097af350dac1'
ORIGIN = 'https://api.appstoreconnect.apple.com'
SLOTS = (9, 14, 20)


def scheduled(now):
    return now.astimezone(ZoneInfo('Europe/Berlin')).hour in SLOTS


def command(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=3600)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} {args[1]} failed (exit {result.returncode}); inspect retained run logs')
    return result.stdout.strip()


def save(path, data):
    temporary = path.with_suffix('.tmp')
    with open(temporary, 'w', opener=lambda p, f: os.open(p, f, 0o600)) as output:
        json.dump(data, output, indent=2)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def gh(endpoint, **parameters):
    args = ['gh', 'api', endpoint, '--method', 'GET']
    for key, value in parameters.items():
        args += ['-f', f'{key}={value}']
    return json.loads(command(args))


def eligible_main_run(run, head):
    return (run.get('head_sha') == head and run.get('head_branch') == 'main'
            and (run.get('head_repository') or {}).get('full_name') == REPOSITORY
            and run.get('event') in ('push', 'workflow_dispatch'))


def green(runs, head):
    # Newest eligible run wins; a PR merge-ref run cannot approve or block main.
    run = next((run for run in runs if eligible_main_run(run, head)), None)
    return bool(run and run.get('status') == 'completed' and run.get('conclusion') == 'success')


def main_ci_green(head):
    page = 1
    while True:
        runs = gh(f'repos/{REPOSITORY}/actions/workflows/ci.yml/runs', branch='main',
                  head_sha=head, per_page=100, page=page)['workflow_runs']
        if any(eligible_main_run(run, head) for run in runs):
            return green(runs, head)
        if len(runs) < 100:
            return False
        page += 1


def testflight_notes(text):
    # Persisted pending releases pass the same store boundary as fresh fragments.
    return validate_test_notes(text)


def next_build(builds, version, reserved):
    numbers = []
    for build in builds:
        if build['marketingVersion'] == version:
            number = build['attributes']['version']
            if not re.fullmatch(r'[0-9]+', number):
                raise RuntimeError('Current version has a non-integer build number; cannot allocate safely')
            numbers.append(int(number))
    return str(max([int(reserved.get(version, 0)), *numbers]) + 1)


class Apple:
    def __init__(self):
        keys = list((Path.home()/'.appstoreconnect/private_keys').glob('AuthKey_*.p8'))
        if len(keys) != 1 or keys[0].stat().st_mode & 0o077:
            raise RuntimeError('Expected one existing private ASC key with mode0600; signing identities are never changed')
        self.key_path = keys[0]
        self.key_id = self.key_path.stem.removeprefix('AuthKey_')
        self.issuer_id = (Path.home()/'.appstoreconnect/issuer-id.txt').read_text().strip()

    def auth(self):
        return ['--apiKey', self.key_id, '--apiIssuer', self.issuer_id]

    def request(self, endpoint, method='GET', data=None):
        if endpoint.startswith(ORIGIN + '/v1/'):
            endpoint = endpoint[len(ORIGIN):]
        if not endpoint.startswith('/v1/') or '\r' in endpoint or '\n' in endpoint:
            raise RuntimeError('Refusing foreign ASC pagination URL')
        if method != 'GET' and not (method in ('POST', 'PATCH') and
                re.fullmatch(r'/v1/betaBuildLocalizations(?:/[A-Za-z0-9-]+)?', endpoint)):
            raise RuntimeError('Only TestFlight build notes may be changed')
        generated = subprocess.run(['xcrun', 'altool', '--generate-jwt', *self.auth(),
            '--p8-file-path', str(self.key_path)], capture_output=True, text=True, timeout=60)
        matches = set(re.findall(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
                                 generated.stdout + generated.stderr))
        if generated.returncode or len(matches) != 1:
            raise RuntimeError('ASC authentication failed; captured JWT output is never printed')
        request = urllib.request.Request(ORIGIN + endpoint, method=method,
            data=json.dumps(data).encode() if data else None,
            headers={'Authorization': 'Bearer ' + matches.pop(), 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f'ASC {method} failed with HTTP {error.code}') from None

    def guard(self):
        if self.request('/v1/apps/' + APP)['data']['attributes']['bundleId'] != 'io.codemyriad.cassini':
            raise RuntimeError('Wrong ASC app')
        attributes = self.request('/v1/betaGroups/' + GROUP)['data']['attributes']
        if not (attributes['name'] == 'cassini' and attributes['isInternalGroup']
                and attributes['hasAccessToAllBuilds'] and not attributes.get('publicLinkEnabled', False)):
            raise RuntimeError('Existing internal cassini group no longer has automatic build access')

    def builds(self):
        endpoint = '/v1/builds?' + urllib.parse.urlencode({'filter[app]': APP,
            'include': 'preReleaseVersion', 'sort': '-uploadedDate', 'limit': 200})
        result = []
        visited = set()
        while endpoint:
            if endpoint in visited:
                raise RuntimeError('Cyclic ASC pagination')
            visited.add(endpoint)
            page = self.request(endpoint)
            versions = {v['id']: v['attributes'] for v in page.get('included', [])
                        if v['type'] == 'preReleaseVersions'}
            for build in page['data']:
                version = versions[build['relationships']['preReleaseVersion']['data']['id']]
                if version['platform'] == 'IOS':
                    result.append(dict(build, marketingVersion=version['version']))
            endpoint = page.get('links', {}).get('next')
        return result

    def finish(self, pending):
        self.guard()
        matches = [b for b in self.builds() if b['marketingVersion'] == pending['version']
                   and b['attributes']['version'] == pending['build']]
        if len(matches) != 1:
            raise RuntimeError('Prior upload is ambiguous; no duplicate submission. Inspect pending.json and Apple delivery')
        build = matches[0]
        attributes = build['attributes']
        if attributes['processingState'] != 'VALID' or attributes['expired']:
            raise RuntimeError('Uploaded build is not VALID and unexpired')
        if attributes.get('buildAudienceType') != 'INTERNAL_ONLY':
            raise RuntimeError('Apple did not confirm INTERNAL_ONLY audience')
        detail = self.request('/v1/builds/' + build['id'] + '/buildBetaDetail')['data']['attributes']
        if detail['internalBuildState'] != 'IN_BETA_TESTING':
            raise RuntimeError('Internal TestFlight testing is not ready')
        notes = self.request('/v1/builds/' + build['id'] + '/betaBuildLocalizations')['data']
        existing = next((n for n in notes if n['attributes']['locale'] == 'en-US'), None)
        data = {'type': 'betaBuildLocalizations',
                'attributes': {'whatsNew': testflight_notes(pending['notes'])}}
        if existing:
            data['id'] = existing['id']
            self.request('/v1/betaBuildLocalizations/' + existing['id'], 'PATCH', {'data': data})
        else:
            data['attributes']['locale'] = 'en-US'
            data['relationships'] = {'build': {'data': {'type': 'builds', 'id': build['id']}}}
            self.request('/v1/betaBuildLocalizations', 'POST', {'data': data})
        return build['id']


def release_notes(source, previous, head):
    if not re.fullmatch(r'[0-9a-f]{40}', previous):
        raise RuntimeError('Seed initial_release_head with the verified previous TestFlight source commit')
    command(['git', 'merge-base', '--is-ancestor', previous, head], cwd=source)
    commits = command(['git', 'rev-list', '--reverse', '--first-parent', previous + '..' + head], cwd=source)
    titles = {}
    direct = []
    for commit in commits.splitlines():
        associated = False
        for pr in gh(f'repos/{REPOSITORY}/commits/{commit}/pulls'):
            if pr.get('merged_at') and pr['base']['ref'] == 'main':
                titles[pr['number']] = pr['title']
                associated = True
        if not associated:
            subject = command(['git', 'show', '-s', '--format=%s', commit], cwd=source)
            direct.append(f'- {subject} ({commit[:12]})')
    text = '\n'.join([*(f'- {title} (#{number})' for number, title in titles.items()), *direct])
    if not text:
        raise RuntimeError('Merged-PR release notes are empty; inspect before upload')
    return text


def delivery_uuid(stdout, stderr):
    # altool versions disagree on JSON shape; return code, not optional metadata, acknowledges upload.
    decoder = json.JSONDecoder()
    for position, char in enumerate(stdout):
        if char != '{':
            continue
        try:
            payload, _ = decoder.raw_decode(stdout[position:])
        except ValueError:
            continue
        details = payload.get('details') if isinstance(payload, dict) else None
        candidate = details.get('delivery-uuid') if isinstance(details, dict) else None
        try:
            return str(uuid.UUID(candidate))
        except (ValueError, TypeError, AttributeError):
            pass
    for candidate in re.findall(r'Delivery UUID:\s*([0-9a-fA-F-]+)', stderr):
        try:
            return str(uuid.UUID(candidate))
        except ValueError:
            pass
    return None  # wait_processing supports the app/version/build route in this same invocation.


def upload(apple, ipa, output):
    args = ['xcrun', 'altool', '--upload-app', '-f', ipa, '-t', 'ios',
            *apple.auth(), '--output-format', 'json']
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=3600)
    except subprocess.TimeoutExpired as error:
        def text(value):
            return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else (value or '')
        (output/'upload.log').write_text('[stdout]\n' + text(error.stdout) + '\n[stderr]\n' + text(error.stderr))
        raise
    (output/'upload.log').write_text('[stdout]\n' + result.stdout + '\n[stderr]\n' + result.stderr)
    if result.returncode:
        raise RuntimeError(f'Apple upload failed (exit {result.returncode}); see {output / "upload.log"}')
    return delivery_uuid(result.stdout, result.stderr)


def refresh_control(config, arguments, lock):
    # Called only after the Berlin slot check AND the shared release mutex.
    source = Path(config['source']).expanduser().resolve()
    if source != Path(__file__).resolve().parent.parent:
        raise RuntimeError('Scheduled updates require the dedicated control clone containing this script')
    if command(['git', 'symbolic-ref', '--short', 'HEAD'], cwd=source) != 'main':
        raise RuntimeError('Scheduled control clone must be on main')
    if command(['git', 'status', '--porcelain'], cwd=source):
        raise RuntimeError('Scheduled control clone is dirty; refusing to change it')
    before = command(['git', 'rev-parse', 'HEAD'], cwd=source)
    command(['git', 'fetch', 'origin', 'main:refs/remotes/origin/main'], cwd=source)
    command(['git', 'merge', '--ff-only', 'origin/main'], cwd=source)
    if command(['git', 'rev-parse', 'HEAD'], cwd=source) != before:
        # Keep the same flock across exec so a manual release cannot enter during deployment.
        os.set_inheritable(lock.fileno(), True)
        os.execv(sys.executable, [sys.executable, str(source/'scripts/daily-testflight.py'),
            '--config', str(arguments.config.absolute()), '--scheduled', '--refresh-control',
            '--release-lock-fd', str(lock.fileno())])


def notify_failure(message, inbox_path):
    print(message, file=sys.stderr)
    try:
        if os.path.samestat(os.fstat(sys.stderr.fileno()), inbox_path.stat()):
            return  # launchd already sent this exact line to the coordinator inbox.
    except (OSError, ValueError, AttributeError):
        pass
    try:
        with inbox_path.open('a') as inbox:
            inbox.write(message + '\n')
    except OSError:
        print('Coordinator inbox unavailable; failure is retained in scheduler/Actions log', file=sys.stderr)


def wait_processing(apple, pending, output):
    args = ['xcrun', 'altool', '--build-status', '--wait', *apple.auth(), '--output-format', 'json']
    if pending.get('delivery'):
        args += ['--delivery-id', pending['delivery']]
    else:
        args += ['--apple-id', APP, '--bundle-version', pending['build'],
                 '--bundle-short-version-string', pending['version'], '--platform', 'ios']
    # Apple's command waits for the processing event; no sleep/poll/re-upload loop.
    with (output/'processing.log').open('a') as log:
        subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=3600)


def external_output(path):
    resolved = path.resolve()
    if not os.path.ismount('/Volumes/DrMeyers2') or not resolved.is_relative_to(Path('/Volumes/DrMeyers2')):
        raise RuntimeError('External volume is unavailable; refusing stale mount-point writes')
    return resolved


def record_release(state, pending, build_id):
    # Advance the ledger only after internal distribution and its notes are confirmed.
    state.setdefault('published_fragments', {}).update(pending.get('fragments', {}))
    state.update(head=pending['head'], version=pending['version'], build=pending['build'], build_id=build_id)
    del state['pending']


def publish(config, state_path, source, apple=None):
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if state.get('pending'):
        pending = state['pending']
        external_output(Path(pending['output']))
        if pending.get('notes_format') != NOTES_FORMAT:
            # Older controllers persisted developer titles. Preserve the audit, never replay them into TestFlight.
            pending['legacy_developer_notes'] = pending.get('notes', '')
            pending.update(notes=FALLBACK_NOTES, notes_format=NOTES_FORMAT, fragments={})
            save(state_path, state)
        apple = apple or Apple()
        wait_processing(apple, pending, Path(pending['output']))
        build_id = apple.finish(pending)  # Resume finalization only; never resubmit an ambiguous upload.
        record_release(state, pending, build_id)
        save(state_path, state)
        print(f"[iOS] resumed TestFlight {state['version']} ({state['build']}) from {state['head']}")
    command(['git', 'fetch', 'origin', 'main:refs/remotes/origin/main'], cwd=source)
    head = command(['git', 'rev-parse', 'origin/main'], cwd=source)
    if gh(f'repos/{REPOSITORY}/git/ref/heads/main')['object']['sha'] != head:
        print('[iOS] daily test release skipped: fetched origin differs from canonical GitHub main')
        return
    previous = state.get('head', config['initial_release_head'])
    if head == previous:
        print('[iOS] daily test release skipped: main unchanged')
        return
    if not main_ci_green(head):
        print('[iOS] daily test release skipped: current main latest CI is not green')
        return
    apple = apple or Apple()
    apple.guard()
    root = external_output(Path(config['output_root']))
    output = root/uuid.uuid4().hex
    output.mkdir(parents=True)
    checkout = output/'source'
    command(['git', 'worktree', 'add', '--detach', str(checkout), head], cwd=source)
    versions = set(re.findall(r"MARKETING_VERSION:\s*'([0-9]+\.[0-9]+\.[0-9]+)'", (checkout/'project.yml').read_text()))
    if len(versions) != 1:
        raise RuntimeError('App and extension must have one marketing version')
    version = versions.pop()
    raw_notes = release_notes(source, previous, head)
    fragments = collect_fragments(checkout, state.get('published_fragments', {}))
    fragment_hashes = {item['id']: item['sha256'] for item in fragments}
    notes = render_test_notes(fragments)
    build = next_build(apple.builds(), version, state.get('reserved', {}))
    state.setdefault('reserved', {})[version] = int(build)
    save(state_path, state)  # Retain reservations after failures; never reuse a possibly uploaded number.
    context = dict(config, source=str(checkout), output=str(output), head=head, version=version, build=build,
                   key_path=str(apple.key_path), key_id=apple.key_id, issuer_id=apple.issuer_id)
    save(output/'context.json', context)
    (output/'release-notes.txt').write_text(raw_notes + '\n', encoding='utf-8', errors='backslashreplace')
    (output/'release-notes-testflight.txt').write_text(notes + '\n')
    (output/'release-notes-github.md').write_text(github_release_body(notes, raw_notes))
    save(output/'release-plan.json', dict(head=head, version=version, build=build,
        raw_notes=raw_notes, testflight_notes=notes, fragments=fragment_hashes, notes_format=NOTES_FORMAT))
    (output/'tmp').mkdir()
    gui_env = dict(os.environ, TMPDIR=str(output/'tmp') + '/', GUIRUN_TIMEOUT='14400')
    with (output/'archive-export.log').open('w') as log:
        subprocess.run([sys.executable, str(checkout/'scripts/run-in-gui.py'),
            'lockf', '-k', '-t', '3600', str(Path.home()/'.cassini-heavy.lock'),
            'env', 'CASSINI_HEAVY_LOCK_HELD=1', sys.executable,
            str(checkout/'scripts/testflight-archive.py'), str(output/'context.json')],
            stdout=log, stderr=subprocess.STDOUT, check=True, timeout=18000, env=gui_env)
    artifact = json.loads((output/'artifact.json').read_text())
    if any(artifact[k] != v for k, v in [('head', head), ('version', version), ('build', build)]):
        raise RuntimeError('Archive result does not match the frozen release plan')
    ipa = Path(artifact['ipa']).resolve()
    if not ipa.is_relative_to(output) or ipa.stat().st_size != artifact['bytes']:
        raise RuntimeError('IPA is outside the owned output or changed size')
    digest = hashlib.sha256()
    with ipa.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != artifact['sha256']:
        raise RuntimeError('IPA changed after signature verification')
    apple.guard()
    if int(next_build(apple.builds(), version, {})) > int(build):
        raise RuntimeError('Another upload consumed the next number during archive; no upload attempted')
    with (output/'validation.log').open('w') as log:
        subprocess.run(['xcrun', 'altool', '--validate-app', '-f', artifact['ipa'], '-t', 'ios', *apple.auth()],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=3600)
    command(['git', 'fetch', 'origin', 'main:refs/remotes/origin/main'], cwd=source)
    current = command(['git', 'rev-parse', 'origin/main'], cwd=source)
    canonical = gh(f'repos/{REPOSITORY}/git/ref/heads/main')['object']['sha']
    if current != head or canonical != head or not main_ci_green(current):
        print('[iOS] daily test release skipped: main changed or latest CI is no longer green after validation')
        return
    pending = dict(head=head, version=version, build=build, notes=notes, output=str(output),
                   fragments=fragment_hashes, notes_format=NOTES_FORMAT)
    state['pending'] = pending
    save(state_path, state)  # Durable upload intent BEFORE calling Apple; ambiguity never causes a duplicate.
    pending['delivery'] = upload(apple, artifact['ipa'], output)
    save(state_path, state)
    wait_processing(apple, pending, output)
    build_id = apple.finish(pending)
    record_release(state, pending, build_id)
    save(state_path, state)
    print(f'[iOS] TestFlight {version} ({build}) released from {head}; internal cassini group')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--refresh-control', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--release-lock-fd', type=int, help=argparse.SUPPRESS)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--scheduled', action='store_true')
    modes.add_argument('--manual', action='store_true')
    args = parser.parse_args()
    config = None
    try:
        if platform.system() != 'Darwin' or platform.node().split('.')[0].lower() != 'drmeyers':
            raise RuntimeError('Signing is permitted only on drmeyers, never a rented/pool runner')
        if args.scheduled and not scheduled(dt.datetime.now(dt.timezone.utc)):
            print('[iOS] daily test release skipped: outside 09/14/20 Europe/Berlin slots')
            return 0
        if args.config.stat().st_mode & 0o077:
            raise RuntimeError('Release config must be private (mode0600)')
        config = json.loads(args.config.read_text())
        state_dir = Path(config['state_dir']).expanduser()
        state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_path = state_dir/'release.lock'
        if args.release_lock_fd is not None:
            if not args.scheduled or not args.refresh_control or not os.path.samestat(
                    os.fstat(args.release_lock_fd), lock_path.stat()):
                raise RuntimeError('Invalid inherited release mutex')
            lock_stream = os.fdopen(args.release_lock_fd, 'a')
            os.set_inheritable(lock_stream.fileno(), False)
        else:
            lock_stream = lock_path.open('a')
        with lock_stream as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('[iOS] daily test release skipped: another release is active')
                return 0
            if args.refresh_control:
                if not args.scheduled:
                    raise RuntimeError('Only scheduled jobs refresh the control clone')
                refresh_control(config, args, lock)
            publish(config, state_dir/'state.json', Path(config['source']).expanduser())
        return 0
    except Exception as error:
        # No exception output from Apple token generation is included; the token stays in memory.
        message = '[iOS] daily test release failed: ' + str(error).replace('\n', ' ')
        inbox_path = Path((config or {}).get('notification_file',
            str(Path.home()/'dev/cassini-coordination/DAILY-TEST-RELEASES-IOS.log'))).expanduser()
        notify_failure(message, inbox_path)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
