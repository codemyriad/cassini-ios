#!/usr/bin/env python3
"""Regressions of check-whistle-runtime-exports.py over synthesized runtimes: no Xcode, simulator or build."""
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / 'check-whistle-runtime-exports.py'
spec = importlib.util.spec_from_file_location('check_whistle_runtime_exports', SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def uleb(value, width=3):
    """A ULEB128 padded to `width` bytes, so a node's size does not depend on the offsets it holds."""
    out = bytearray()
    for index in range(width):
        byte = value & 0x7f; value >>= 7
        out.append(byte | (0x80 if index < width - 1 else 0))
    assert value == 0
    return bytes(out)


def trie(names, reexported=()):
    """An export trie whose root has one edge per name, plus `reexported` names as re-export entries."""
    entries = [(name, uleb(0) + uleb(0)) for name in names]
    entries += [(name, uleb(checker.EXPORT_SYMBOL_FLAGS_REEXPORT) + uleb(1) + b'\0') for name in reexported]
    root_size = 1 + 1 + sum(len(name) + 1 + 3 for name, _ in entries)
    root, children, offset = bytearray(b'\0' + bytes([len(entries)])), bytearray(), root_size
    for name, info in entries:
        node = uleb(len(info), 1) + info + b'\0'
        root += name.encode() + b'\0' + uleb(offset)
        children += node
        offset += len(node)
    return bytes(root + children)


def nested_trie():
    """_memcpy and _memset under a shared "_mem" edge, and _abort beside it."""
    leaf = uleb(2, 1) + uleb(0, 1) + uleb(0, 1) + b'\0'
    root = b'\0\x02' + b'_mem\0' + uleb(0) + b'_abort\0' + uleb(0)
    mem_at = len(root)
    mem = b'\0\x02' + b'cpy\0' + uleb(0) + b'set\0' + uleb(0)
    abort_at = mem_at + len(mem)
    cpy_at = abort_at + len(leaf)
    set_at = cpy_at + len(leaf)
    root = b'\0\x02' + b'_mem\0' + uleb(mem_at) + b'_abort\0' + uleb(abort_at)
    mem = b'\0\x02' + b'cpy\0' + uleb(cpy_at) + b'set\0' + uleb(set_at)
    return root + mem + leaf + leaf + leaf


def command(cmd, body):
    size = (8 + len(body) + 7) // 8 * 8
    return struct.pack('<II', cmd, size) + body.ljust(size - 8, b'\0')


def dylib(names, reexports=(), reexported=(), linkedit=None, data=None, dataoff=None):
    """A thin arm64 dylib: its re-exported libraries, an optional __LINKEDIT segment (vmaddr, fileoff), then its export
    trie (`data`, else one of `names` and `reexported`). `dataoff` states another trie offset, as a shared-cache image
    whose trie lives elsewhere does."""
    data = trie(names, reexported) if data is None else data
    commands = [command(checker.LC_REEXPORT_DYLIB, struct.pack('<IIII', 24, 0, 0, 0) + path.encode() + b'\0')
                for path in reexports]
    if linkedit:
        commands.append(command(checker.LC_SEGMENT_64, b'__LINKEDIT'.ljust(16, b'\0')
                                + struct.pack('<QQQQiiII', linkedit[0], 0x4000, linkedit[1], 0x4000, 1, 1, 0, 0)))
    trie_offset = (32 + sum(map(len, commands)) + 16 + 15) // 16 * 16
    commands.append(command(checker.LC_DYLD_EXPORTS_TRIE,
                            struct.pack('<II', trie_offset if dataoff is None else dataoff, len(data))))
    body = b''.join(commands)
    header = struct.pack('<IiiIIIII', 0xfeedfacf, checker.CPU_TYPE_ARM64, 0, 6, len(commands), len(body), 0, 0)
    return (header + body).ljust(trie_offset, b'\0') + data


def fat(*slices):
    """A fat file of (cputype, subtype, thin) slices."""
    offset, entries, payload = 0x1000, b'', b''
    for cputype, subtype, thin in slices:
        entries += struct.pack('>iIIII', cputype, subtype, offset + len(payload), len(thin), 12)
        payload += thin.ljust((len(thin) + 0xfff) // 0x1000 * 0x1000, b'\0')
    return (struct.pack('>II', 0xcafebabe, len(slices)) + entries).ljust(0x1000, b'\0') + payload


LINKED = ['/usr/lib/libc++.1.dylib', '/usr/lib/libSystem.B.dylib']


def facts(imports, linked=LINKED, platform='IOSSIMULATOR'):
    return lambda binary: (imports, linked, platform)


class LooseRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='cassini runtime ')
        self.root = Path(self.directory.name) / 'RuntimeRoot'
        self.binary = Path(self.directory.name) / 'CassiniWhistleRuntime'
        self.binary.write_bytes(b'framework')
        self.host = {'/usr/lib/system/libsystem_pthread.dylib': ({'_pthread_create'}, [])}
        self.write('usr/lib/libc++.1.dylib', fat((0x01000007, 3, b'x86'),
                                                 (checker.CPU_TYPE_ARM64, 2, dylib(['_wrong_arm64e_slice'])),
                                                 (checker.CPU_TYPE_ARM64, 0, dylib(
                                                     ['__ZNSt3__16locale4nameEv'], reexports=['/usr/lib/libc++abi.dylib'],
                                                     reexported=['___cxa_throw_reexport']))))
        self.write('usr/lib/libc++abi.dylib', dylib(['___cxa_throw', '__Znwm']))
        self.write('usr/lib/libSystem.B.dylib', dylib([], reexports=[
            '/usr/lib/system/libsystem_c.dylib', '/usr/lib/system/libsystem_sim_pthread.dylib']))
        self.write('usr/lib/system/libsystem_c.dylib.real', dylib([], data=nested_trie()))
        os.symlink('/usr/lib/system/libsystem_c.dylib.real', self.root / 'usr/lib/system/libsystem_c.dylib')
        self.write('usr/lib/system/libsystem_sim_pthread.dylib',
                   dylib([], reexports=['/usr/lib/system/libsystem_sim_pthread_host.dylib']))
        self.write('usr/lib/system/libsystem_sim_pthread_host.dylib',
                   dylib([], reexports=['/usr/lib/system/libsystem_pthread.dylib']))

    def tearDown(self):
        self.directory.cleanup()

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def check(self, imports, **options):
        return checker.check(self.root, self.binary, facts(imports, **options), host_exports=self.host.get)

    def test_every_import_resolves_through_reexports_symlinks_and_the_arm64_slice(self):
        result = self.check({'libc++': ['__ZNSt3__16locale4nameEv', '___cxa_throw', '___cxa_throw_reexport'],
                             'libSystem': ['_memcpy', '_memset', '_abort'],
                             checker.COALESCED: ['__Znwm']})
        self.assertEqual(result['result'], 'pass', result)
        self.assertEqual((result['imports'], result['resolved'], result['missing']), (7, 7, []))
        self.assertEqual(result['layout'], 'dylibs')
        self.assertEqual(result['libraries']['/usr/lib/libc++.1.dylib']['images'],
                         ['/usr/lib/libc++.1.dylib', '/usr/lib/libc++abi.dylib'])
        self.assertEqual(result['resolvedByHost'], [])
        self.assertEqual((result['resolvedByRuntime'], result['proves']), (7, 'every import'))

    def test_a_symbol_the_runtime_lacks_fails_and_is_named(self):
        result = self.check({'libc++': ['__ZNSt3__16locale4nameEv', '__ZNSt3__122__libcpp_verbose_abortEPKcz'],
                             'libSystem': ['_memcpy', '___cxa_throw'], checker.COALESCED: ['__Znwm', '__Zmade_up']})
        self.assertEqual(result['result'], 'fail')
        self.assertEqual(result['missing'], [
            {'symbol': '__ZNSt3__122__libcpp_verbose_abortEPKcz', 'library': '/usr/lib/libc++.1.dylib'},
            {'symbol': '___cxa_throw', 'library': '/usr/lib/libSystem.B.dylib'},  # Two-level: libc++abi is not libSystem's.
            {'symbol': '__Zmade_up', 'library': checker.COALESCED}])
        self.assertEqual(result['resolved'], 3)
        self.assertNotIn('_wrong_arm64e_slice', checker.closure(checker.open_runtime(self.root), LINKED[0])[0])

    def test_what_only_the_host_shim_provides_is_listed_apart(self):
        result = self.check({'libSystem': ['_pthread_create', '_abort']})
        self.assertEqual(result['result'], 'pass')
        self.assertEqual(result['resolvedByHost'], [{'symbol': '_pthread_create', 'library': '/usr/lib/libSystem.B.dylib',
                                                     'image': '/usr/lib/system/libsystem_pthread.dylib'}])
        self.assertEqual(result['resolvedByRuntime'], 1)
        self.assertEqual(result['proves'], 'partial: 1 of 2 imports resolve to the host Mac, not to this runtime')
        self.assertIn('host:/usr/lib/system/libsystem_pthread.dylib',
                      result['libraries']['/usr/lib/libSystem.B.dylib']['images'])
        self.host = {}
        with self.assertRaisesRegex(checker.Refused, 'libsystem_pthread.dylib, which is not in the runtime'):
            self.check({'libSystem': ['_abort']})

    def test_only_a_host_shim_may_reach_outside_the_runtime(self):
        self.write('usr/lib/system/libsystem_c.dylib.real', dylib(['_abort'], reexports=['/usr/lib/system/libgone.dylib']))
        self.host['/usr/lib/system/libgone.dylib'] = ({'_gone'}, [])
        with self.assertRaisesRegex(checker.Refused, 'libsystem_c.dylib re-exports /usr/lib/system/libgone.dylib'):
            self.check({'libSystem': ['_abort']})

    def test_inputs_it_cannot_judge_are_refused(self):
        with self.assertRaisesRegex(checker.Refused, 'not the iOS simulator'):
            self.check({'libSystem': ['_abort']}, platform='IOS')
        with self.assertRaisesRegex(checker.Refused, 'not linked'):
            self.check({'libz': ['_inflate']})
        with self.assertRaisesRegex(checker.Refused, 'is not in the runtime'):
            self.check({'libSystem': ['_abort']}, linked=LINKED + ['/usr/lib/libmissing.dylib'])
        self.assertEqual(self.check({})['result'], 'fail', 'a framework with no imports proves nothing')
        (self.root / 'usr/lib/libSystem.B.dylib').unlink()
        with self.assertRaisesRegex(checker.Refused, 'neither'):
            self.check({'libSystem': ['_abort']})


class SharedCacheTests(unittest.TestCase):
    def test_exports_are_read_from_the_cache_and_its_subcaches(self):
        with tempfile.TemporaryDirectory(prefix='cassini cache ') as directory:
            root = Path(directory) / 'RuntimeRoot'
            caches = root / 'System/Library/Caches/com.apple.dyld'
            caches.mkdir(parents=True)
            cache = caches / 'dyld_sim_shared_cache_arm64'
            # The main file maps 0x10000 onward from offset 0, with the images at 0x11000 and 0x13000. libc++'s trie
            # lives in the subcache .01, mapped at 0x80000, as split caches keep __LINKEDIT apart: its __LINKEDIT says
            # file offset 0x200000 is address 0x80000, so trie offset 0x200400 is address 0x80400, offset 0x400 of .01.
            libc = dylib(['_ignored'], reexports=['/usr/lib/libc++abi.dylib'], linkedit=(0x80000, 0x200000),
                         dataoff=0x200400)
            abi = dylib(['___cxa_throw'], linkedit=(0x13000, 0))
            main = bytearray(0x200)
            main[:16] = b'dyld_v1   arm64\0'
            struct.pack_into('<II', main, 16, 0x200, 1)          # one mapping, at 0x200 (a modern header)
            struct.pack_into('<II', main, 448, 0x300, 2)         # two images, at 0x300
            main += struct.pack('<QQQII', 0x10000, 0x8000, 0, 5, 5).ljust(0x100, b'\0')
            main += struct.pack('<QQQII', 0x11000, 0, 0, 0x400, 0) + struct.pack('<QQQII', 0x13000, 0, 0, 0x480, 0)
            main = main.ljust(0x400, b'\0') + b'/usr/lib/libc++.1.dylib\0'
            main = main.ljust(0x480, b'\0') + b'/usr/lib/libc++abi.dylib\0'
            main = main.ljust(0x1000, b'\0') + libc
            main = main.ljust(0x3000, b'\0') + abi
            cache.write_bytes(bytes(main).ljust(0x8000, b'\0'))
            sub = bytearray(0x200)
            sub[:16] = b'dyld_v1   arm64\0'
            struct.pack_into('<II', sub, 16, 0x200, 1)
            sub += struct.pack('<QQQII', 0x80000, 0x1000, 0, 1, 1)
            sub = sub.ljust(0x400, b'\0') + trie(['_abort'])
            (caches / 'dyld_sim_shared_cache_arm64.01').write_bytes(bytes(sub).ljust(0x1000, b'\0'))
            (caches / 'dyld_sim_shared_cache_arm64.map').write_text('not a subcache')
            runtime = checker.open_runtime(root)
            self.assertEqual(runtime.layout, 'dyld_sim_shared_cache')
            provider, images = checker.closure(runtime, '/usr/lib/libc++.1.dylib')
            self.assertEqual(provider, {'_abort': '/usr/lib/libc++.1.dylib', '___cxa_throw': '/usr/lib/libc++abi.dylib'})
            self.assertEqual(images, ['/usr/lib/libc++.1.dylib', '/usr/lib/libc++abi.dylib'])
            with self.assertRaisesRegex(checker.Refused, 'not in the runtime'):
                checker.closure(runtime, '/usr/lib/libSystem.B.dylib')


class ParsingTests(unittest.TestCase):
    def test_dyld_info_output(self):
        imports = checker.parse_imports(
            '/x/CassiniWhistleRuntime [arm64]:\n    -imports:\n'
            '      0x0000  __ZTVN10__cxxabiv117__class_type_infoE  (from libc++)\n'
            '      0x0001  _abort  (from libSystem)\n'
            '      0x0077  __Znwm  (from <weak-def-coalesce>)\n')
        self.assertEqual(imports, {'libc++': ['__ZTVN10__cxxabiv117__class_type_infoE'], 'libSystem': ['_abort'],
                                   checker.COALESCED: ['__Znwm']})
        with self.assertRaisesRegex(checker.Refused, 'unexpected dyld_info -imports line: 0x0002  _strlen_weak'):
            checker.parse_imports('/x/y [arm64]:\n    -imports:\n      0x0001  _abort  (from libSystem)\n'
                                  '      0x0002  _strlen_weak [weak-import] (from <flat-namespace>)\n')
        linked = checker.parse_linked('/x/CassiniWhistleRuntime [arm64]:\n    -linked_dylibs:\n'
                                      '        attributes       load path\n'
                                      '                         /usr/lib/libc++.1.dylib\n'
                                      '                         /usr/lib/libSystem.B.dylib\n')
        self.assertEqual(linked, LINKED)
        self.assertEqual([checker.leaf(path) for path in linked], ['libc++', 'libSystem'])
        with self.assertRaises(checker.Refused):
            checker.parse_linked('/x/CassiniWhistleRuntime [arm64]:\n')

    def test_the_trie_reader_joins_edges_and_rejects_loops(self):
        self.assertEqual(checker.trie_names(nested_trie()), {'_memcpy', '_memset', '_abort'})
        with self.assertRaises(checker.Refused):
            checker.trie_names(b'\0\x01_a\0\x00')  # The child points back at the root.
        with self.assertRaises(checker.Refused):
            checker.trie_names(b'\x05')

    def test_the_command_line_names_its_usage(self):
        run = subprocess.run([sys.executable, '-I', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 2)
        self.assertIn('check-whistle-runtime-exports.py <RuntimeRoot>', run.stderr)


if __name__ == '__main__':
    unittest.main()
