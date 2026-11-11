#!/usr/bin/env python3
"""Archive/export one frozen main head; invoked in the GUI session under the host heavy lock.

Usage: testflight-archive.py CONTEXT.json. Never uploads or changes signing identities.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shutil
import signal
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def admission(output):
    def swap():
        text = subprocess.check_output(['vm_stat'], text=True)
        return int(re.search(r'^Swapouts:\s+(\d+)', text, re.M).group(1))
    before = swap()
    pressure = subprocess.check_output(['memory_pressure'], text=True)
    free = int(re.search(r'System-wide memory free percentage: (\d+)%', pressure).group(1))
    require(swap() == before and free >= 25, 'Resource admission deferred: swap is growing or memory is low')
    require(shutil.disk_usage('/').free >= 15 * 2**30, 'Internal disk is below the 15 GiB floor')
    require(shutil.disk_usage(output).free >= 5 * 2**30, 'External disk has less than 5 GiB available')
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    keychain, flags = ctypes.c_void_p(), ctypes.c_uint32()
    status = security.SecKeychainOpen(str(Path.home() / 'Library/Keychains/login.keychain-db').encode(),
                                      ctypes.byref(keychain))
    require(status == 0, 'Cannot open the existing login keychain')
    require(security.SecKeychainGetStatus(keychain, ctypes.byref(flags)) == 0, 'Cannot inspect login keychain status')
    require(flags.value & 1, 'login keychain is locked. Silvio must open Keychain Access, select login, '
                            'and unlock it with his Mac login password.')


def main(arguments):
    require(len(arguments) == 1, 'Usage: testflight-archive.py CONTEXT.json')
    require(platform.system() == 'Darwin' and platform.node().split('.')[0].lower() == 'drmeyers',
            'Signing is permitted only on drmeyers')
    context = json.loads(Path(arguments[0]).read_text())
    require(os.environ.get('GUIRUN_INSIDE') == '1', 'Signing requires scripts/run-in-gui.py')
    require(os.environ.get('CASSINI_HEAVY_LOCK_HELD') == '1', 'Controller must acquire the host heavy lock first')
    source, output = Path(context['source']).resolve(), Path(context['output']).resolve()
    mount = Path('/Volumes/DrMeyers2')
    require(os.path.ismount(mount) and output.is_relative_to(mount) and output.is_dir(),
            'Output must already exist on the mounted DrMeyers2 volume')
    require(re.fullmatch(r'[0-9a-f]{40}', context['head']), 'Invalid source head')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', context['version']), 'Invalid marketing version')
    require(re.fullmatch(r'[1-9][0-9]*', context['build']), 'Invalid test build number')
    for kind in ('development', 'distribution'):
        require(re.fullmatch(r'[0-9a-f]{64}', context[kind + '_certificate_sha256']), 'Missing signing baseline')
    key = Path(context['key_path'])
    require(key.is_file() and not key.stat().st_mode & 0o077, 'Existing ASC key is missing or not private')
    require(os.environ.get('CASSINI_SHERPA_LOCAL', '0') in ('', '0'), 'Local native-runtime overrides cannot be released')

    def frozen_source():
        for ref in ('HEAD', 'origin/main'):
            value = subprocess.check_output(['git', 'rev-parse', ref], cwd=source, text=True).strip()
            require(value == context['head'], 'Release source no longer equals the frozen main head')
        require(not subprocess.check_output(['git', 'status', '--porcelain'], cwd=source), 'Release source is dirty')

    frozen_source()
    admission(output)
    env = os.environ.copy()
    for name in ('tmp', 'cache', 'module-cache'):
        (output / name).mkdir(exist_ok=True)
    env.update(TMPDIR=str(output / 'tmp') + '/', CASSINI_WHISTLE_CACHE=str(output / 'cache/whistle'),
               CASSINI_WHISTLE_LAB_FIXTURES='0', CLANG_MODULE_CACHE_PATH=str(output / 'module-cache'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / 'module-cache'))
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode-27.0.0.app/Contents/Developer')

    def run(name, command, capture=False, timeout=1800):
        with (output / (name + '.log')).open('wb') as log:
            process = subprocess.Popen(command, cwd=source, env=env, stdout=subprocess.PIPE if capture else log,
                                       stderr=log, start_new_session=True)
            try:
                data, _ = process.communicate(timeout=timeout)
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                except ProcessLookupError:
                    pass
                raise
            if capture:
                log.write(data)
            require(process.returncode == 0, name + ' failed; see ' + str(output / (name + '.log')))
            return data

    def interrupted(_signum, _frame):
        raise InterruptedError('Archive worker interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    pins = json.loads((source / 'Whistle/pins.json').read_text())
    sys.path.insert(0, str(source / 'scripts'))
    from whistle_binary_identity import identity
    auth = ['-allowProvisioningUpdates', '-authenticationKeyPath', str(key), '-authenticationKeyID',
            context['key_id'], '-authenticationKeyIssuerID', context['issuer_id']]
    archive = output / 'Cassini.xcarchive'
    run('xcodegen', ['xcodegen', 'generate'])
    run('archive', ['xcodebuild', 'archive', '-jobs', '2', '-project', 'Cassini.xcodeproj', '-scheme',
        'CassiniInternal', '-configuration', 'Internal', '-destination', 'generic/platform=iOS', '-archivePath',
        str(archive), '-derivedDataPath', str(output / 'DerivedData.noindex'), '-clonedSourcePackagesDirPath',
        str(output / 'SourcePackages'), '-packageCachePath', str(output / 'PackageCache')] + auth +
        ['CURRENT_PROJECT_VERSION=' + context['build'], 'MARKETING_VERSION=' + context['version'],
         'CASSINI_WHISTLE_LAB_FIXTURES=0', 'COMPILER_INDEX_STORE_ENABLE=NO'])

    def verify(app, distribution):
        label = 'distribution' if distribution else 'archive'
        bundles = [app, app / 'PlugIns/CassiniActivity.appex']
        for bundle, identifier in zip(bundles, ['io.codemyriad.cassini', 'io.codemyriad.cassini.activity']):
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            require(info['CFBundleIdentifier'] == identifier and info['CFBundleVersion'] == context['build']
                    and info['CFBundleShortVersionString'] == context['version']
                    and info['MinimumOSVersion'] == pins['deploymentTarget'], label + ': wrong bundle identity/version')
            entitlements = plistlib.loads(run(label + '-' + bundle.name + '-entitlements',
                ['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)], capture=True, timeout=60))
            require(entitlements.get('com.apple.developer.team-identifier') == '4LS8W738Y3', 'Signing team changed')
            require(not distribution or entitlements.get('get-task-allow', False) is False, 'Distribution debug entitlement')
            if bundle == app:
                require(entitlements.get('com.apple.developer.kernel.increased-memory-limit') is True,
                        'Missing increased-memory entitlement')
        run(label + '-signature', ['codesign', '--verify', '--deep', '--strict', str(app)], timeout=60)
        for bundle in bundles + sorted((app / 'Frameworks').glob('*.framework')):
            prefix = output / (label + '-' + bundle.name + '-certificate-')
            run(label + '-' + bundle.name + '-certificate',
                ['codesign', '-d', '--extract-certificates=' + str(prefix), str(bundle)], timeout=60)
            require(sha256(Path(str(prefix) + '0')) == context[
                ('distribution' if distribution else 'development') + '_certificate_sha256'], 'Signing identity changed')
        require(not (app / 'WhistleTests').exists(), 'Lab fixtures must not ship')
        for name in ('SherpaOnnxC.framework', 'onnxruntime.framework'):
            require(not (app / 'Frameworks' / name).exists(), 'Static framework stub must not ship')
        manifest = json.loads((app / 'Whistle/manifest.json').read_text())
        require(manifest['identitySchema'] == 'cassini-whistle-sections-v1' and manifest['target'] == 'ios-arm64'
                and manifest['engineRevision'] == pins['engineRevision']
                and manifest['minimumOS'] == pins['deploymentTarget'], 'Whistle metadata disagrees with pins')
        runtime = app / 'Frameworks/CassiniWhistleRuntime.framework/CassiniWhistleRuntime'
        require(identity(runtime.read_bytes()) == manifest['runtimeIdentity'], 'Whistle runtime identity mismatch')
        for name in ('whistle.cact', 'silero-vad-6.2.1.onnx'):
            file, pin = app / 'Whistle' / name, pins['artifacts'][name]
            require(file.stat().st_size == pin['bytes'] and sha256(file) == pin['sha256'], 'Whistle artifact mismatch')
        require(manifest['modelSha256'] == pins['artifacts']['whistle.cact']['sha256'], 'Whistle model metadata mismatch')
        run(label + '-minimum-os', [sys.executable, str(source / 'scripts/check-embedded-minos.py'), str(app)], timeout=60)

    verify(archive / 'Products/Applications/Cassini.app', False)
    options = output / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps(dict(method='app-store-connect', destination='export', teamID='4LS8W738Y3',
        signingStyle='automatic', manageAppVersionAndBuildNumber=False, testFlightInternalTestingOnly=True)))
    admission(output)
    run('export', ['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(output / 'export'),
                  '-exportOptionsPlist', str(options)] + auth)
    ipa = output / 'export/Cassini.ipa'
    run('inspect-export', ['ditto', '-x', '-k', str(ipa), str(output / 'export-inspection')], timeout=120)
    verify(output / 'export-inspection/Payload/Cassini.app', True)
    frozen_source()
    artifact = {key: context[key] for key in ('head', 'version', 'build')}
    artifact.update(ipa=str(ipa), sha256=sha256(ipa), bytes=ipa.stat().st_size)
    temporary = output / 'artifact.json.tmp'
    temporary.write_text(json.dumps(artifact, indent=2) + '\n')
    temporary.replace(output / 'artifact.json')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except Exception as error:
        print('Archive/export failed: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
