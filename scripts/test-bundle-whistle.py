#!/usr/bin/env python3
"""Fast integrity/closure regressions; no compiler, inference, simulator or network."""
import importlib.util
import hashlib
import io
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


if __name__ == "__main__":
    unittest.main()
