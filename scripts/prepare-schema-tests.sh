#!/bin/bash
# Prepare the independent schema validator once in the caller's build cache; never alter system Python.
# Prints only the venv interpreter on stdout; installation/diagnostics go to stderr.
# Usage: export CASSINI_SCHEMA_PYTHON="$(scripts/prepare-schema-tests.sh "$CASSINI_TEST_CACHE")"
# Standalone Swift tests require that export and CASSINI_CONFORMANCE; unit tests never fetch dependencies.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cache="${1:-${CASSINI_TEST_CACHE:-}}"
if [ -z "$cache" ]; then
    echo 'Schema tests: supply a build-cache directory as argument or CASSINI_TEST_CACHE.' >&2
    exit 1
fi
exec "${CASSINI_SCHEMA_BOOTSTRAP_PYTHON:-/usr/bin/python3}" - "$here/schema-test-requirements.txt" "$cache" <<'PY'
import fcntl
import hashlib
import os
import platform as host_platform
from pathlib import Path
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import venv

requirements = Path(sys.argv[1]).resolve()
cache = Path(sys.argv[2]).expanduser().resolve()
cache.mkdir(parents=True, exist_ok=True)
if sys.version_info < (3, 9):
    sys.exit('Schema tests need Python 3.9 or newer; set CASSINI_SCHEMA_BOOTSTRAP_PYTHON to that interpreter.')
versions = dict(line.strip().split('==', 1) for line in requirements.read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#'))
key = hashlib.sha256(requirements.read_bytes()).hexdigest()[:16]
platform = sysconfig.get_platform().replace('/', '_')
name = 'schema-tests-' + sys.implementation.cache_tag + '-' + platform + '-' + host_platform.machine() + '-' + key
folder = cache / name
verification = """
from importlib.metadata import version
from jsonschema import Draft202012Validator, FormatChecker
import json, sys
for package, expected in json.loads(sys.argv[1]).items():
    assert version(package) == expected, package + ': expected ' + expected
checker = FormatChecker()
assert 'date-time' in checker.checkers, 'date-time checker is not registered'
assert checker.conforms('2026-11-09T09:31:48Z', 'date-time')
assert not checker.conforms('2026-02-30T09:31:48Z', 'date-time'), 'date-time validation is inactive'
"""
import json

def verify(python):
    subprocess.run([str(python), '-I', '-B', '-c', verification, json.dumps(versions)],
                   check=True, stdout=sys.stderr, stderr=sys.stderr)
    subprocess.run([str(python), '-I', '-B', '-m', 'pip', 'check'],
                   check=True, stdout=sys.stderr, stderr=sys.stderr)

# Event-based OS lock: simultaneous branches sharing a cache never install over an interpreter in use.
with (cache / (name + '.lock')).open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if folder.exists():
        try:
            verify(folder / 'bin/python')
        except (OSError, subprocess.CalledProcessError):
            sys.exit('Cached schema validator is incomplete: ' + str(folder)
                     + '. Choose a new CASSINI_TEST_CACHE or repair this task-owned cache before retrying.')
    else:
        temporary = Path(tempfile.mkdtemp(prefix=name + '.tmp-', dir=cache))
        try:
            os.environ['TMPDIR'] = str(temporary)
            venv.EnvBuilder(with_pip=True).create(temporary)
            python = temporary / 'bin/python'
            print('Preparing pinned schema-test validator in ' + str(folder), file=sys.stderr)
            environment = os.environ.copy()
            environment['TMPDIR'] = str(temporary)
            subprocess.run([str(python), '-I', '-B', '-m', 'pip', 'install', '--disable-pip-version-check',
                            '--only-binary=:all:', '--no-deps', '--cache-dir', str(cache / 'schema-pip'),
                            '--requirement', str(requirements)], check=True, env=environment,
                           stdout=sys.stderr, stderr=sys.stderr)
            verify(python)
            # Invoke bin/python directly after the atomic rename; generated console-script shebangs are unused.
            temporary.rename(folder)
        except BaseException:
            shutil.rmtree(temporary, ignore_errors=True)  # Only this invocation's newly created staging directory.
            raise
        verify(folder / 'bin/python')
print(str(folder / 'bin/python'))
PY
