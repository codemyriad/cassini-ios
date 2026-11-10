#!/usr/bin/env python3
"""Checks that an iOS simulator runtime exports every symbol the built Whistle simulator framework imports.

    scripts/check-whistle-runtime-exports.py <RuntimeRoot> <CassiniWhistleRuntime of a Debug-iphonesimulator build>

RuntimeRoot is a simulator runtime's root, such as
/Library/Developer/CoreSimulator/Volumes/iOS_22C150/Library/Developer/CoreSimulator/Profiles/Runtimes/
iOS 18.2.simruntime/Contents/Resources/RuntimeRoot (`xcrun simctl list runtimes -j` gives each one's runtimeRoot).
Every import of the framework (`dyld_info -imports`, each with the library it binds to) must be exported by that
library in the runtime, or by a library it re-exports (libSystem re-exports usr/lib/system/*, libc++ re-exports
libc++abi). The few imports dyld binds by flat lookup (`<weak-def-coalesce>`: operator new and delete) must be
exported by one of the linked libraries.

A runtime that ships loose dylibs takes libsystem_kernel, libsystem_platform and libsystem_pthread from the host Mac:
its libsystem_sim_*_host shims re-export the host's copies, which are not in RuntimeRoot. Those are read from the host
(`dyld_info -exports`), and every import they provide is listed under "resolvedByHost": on that runtime the simulator
binds them to the Mac's libraries, so they are no evidence about the iOS version's own libraries. "resolvedByRuntime"
counts the imports the runtime itself exports, and "proves" says "partial" whenever any resolve to the host, even when
"result" is "pass". The runtime's libraries are read from its loose dylibs where it ships them (iOS 26.0 and older runtimes),
else from its dyld_sim_shared_cache (iOS 27). Prints one JSON object; exits 0 when every import resolves, 1 when one
does not, 2 on bad input.

What a pass shows: that runtime's simulator libSystem/libc++ family has every symbol the simulator slice binds, so
dyld would not refuse the framework for a missing symbol there. It says nothing about the device slice, the device's
own libraries or the CPU, and nothing about behaviour; those need the parity fixtures and a device.
"""
import hashlib
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path

LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_REEXPORT_DYLIB = 0x1f | LC_REQ_DYLD
LC_DYLD_INFO = 0x22
LC_DYLD_EXPORTS_TRIE = 0x33 | LC_REQ_DYLD
LC_BUILD_VERSION = 0x32
COALESCED = '<weak-def-coalesce>'
CPU_TYPE_ARM64 = 0x0100000c
PLATFORMS = {2: 'IOS', 7: 'IOSSIMULATOR'}
EXPORT_SYMBOL_FLAGS_REEXPORT = 0x08
EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER = 0x10


class Refused(Exception):
    """Input this tool cannot judge (exit 2), as opposed to a symbol that does not resolve (exit 1)."""


def uleb(data, at):
    value = shift = 0
    while True:
        if at >= len(data):
            raise Refused('truncated export trie')
        byte = data[at]; at += 1
        value |= (byte & 0x7f) << shift; shift += 7
        if byte < 0x80:
            return value, at


def trie_names(data):
    """The symbol names of a Mach-O export trie (dyld's format, any entry kind, re-exports included)."""
    names, stack, seen = set(), [(0, b'')], set()
    while stack:
        node, prefix = stack.pop()
        if node in seen or node >= len(data):
            raise Refused('malformed export trie')
        seen.add(node)
        terminal, at = uleb(data, node)
        if terminal:
            names.add(prefix.decode())
        at += terminal
        if at >= len(data):
            raise Refused('malformed export trie')
        children = data[at]; at += 1
        for _ in range(children):
            end = data.index(b'\0', at)
            edge = data[at:end]
            child, at = uleb(data, end + 1)
            stack.append((child, prefix + edge))
    return names


