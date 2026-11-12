# SPDX-License-Identifier: CC0-1.0
"""Reject incoherent v3 fixtures rather than blessing regenerated expectations."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('badge_contract',Path(__file__).with_name('verify.py'))
contract=importlib.util.module_from_spec(spec);spec.loader.exec_module(contract)

class ContractChecks(unittest.TestCase):
    def test_committed_contract(self):contract.verify()

    def test_corrupt_contracts_fail_assertions(self):
        def catalog_entry(data,key):return next(e for e in data['entries'] if e['id']==key)
        mutations=[
            ('legacy tone','vectors/states/states-vectors.json',lambda d:d['vectors'][2]['badge'].update(tint='accent')),
            ('wrong glyph','vectors/states/states-vectors.json',lambda d:d['vectors'][1]['badge'].update(glyph='dot')),
            ('invented precedence','vectors/states/states-vectors.json',lambda d:d['precedence'].insert(1,'importing')),
            ('missing importing','vectors/states/states-vectors.json',lambda d:d.update(entryVectors=[])),
            ('stale ETA','vectors/format/format-vectors.json',lambda d:d['eta'][2].update(out='Transcribing, about 4 minutes left')),
            ('lost placeholder','strings/strings.json',lambda d:catalog_entry(d,'states.badge.recording')['l10n']['fr'].update(text='Enregistrement')),
            ('lost plural count','strings/strings.json',lambda d:catalog_entry(d,'states.badge.transcribing')['l10n']['it']['plural'].update(other='In trascrizione')),
            ('undecided fallback rewrite','strings/strings.json',lambda d:catalog_entry(d,'states.badge.transcribing.noEta').update(en='Transcribing · soon')),
            ('stale Library badge','vectors/library-vectors/expected/main.json',lambda d:d['groups'][0]['meetings'][0].update(badge='Recording')),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for path in ['strings/strings.json','vectors/states/states-vectors.json','vectors/format/format-vectors.json']:
                target=root/path;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(contract.ROOT/path,target)
            shutil.copytree(contract.ROOT/'vectors/library-vectors/expected',root/'vectors/library-vectors/expected')
            with patch.object(contract,'ROOT',root):
                for name,path,mutate in mutations:
                    with self.subTest(name=name):
                        file=root/path;original=file.read_bytes();data=json.loads(original);mutate(data)
                        try:
                            file.write_text(json.dumps(data))
                            with redirect_stdout(io.StringIO()),self.assertRaises(AssertionError):contract.verify()
                        finally:file.write_bytes(original)
                contract.verify()

if __name__=='__main__':unittest.main()
