#!/usr/bin/env python3
"""Checks that nothing in a built app needs a newer iOS than the app itself.

    scripts/check-embedded-minos.py <path to Cassini.app>

The app's minimum is its Info.plist MinimumOSVersion (the deployment target). Every Mach-O in the bundle (the app,
PlugIns/*.appex, Frameworks/*, test bundles) must have a minimum OS (LC_BUILD_VERSION or LC_VERSION_MIN_IPHONEOS) at
or below it, and so must every embedded bundle's Info.plist MinimumOSVersion: a binary above it fails to load on the
older systems the app installs on, and App Store Connect rejects a bundle whose plist minimum differs (90208).
Reads the load commands itself, so it needs no Xcode tools and takes well under a second.
"""
import plistlib
import struct
import sys
from pathlib import Path

# Bundles allowed a higher minimum than the app's, each with the highest minimum allowed, until the work named
# beside it lands; an exception that is no longer needed fails the check, so it is deleted with that work.
EXCEPTIONS = {
    # The pinned private Whistle runtime stays linked for iOS 26 (scripts/bundle-whistle.py) and is offered only
    # from iOS 26 (WhistleCapability's OS floor), loaded lazily, never at launch. Until: Whistle linked for iOS 18.
    'Frameworks/CassiniWhistleRuntime.framework': (26, 0, 0),
}

LC_REQ_DYLD = 0x80000000
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
THIN = {b'\xcf\xfa\xed\xfe': ('<', 32), b'\xce\xfa\xed\xfe': ('<', 28),
        b'\xfe\xed\xfa\xcf': ('>', 32), b'\xfe\xed\xfa\xce': ('>', 28)}
FAT = {b'\xca\xfe\xba\xbe': 20, b'\xca\xfe\xba\xbf': 32}


def version(text):
    parts = [int(part) for part in text.split('.')]
    return tuple((parts + [0, 0, 0])[:3])


def shown(value):
    major, minor, patch = value
    return f'{major}.{minor}' + (f'.{patch}' if patch else '')


def thin_minimum(data, offset):
    """The minimum OS of the thin Mach-O at `offset`, or None when it states none."""
    order, header = THIN[data[offset:offset + 4]]
    ncmds = struct.unpack_from(order + 'I', data, offset + 16)[0]
    cursor = offset + header
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(order + 'II', data, cursor)
        cmd &= ~LC_REQ_DYLD
        if cmd == LC_BUILD_VERSION:
            encoded = struct.unpack_from(order + 'I', data, cursor + 12)[0]
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            encoded = struct.unpack_from(order + 'I', data, cursor + 8)[0]
        else:
            cursor += size
            continue
        return (encoded >> 16, (encoded >> 8) & 0xff, encoded & 0xff)
    return None


def minimums(path):
    """The minimum OS of each slice of `path`, or None when it is no Mach-O."""
    with path.open('rb') as file:
        magic = file.read(4)
        if magic not in THIN and magic not in FAT:
            return None
        data = magic + file.read()
    if magic in THIN:
        return [thin_minimum(data, 0)]
    count = struct.unpack_from('>I', data, 4)[0]
    if count > 64:  # A Java class file shares the fat magic; no real fat file has this many slices.
        return None
    entry = FAT[magic]
    slices = []
    for index in range(count):
        base = 8 + index * entry
        offset = struct.unpack_from('>Q' if entry == 32 else '>I', data, base + 8)[0]
        slices.append(thin_minimum(data, offset))
    return slices


def check(app):
    """The problems found in `app`, one line each."""
    target = version(plistlib.loads((app / 'Info.plist').read_bytes())['MinimumOSVersion'])
    problems = []
    needed = set()

    def allowed(relative):
        for bundle, ceiling in EXCEPTIONS.items():
            if relative == bundle or relative.startswith(bundle + '/'):
                return bundle, ceiling
        return None, target

    def judge(relative, minimum):
        bundle, ceiling = allowed(relative)
        if minimum > ceiling:
            problems.append(f'{relative}: minimum iOS {shown(minimum)} is above '
                            + (f'its exception, {shown(ceiling)}' if bundle else f"the app's {shown(target)}"))
        elif bundle and minimum > target:
            needed.add(bundle)

    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(app).as_posix()
        if path.name == 'Info.plist' and path.parent != app:
            stated = plistlib.loads(path.read_bytes()).get('MinimumOSVersion')
            if stated is not None:
                judge(relative, version(stated))
            continue
        try:
            slices = minimums(path)
        except (KeyError, struct.error):
            problems.append(f'{relative}: unreadable Mach-O')
            continue
        for minimum in slices or []:
            if minimum is None:
                problems.append(f'{relative}: a Mach-O without a minimum OS')
            else:
                judge(relative, minimum)
    for bundle in EXCEPTIONS:
        if bundle not in needed:
            problems.append(f'{bundle}: no longer needs its exception in scripts/check-embedded-minos.py; delete it')
    return target, problems


def main(arguments):
    if len(arguments) != 1:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    app = Path(arguments[0])
    target, problems = check(app)
    for problem in problems:
        print(f'error: {problem}', file=sys.stderr)
    if problems:
        return 1
    print(f'{app.name}: every embedded binary needs iOS {shown(target)} or older'
          + ''.join(f' (exception: {bundle} up to {shown(ceiling)})' for bundle, ceiling in EXCEPTIONS.items()))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
