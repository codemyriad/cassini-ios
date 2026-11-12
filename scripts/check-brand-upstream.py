#!/usr/bin/env python3
"""Compare vendored brand bytes with their immutable private cassini-ux source."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def check(root, fetch=None):
    folder = Path(root) / 'CassiniShared/Brand'
    pin = json.loads((folder / 'UPSTREAM.json').read_text())
    if (pin.get('repository') != 'https://github.com/codemyriad/cassini-ux'
            or pin.get('path') != 'brand/tokens.json'
            or not re.fullmatch('[0-9a-f]{40}', pin.get('commit', ''))
            or not re.fullmatch('[0-9a-f]{64}', pin.get('sha256', ''))):
        raise ValueError('Invalid immutable brand source pin')
    endpoint = f"repos/codemyriad/cassini-ux/contents/brand/tokens.json?ref={pin['commit']}"
    if fetch is None:
        result = subprocess.run(['gh', 'api', endpoint], capture_output=True, text=True)
        if result.returncode:
            # Never echo authentication diagnostics or credentials from the environment.
            raise ValueError('Cannot read pinned cassini-ux source with the existing read-only CI credentials')
        value = json.loads(result.stdout)
        if value.get('encoding') != 'base64':
            raise ValueError('Unexpected upstream content encoding')
        upstream = base64.b64decode(''.join(value['content'].split()), validate=True)
    else:
        upstream = fetch(endpoint)
    vendored = (folder / 'tokens.json').read_bytes()
    if hashlib.sha256(upstream).hexdigest() != pin['sha256']:
        raise ValueError('Pinned SHA-256 differs from cassini-ux source')
    if upstream != vendored:
        raise ValueError('Vendored brand file is not byte-identical to cassini-ux source')


if __name__ == '__main__':
    try:
        check(Path(__file__).resolve().parent.parent)
    except (ValueError, OSError, KeyError) as error:
        print(f'Brand upstream check failed: {error}', file=sys.stderr)
        sys.exit(1)
    print('Brand bytes match the immutable cassini-ux pin')