class Image:
    """One arm64 Mach-O's load commands, read from `read(offset, size)` relative to its header."""

    def __init__(self, read):
        magic, cputype, _, _, ncmds, sizeofcmds = struct.unpack('<IiIIII', read(0, 24))
        if magic != 0xfeedfacf or cputype != CPU_TYPE_ARM64:
            raise Refused('not a 64-bit arm64 Mach-O')
        data = read(32, sizeofcmds)
        self.commands, at = [], 0
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', data, at)
            if size < 8 or at + size > len(data):
                raise Refused('malformed load commands')
            self.commands.append((cmd, data[at:at + size]))
            at += size

    def reexports(self):
        paths = []
        for cmd, body in self.commands:
            if cmd == LC_REEXPORT_DYLIB:
                offset = struct.unpack_from('<I', body, 8)[0]
                paths.append(body[offset:].split(b'\0', 1)[0].decode())
        return paths

    def trie(self):
        """(offset, size) of the export trie as the load commands state it, or None."""
        for cmd, body in self.commands:
            if cmd == LC_DYLD_EXPORTS_TRIE:
                return struct.unpack_from('<II', body, 8)
            if (cmd & ~LC_REQ_DYLD) == LC_DYLD_INFO:
                return struct.unpack_from('<II', body, 40)
        return None

    def linkedit(self):
        for cmd, body in self.commands:
            if cmd == LC_SEGMENT_64 and body[8:24].split(b'\0', 1)[0] == b'__LINKEDIT':
                vmaddr, _, fileoff, _ = struct.unpack_from('<QQQQ', body, 24)
                return vmaddr, fileoff
        raise Refused('no __LINKEDIT segment')

    def platform(self):
        for cmd, body in self.commands:
            if cmd == LC_BUILD_VERSION:
                return PLATFORMS.get(struct.unpack_from('<I', body, 8)[0], 'other')
        return None


def arm64_slice(data):
    """The offset of the arm64 slice of a thin or fat file."""
    magic = data[:4]
    if magic == b'\xcf\xfa\xed\xfe':
        return 0
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = magic == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        entry = 32 if wide else 20
        slices = []
        for index in range(count):
            cputype, subtype = struct.unpack_from('>iI', data, 8 + index * entry)
            offset = struct.unpack_from('>Q' if wide else '>I', data, 8 + index * entry + 8)[0]
            if cputype == CPU_TYPE_ARM64:
                slices.append((subtype & 0xff, offset))
        if slices:
            return min(slices)[1]  # CPU_SUBTYPE_ARM64_ALL (0) before arm64e.
    raise Refused('no arm64 slice')


class LooseRuntime:
    """A runtime that ships its libraries as files under RuntimeRoot."""
    layout = 'dylibs'

    def __init__(self, root, host_exports=None):
        self.root = root
        self.host_exports = host_exports or read_host_exports

    def resolve(self, path):
        """`path` inside the runtime root, following symlinks without leaving it."""
        current = self.root / path.lstrip('/')
        for _ in range(16):
            if not current.is_symlink():
                return current
            target = os.readlink(current)
            current = self.root / target.lstrip('/') if target.startswith('/') else current.parent / target
        raise Refused(f'symlink loop at {path}')

    def exports(self, path):
        file = self.resolve(path)
        if not file.is_file():
            return None
        data = file.read_bytes()
        base = arm64_slice(data)
        image = Image(lambda offset, size: data[base + offset:base + offset + size])
        trie = image.trie()
        names = trie_names(data[base + trie[0]:base + trie[0] + trie[1]]) if trie and trie[1] else set()
        return names, image.reexports()


