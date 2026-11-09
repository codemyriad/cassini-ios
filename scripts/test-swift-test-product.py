#!/usr/bin/env python3
"""Command-selection regressions using a fake Swift CLI: no package builds/tests."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / 'scripts/test.sh').read_text()
TARGETS = re.findall(r'\.testTarget\(name: "([^"]+)"', (ROOT / 'Package.swift').read_text())
HELP = '--test-product <test-product>\nSpecify the build system to use. (default: swiftbuild)'


def function(name):
    start = SOURCE.index(name + '() {')
    return SOURCE[start:SOURCE.index('\n}\n', start) + 3]


class ProductSelectionTests(unittest.TestCase):
    def invoke(self, filter, help=HELP, help_status=0, test_status=0):
        with tempfile.TemporaryDirectory(prefix='cassini product selection ') as temporary:
            directory = Path(temporary)
            env = dict(os.environ, STUB_ROOT=str(directory), STUB_HELP=help,
                       STUB_HELP_STATUS=str(help_status), STUB_TEST_STATUS=str(test_status),
                       CASSINI_CONFORMANCE_REQUIRED='1')
            script = '\n'.join(function(name) for name in ('swift_test_product', 'swift_test')) + r'''
                conformance_env() { echo conformance >> "$STUB_ROOT/order"; }
                seed_swiftpm() { echo seed >> "$STUB_ROOT/order"; }
                save_swiftpm() { echo save >> "$STUB_ROOT/order"; }
                run_logged() { shift 2; "$@"; }
                swift() {
                    if [ "$#" = 2 ] && [ "$1" = test ] && [ "$2" = --help-hidden ]; then
                        echo help >> "$STUB_ROOT/order"
                        printf '%s\n' "$STUB_HELP"
                        return "$STUB_HELP_STATUS"
                    fi
                    echo run >> "$STUB_ROOT/order"
                    printf '%s\0' "$@" > "$STUB_ROOT/arguments"
                    printf '%s\n' "$CASSINI_CONFORMANCE_REQUIRED" > "$STUB_ROOT/required"
                    return "$STUB_TEST_STATUS"
                }
                logs="$STUB_ROOT"
                swift_test "$1"
            '''
            result = subprocess.run(['/bin/bash', '-eu', '-c', script, 'fixture', filter],
                                    env=env, capture_output=True, text=True)
            args = (directory / 'arguments').read_bytes().split(b'\0')[:-1]
            return (result.returncode, [arg.decode() for arg in args],
                    (directory / 'order').read_text().splitlines(),
                    (directory / 'required').read_text().strip())

    def test_every_current_single_test_target_selects_its_product_and_keeps_filter(self):
        for target in TARGETS:
            with self.subTest(target=target):
                status, args, order, required = self.invoke(target)
                self.assertEqual(status, 0)
                self.assertEqual(args, ['test', '--test-product', target, '--filter', target])
                self.assertEqual(order, ['conformance', 'seed', 'help', 'run', 'save'])
                self.assertEqual(required, '1')

    def test_full_unknown_multi_and_arbitrary_filters_never_narrow_products(self):
        for filter in ['', 'ALL', 'UnknownTests', 'CassiniNotebookTests|CassiniEngineTests',
                       '^CassiniNotebookTests$', 'CassiniNotebookTests.Suite/test',
                       'CassiniNotebookTests CassiniEngineTests', "a 'literal' $(command)\nfilter"]:
            with self.subTest(filter=filter):
                status, args, order, required = self.invoke(filter)
                self.assertEqual(status, 0)
                self.assertEqual(args, ['test'] + (['--filter', filter] if filter else []))
                self.assertEqual(order, ['conformance', 'seed', 'run', 'save'])
                self.assertEqual(required, '1')

    def test_missing_hidden_option_native_backend_or_failed_probe_preserve_old_command(self):
        cases = [('', 0), (HELP.replace('--test-product <test-product>', ''), 0),
                 (HELP.replace('default: swiftbuild', 'default: native'), 0), (HELP, 64)]
        for help, help_status in cases:
            with self.subTest(help=help, help_status=help_status):
                status, args, order, required = self.invoke('CassiniNotebookTests', help, help_status)
                self.assertEqual(status, 0)
                self.assertEqual(args, ['test', '--filter', 'CassiniNotebookTests'])
                self.assertEqual(order[-2:], ['run', 'save'])
                self.assertEqual(required, '1')

    def test_selected_product_failure_is_returned_and_dependencies_are_still_saved(self):
        status, args, order, required = self.invoke('CassiniNotebookTests', test_status=23)
        self.assertEqual(status, 23)
        self.assertIn('--test-product', args)
        self.assertEqual(order[-2:], ['run', 'save'])
        self.assertEqual(required, '1')

    def test_existing_changed_mapping_has_a_practical_single_target_path(self):
        script = function('swift_targets_for') + '\nswift_targets_for "$1"'
        path = 'Packages/CassiniNotebook/Tests/CassiniNotebookTests/TurnModelVectorTests.swift'
        result = subprocess.run(['/bin/bash', '-eu', '-c', script, 'fixture', path],
                                capture_output=True, text=True, check=True)
        target = result.stdout.strip()
        self.assertEqual(target, 'CassiniNotebookTests')
        self.assertEqual(self.invoke(target)[1], ['test', '--test-product', target, '--filter', target])
        source = path.replace('/Tests/CassiniNotebookTests/', '/Sources/CassiniNotebook/')
        result = subprocess.run(['/bin/bash', '-eu', '-c', script, 'fixture', source],
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.split(), ['CassiniNotebookTests', 'CassiniEngineTests', 'CassiniInferenceTests'])


if __name__ == '__main__':
    unittest.main()
