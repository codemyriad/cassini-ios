#!/usr/bin/env python3
"""The production extractor must see modern lookups and native plural/bundle lookups alike."""
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class CatalogExtractionTests(unittest.TestCase):
    def test_both_localization_apis_use_the_same_checked_table(self):
        script = Path(__file__).with_name('check-strings.sh').read_text()
        line = next(line for line in script.splitlines() if line.startswith('xcrun xcstringstool extract '))
        command = shlex.split(line.split('"${sources[@]}"', 1)[0])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'EnglishFixture.swift'
            source.write_text('''import Foundation
let modern = String(localized: "Modern", table: "Example")
func pluralTemplate(bundle: Bundle) -> String {
    NSLocalizedString("NativePlural", tableName: "Example", bundle: bundle, comment: "English count template")
}
''')
            output = root / 'extracted'
            output.mkdir()
            subprocess.run(command + [str(source), '--output-directory', str(output)], check=True, capture_output=True)
            tables = {}
            for path in output.glob('*.stringsdata'):
                for table, entries in json.loads(path.read_text()).get('tables', {}).items():
                    tables.setdefault(table, set()).update(entry['key'] for entry in entries)
            self.assertEqual(tables.get('Example'), {'Modern', 'NativePlural'})
            self.assertNotIn('Localizable', tables)


if __name__ == '__main__':
    unittest.main()