def read_host_exports(path):
    """The exports of the host Mac's own copy of `path` (from its dyld shared cache), or None."""
    try:
        text = subprocess.check_output(['xcrun', 'dyld_info', '-arch', 'arm64', '-exports', path], text=True,
                                       stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return None
    names = {match.group(1) for match in re.finditer(r'^\s*0x[0-9A-Fa-f]+\s+(\S+)', text, re.M)}
    return (names, []) if names else None


class SharedCacheRuntime:
    """A runtime whose libraries are only in its dyld_sim_shared_cache (and its .01, .02 … subcaches)."""
    layout = 'dyld_sim_shared_cache'

    def __init__(self, cache):
        self.cache = cache
        files = [cache] + sorted(path for path in cache.parent.glob(cache.name + '.*')
                                 if re.fullmatch(r'\.\d+', path.suffix))
        self.mappings, self.images = [], {}
        for file in files:
            with file.open('rb') as handle:
                header = handle.read(0x200)
            if not header.startswith(b'dyld_v1'):
                raise Refused(f'not a dyld shared cache: {file.name}')
            mapping_offset, mapping_count = struct.unpack_from('<II', header, 16)
            with file.open('rb') as handle:
                handle.seek(mapping_offset)
                table = handle.read(mapping_count * 32)
            for index in range(mapping_count):
                address, size, offset = struct.unpack_from('<QQQ', table, index * 32)
                self.mappings.append((address, size, file, offset))
            if file == cache:
                images_offset, images_count = struct.unpack_from('<II', header, 448) if mapping_offset >= 456 else (0, 0)
                if not images_count:
                    images_offset, images_count = struct.unpack_from('<II', header, 24)
                with file.open('rb') as handle:
                    handle.seek(images_offset)
                    infos = handle.read(images_count * 32)
                    for index in range(images_count):
                        address, _, _, path_offset = struct.unpack_from('<QQQI', infos, index * 32)
                        handle.seek(path_offset)
                        self.images[handle.read(1024).split(b'\0', 1)[0].decode()] = address

    def read(self, address, size):
        for start, length, file, offset in self.mappings:
            if start <= address and address + size <= start + length:
                with file.open('rb') as handle:
                    handle.seek(offset + address - start)
                    return handle.read(size)
        raise Refused(f'address 0x{address:x} is in no mapping of the cache')

    def exports(self, path):
        address = self.images.get(path)
        if address is None:
            return None
        image = Image(lambda offset, size: self.read(address + offset, size))
        trie = image.trie()
        if not trie or not trie[1]:
            return set(), image.reexports()
        vmaddr, fileoff = image.linkedit()
        return trie_names(self.read(vmaddr + trie[0] - fileoff, trie[1])), image.reexports()


def open_runtime(root, host_exports=None):
    root = Path(root)
    if (root / 'usr/lib/libSystem.B.dylib').exists():
        return LooseRuntime(root, host_exports)
    cache = root / 'System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64'
    if cache.is_file():
        return SharedCacheRuntime(cache)
    raise Refused(f'{root} has neither usr/lib/libSystem.B.dylib nor an arm64 dyld_sim_shared_cache')


HOST = 'host:'


def closure(runtime, path):
    """{symbol: image} for every symbol `path` exports in the runtime through its re-exports, nearest image first. An
    image only the host provides (re-exported by a libsystem_sim_*_host shim of a loose runtime) is named host:<path>."""
    provider, images, queue = {}, [], [(path, None)]
    while queue:
        current, parent = queue.pop(0)
        if current in images or HOST + current in images:
            continue
        found, name = runtime.exports(current), current
        if found is None and parent and Path(parent).name.startswith('libsystem_sim_') \
                and parent.endswith('_host.dylib') and isinstance(runtime, LooseRuntime):
            found, name = runtime.host_exports(current), HOST + current
        if found is None:
            if current == path:
                raise Refused(f'{path} is not in the runtime')
            raise Refused(f'{parent} re-exports {current}, which is not in the runtime')
        images.append(name)
        for symbol in found[0]:
            provider.setdefault(symbol, name)
        queue += [(child, current) for child in found[1]]
    return provider, images


def leaf(path):
    """dyld_info's short name of a linked library: libc++.1.dylib is libc++, libSystem.B.dylib is libSystem."""
    return Path(path).name.split('.', 1)[0]


def parse_imports(text):
    """{library short name: [symbol]} from `dyld_info -imports`. Every import line must have the plain form; any other
    (such as `_foo [weak-import] (from libSystem)`) is refused rather than dropped, so no import goes unchecked."""
    imports = {}
    for line in text.splitlines():
        if not re.match(r'\s*0x[0-9A-Fa-f]+\s', line):
            continue
        match = re.fullmatch(r'\s*0x[0-9A-Fa-f]+\s+(\S+)\s+\(from ([^)]+)\)\s*', line)
        if not match:
            raise Refused(f'unexpected dyld_info -imports line: {line.strip()}')
        imports.setdefault(match.group(2), []).append(match.group(1))
    return imports


def parse_linked(text):
    """The load paths from `dyld_info -linked_dylibs` (the lines after its "-linked_dylibs:" heading)."""
    lines = text.splitlines()
    start = next((index for index, line in enumerate(lines) if line.strip() == '-linked_dylibs:'), None)
    if start is None:
        raise Refused('unexpected dyld_info -linked_dylibs output')
    return [line.split()[-1] for line in lines[start + 1:] if line.split() and line.split()[-1].startswith('/')]


def binary_facts(binary):
    """The framework's imports by library, its linked libraries and its platform."""
    imports = parse_imports(subprocess.check_output(['xcrun', 'dyld_info', '-imports', str(binary)], text=True))
    linked = parse_linked(subprocess.check_output(['xcrun', 'dyld_info', '-linked_dylibs', str(binary)], text=True))
    data = binary.read_bytes()
    base = arm64_slice(data)
    platform = Image(lambda offset, size: data[base + offset:base + offset + size]).platform()
    return imports, linked, platform


def check(runtime_root, binary, facts=binary_facts, host_exports=None):
    root = Path(runtime_root)
    binary = Path(binary)
    imports, linked, platform = facts(binary)
    if platform != 'IOSSIMULATOR':
        raise Refused(f'{binary} is built for {platform}, not the iOS simulator; a simulator runtime cannot judge it')
    by_leaf = {leaf(path): path for path in linked}
    unknown = sorted(set(imports) - by_leaf.keys() - {COALESCED})
    if unknown:
        raise Refused(f'imports from libraries that are not linked: {unknown}')
    runtime = open_runtime(root, host_exports)
    version = {}
    system = root / 'System/Library/CoreServices/SystemVersion.plist'
    if system.is_file():
        info = plistlib.loads(system.read_bytes())
        version = {key: info.get(key) for key in ('ProductName', 'ProductVersion', 'ProductBuildVersion')}
    libraries, missing, total, everything, by_host = {}, [], 0, {}, []

    def judge(library, wanted, provider):
        absent = sorted(set(wanted) - provider.keys())
        missing.extend({'symbol': symbol, 'library': library} for symbol in absent)
        hosted = sorted(symbol for symbol in wanted if provider.get(symbol, '').startswith(HOST))
        by_host.extend({'symbol': symbol, 'library': library, 'image': provider[symbol][len(HOST):]} for symbol in hosted)
        return {'imports': len(wanted), 'missing': len(absent), 'resolvedByHost': len(hosted)}

    for path in linked:
        provider, images = closure(runtime, path)
        for symbol, image in provider.items():
            everything.setdefault(symbol, image)
        wanted = imports.get(leaf(path), [])
        total += len(wanted)
        libraries[path] = {'images': sorted(images), 'exports': len(provider), **judge(path, wanted, provider)}
    coalesced = imports.get(COALESCED, [])
    if coalesced:
        total += len(coalesced)
        libraries[COALESCED] = {'images': sorted(linked), **judge(COALESCED, coalesced, everything)}
    return {
        'tool': 'scripts/check-whistle-runtime-exports.py', 'schema': 1,
        'runtimeRoot': str(root), 'runtime': version, 'layout': runtime.layout,
        'binary': str(binary), 'binarySha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'platform': platform,
        'libraries': libraries, 'imports': total, 'resolved': total - len(missing), 'missing': missing,
        'resolvedByHost': by_host,
        'resolvedByRuntime': total - len(missing) - len(by_host),
        'proves': 'every import' if not by_host else
                  f'partial: {len(by_host)} of {total} imports resolve to the host Mac, not to this runtime',
        'result': 'pass' if not missing and total else 'fail',
    }


def main(arguments):
    if len(arguments) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    try:
        result = check(*arguments)
    except (Refused, OSError, subprocess.CalledProcessError, struct.error, ValueError) as error:
        print(json.dumps({'tool': 'scripts/check-whistle-runtime-exports.py', 'schema': 1, 'result': 'error',
                          'error': str(error)}, indent=2))
        return 2
    print(json.dumps(result, indent=2))
    return 0 if result['result'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
