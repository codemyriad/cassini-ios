#!/usr/bin/env python3
"""Fast integrity/closure regressions; no compiler, inference, simulator or network."""
import importlib.util
import hashlib
import io
import struct
from whistle_binary_identity import identity
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("bundle", Path(__file__).with_name("bundle-whistle.py"))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class IntegrityTests(unittest.TestCase):
    def test_oversized_response_is_refused_and_partial_removed(self):
        pin = {"bytes": 4, "sha256": hashlib.sha256(b"0123").hexdigest(), "url": "https://invalid.example/input"}
        with tempfile.TemporaryDirectory() as root, mock.patch.dict(bundle.PINS["artifacts"], {"test": pin}), \
                mock.patch("urllib.request.urlopen", return_value=io.BytesIO(b"01234")):
            with self.assertRaises(ValueError):
                bundle.fetch(Path(root), "test")
            self.assertEqual(list(Path(root).iterdir()), [])

    def test_offline_absence_fails_without_network(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(FileNotFoundError):
                bundle.fetch(Path(root), "whistle.cact", offline=True)

    def test_corrupt_cache_fails_instead_of_refetching(self):
        with tempfile.TemporaryDirectory() as root:
            Path(root, "whistle.cact").write_bytes(b"broken")
            with self.assertRaises(ValueError):
                bundle.fetch(Path(root), "whistle.cact")

    def test_same_length_corruption_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root, "input")
            path.write_bytes(b"bad")
            with self.assertRaises(ValueError):
                bundle.verify(path, {"bytes": 3, "sha256": hashlib.sha256(b"yes").hexdigest()})

    def test_new_import_requires_sdk26_evidence(self):
        with self.assertRaises(ValueError):
            bundle.check_imports("ios-arm64", ["_made_up_ios27_symbol"])
        bundle.check_imports("ios-arm64", ["_memcpy", "_memset"])

    def test_archive_pin_change_invalidates_old_sdk26_evidence(self):
        with mock.patch.dict(bundle.PINS["artifacts"]["ios-arm64/libneedle.a"], {"sha256": "0" * 64}):
            with self.assertRaises(ValueError):
                bundle.check_imports("ios-arm64", ["_memcpy"])


class SectionIdentityTests(unittest.TestCase):
    def image(self):
        image = bytearray(320)
        def put(value, offset): struct.pack_into("<I", image, offset, value)
        for value, offset in [(0xfeedfacf,0),(0x100000c,4),(6,12),(1,16),(152,20),
                              (0x19,32),(152,36),(1,96),(16,144),(192,152),(0x80000400,168)]: put(value,offset)
        return image

    def test_payload_tampering_changes_identity_but_signing_tail_does_not(self):
        image = self.image(); before = identity(image)
        image[319] = 91
        self.assertEqual(identity(image), before)
        image[192] = 1
        self.assertNotEqual(identity(image), before)

    def test_unknown_command_or_out_of_range_section_is_refused(self):
        image = self.image(); struct.pack_into("<I",image,32,0x77777777)
        with self.assertRaises(ValueError): identity(image)
        image = self.image(); struct.pack_into("<I",image,152,0xffffffff)
        with self.assertRaises(ValueError): identity(image)


if __name__ == "__main__":
    unittest.main()
