#!/usr/bin/env python3
"""Fast fragment/store boundary checks using real files; no network or release side effects."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('user_notes', Path(__file__).with_name('testflight_notes.py'))
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)


class UserReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cassini-user-notes-')
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name)
        self.directory = self.source / 'release-notes.d'
        self.directory.mkdir()

    def fragment(self, name, kind, text):
        file = self.directory / name
        file.write_text('kind: ' + kind + '\n---\n' + text + '\n', encoding='utf-8')
        return file

    def test_empty_source_has_the_exact_non_developer_fallback(self):
        self.assertEqual(notes.collect_fragments(self.source, {}), [])
        self.assertEqual(notes.render_test_notes([]),
            'Fixes and improvements under the hood. Nothing changes in how you use Cassini.')
        self.directory.rmdir()
        self.assertEqual(notes.collect_fragments(self.source, {}), [])

    def test_identical_visible_outcomes_are_shown_once_without_losing_fragment_ids(self):
        for name, kind in [('export-a.md', 'new'), ('export-b.md', 'fixed')]:
            self.fragment(name, kind, 'You can export your notes together.')
        records = notes.collect_fragments(self.source, {})
        self.assertEqual(len(records), 2)
        self.assertEqual(notes.render_test_notes(records), 'New: You can export your notes together.')

    def test_real_fragments_have_ids_raw_hashes_and_deterministic_user_groups(self):
        fixed = self.fragment('01-import-recovery.md', 'fixed', 'Importing a zip now keeps the right meeting count if you cancel partway.')
        new = self.fragment('03-markdown-export.md', 'new', 'You can now export a transcript as Markdown from the Library.')
        better = self.fragment('02-more-phones.md', 'better', 'Parakeet Ultra now works on phones with 4 GB of memory.')
        (self.directory / 'README.md').write_text('# Developer docs\nCI #123 D95\n')
        fragments = notes.collect_fragments(self.source, {})
        self.assertEqual([f['id'] for f in fragments], [fixed.name, better.name, new.name])
        self.assertEqual(fragments[0]['sha256'], hashlib.sha256(fixed.read_bytes()).hexdigest())
        text = notes.render_test_notes(fragments)
        self.assertEqual(text, 'New: You can now export a transcript as Markdown from the Library.\n'
            'Better: Parakeet Ultra now works on phones with 4 GB of memory.\n'
            'Fixed: Importing a zip now keeps the right meeting count if you cancel partway.')
        self.assertEqual(notes.render_test_notes(list(reversed(fragments))), text)
        for fragment in fragments:
            self.assertNotIn(fragment['id'], text)
            self.assertNotIn(fragment['sha256'], text)

    def test_wrapped_sentences_keep_their_meaning_and_typographic_apostrophes(self):
        self.fragment('readable-notes.md', 'better',
            'Long transcripts are easier to read.\nYou don’t need to choose a different view.')
        fragments = notes.collect_fragments(self.source, {})
        self.assertEqual(fragments[0]['text'], 'Long transcripts are easier to read. You don’t need to choose a different view.')

    def test_invalid_metadata_and_non_plain_sentence_shapes_fail_before_rendering(self):
        file = self.directory / 'import.md'
        for body in ['kind: Added\n---\nImports are clearer.', 'kind:new\n---\nImports are clearer.',
                     'kind: fixed\nImports are clearer.', 'kind: fixed\n---\n',
                     'kind: fixed\n---\nImport improvements',
                     'kind: fixed\n---\nOne change. Another change. A third change.',
                     'kind: fixed\n---\n- Importing recordings is easier.',
                     'kind: fixed\n---\nImporting is easier.\n\nYour Library stays ready.']:
            with self.subTest(body=body):
                file.write_text(body)
                with self.assertRaises(ValueError):
                    notes.collect_fragments(self.source, {})

    def test_developer_titles_ids_code_paths_links_and_controls_cannot_reach_the_store(self):
        bad = ['Fix export after #123.', 'Import now follows D95.', 'The CI is now green.',
            'You can now open /tmp/meeting.json.', 'Saved voices now use VoiceStore.swift.',
            'fix: Preserve completed imports.', 'chore(model): Bump the runtime.',
            'Refactors make imports faster.', 'The workflow now starts sooner.',
            'You can now <b>import recordings</b>.',
            'You can now use [Saved voices](https://example.invalid).',
            'Import now works.\u202e', 'Import now works.\x00', 'The C\u200dI is now green.',
            'Transcripts now open from www.example.invalid.', 'You can now open `Notes`.',
            'You can now export notes.txt.', 'You can now view src/LibraryView.swift.',
            'Add localized Markdown export with shared S-5 and D84 parity.']
        for text in bad:
            with self.subTest(text=text):
                self.fragment('unsafe.md', 'fixed', text)
                with self.assertRaises(ValueError):
                    notes.collect_fragments(self.source, {})
                with self.assertRaises(ValueError):
                    notes.validate_test_notes(text)

    def test_final_store_boundary_rejects_invalid_unicode_and_both_length_overflows(self):
        for text in ['A note.\ud800', '😀' * 250, 'x' * 500, 'Fixed: src/App.swift now works.']:
            with self.subTest(text=repr(text)):
                with self.assertRaises(ValueError):
                    notes.validate_test_notes(text)
        self.assertEqual(notes.validate_test_notes('😀' * 249), '😀' * 249)
        self.assertEqual(notes.validate_test_notes('x' * 499), 'x' * 499)

    def test_overflow_keeps_whole_new_fragments_first_and_a_smaller_fixes_summary(self):
        self.fragment('00-small-fix.md', 'fixed', 'Opening a recording now keeps your place. ' + 'The Library stays ready for your next recording.')
        self.fragment('b-new.md', 'new', 'You can now keep a copy of a recording with its transcript. '
            'The Library stays ready while you choose where to save your recording.')
        self.fragment('a-new.md', 'new', 'You can now find a recording from the Library with a shorter search. '
            'Your recordings stay together while you choose what to open next.')
        self.fragment('a-better.md', 'better', 'Long transcripts now keep each speaker’s paragraphs together. '
            'You can follow a reply without losing your place in the conversation.')
        self.fragment('b-fixed.md', 'fixed', 'Importing a zip now keeps completed recordings when you cancel. '
            'The Library shows how many recordings were added before you stopped.')
        fragments = notes.collect_fragments(self.source, {})
        text = notes.render_test_notes(fragments)
        self.assertEqual(notes.render_test_notes(list(reversed(fragments))), text)
        self.assertTrue(text.startswith('New: '))
        self.assertTrue(text.endswith('and smaller fixes'))
        self.assertLess(len(text), 500)
        self.assertLess(len(text.encode('utf-16-le')) // 2, 500)
        for fragment in fragments:
            first_sentence = fragment['text'].split('. ')[0] + '.'
            if first_sentence in text:
                self.assertIn(fragment['text'], text, 'A fragment is never cut halfway through')
        first = next(f['text'] for f in fragments if f['id'] == 'a-new.md')
        second = next(f['text'] for f in fragments if f['id'] == 'b-new.md')
        self.assertIn(first, text)
        self.assertIn(second, text)
        self.assertLess(text.index(first), text.index(second))

    def test_supplementary_characters_are_budgeted_as_utf16_without_sentence_cutting(self):
        self.fragment('a-new.md', 'new', 'You can now keep a recording close. ' + '😀' * 100 + '.')
        self.fragment('b-new.md', 'new', 'You can now find your saved recording sooner. ' + '😀' * 100 + '.')
        self.fragment('c-new.md', 'new', 'You can now return to the Library sooner. ' + '😀' * 100 + '.')
        fragments = notes.collect_fragments(self.source, {})
        text = notes.render_test_notes(fragments)
        self.assertLess(len(text.encode('utf-16-le')) // 2, 500)
        self.assertEqual(text.encode('utf-16-le').decode('utf-16-le'), text)
        self.assertTrue(text.endswith('and smaller fixes'))
        self.assertIn(fragments[0]['text'], text)
        self.assertNotIn(fragments[2]['text'], text)

    def test_oversized_single_fragment_requires_an_editor_instead_of_truncation(self):
        self.fragment('too-long.md', 'new', 'You can now ' + 'find recordings ' * 40 + 'more easily.')
        with self.assertRaisesRegex(ValueError, 'too long'):
            notes.collect_fragments(self.source, {})

    def test_published_unchanged_fragments_are_skipped_but_edits_are_refused(self):
        file = self.fragment('import.md', 'fixed', 'Importing recordings now keeps their original dates.')
        records = notes.collect_fragments(self.source, {})
        published = {f['id']: f['sha256'] for f in records}
        self.assertEqual(notes.collect_fragments(self.source, published), [])
        file.write_text(file.read_text().replace('fixed', 'better'))
        with self.assertRaisesRegex(ValueError, 'Published release fragment was edited'):
            notes.collect_fragments(self.source, published)

    def test_fragment_symlinks_and_non_slug_ids_are_refused(self):
        outside = self.source / 'outside.md'
        outside.write_text('kind: fixed\n---\nImporting is clearer.')
        (self.directory / 'outside.md').symlink_to(outside)
        with self.assertRaises(ValueError):
            notes.collect_fragments(self.source, {})
        (self.directory / 'outside.md').unlink()
        self.fragment('Bad Name.md', 'fixed', 'Importing is clearer.')
        with self.assertRaises(ValueError):
            notes.collect_fragments(self.source, {})

    def test_developer_details_stay_folded_and_html_escaped_outside_store_notes(self):
        store = notes.render_test_notes([])
        developer = 'DEVELOPER_SENTINEL fix: Foo.swift (#123) </pre></details><script>bad</script> & D95'
        body = notes.github_release_body(store, developer)
        self.assertEqual(body.split('\n\n<details>')[0], store)
        self.assertNotIn('DEVELOPER_SENTINEL', store)
        self.assertIn('DEVELOPER_SENTINEL', body)
        self.assertEqual(body.count('</details>'), 1)
        self.assertNotIn('<script>', body)
        self.assertIn('&lt;/pre&gt;&lt;/details&gt;&lt;script&gt;', body)
        self.assertIn('&amp;', body)

    def test_stable_notes_are_explicit_manual_input_without_fallback_or_file_mutation(self):
        path = self.source / 'stable.md'
        for missing in [None, path]:
            with self.assertRaisesRegex(ValueError, 'hand-curated'):
                notes.require_stable_notes(missing)
        path.write_text(' \n\t')
        with self.assertRaisesRegex(ValueError, 'nonempty'):
            notes.require_stable_notes(path)
        content = '## Highlights\n\nYour recordings now keep their original dates.\n'
        path.write_text(content)
        self.assertEqual(notes.require_stable_notes(path), content.strip())
        self.assertEqual(path.read_text(), content)


if __name__ == '__main__':
    unittest.main()
