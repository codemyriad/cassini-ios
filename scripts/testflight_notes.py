#!/usr/bin/env python3
"""Hand-written user fragments for test builds; developer titles are never a renderer input."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import unicodedata

FALLBACK_NOTES = 'Fixes and improvements under the hood. Nothing changes in how you use Cassini.'
NOTE_LIMIT = 499  # Strictly under 500, counting both Unicode scalars and UTF-16 code units.
OVERFLOW_NOTE = 'and smaller fixes'
KINDS = ('new', 'better', 'fixed')
SLUG = re.compile(r'[a-z0-9]+(?:-[a-z0-9]+)*\.md')
DEVELOPER_PREFIX = re.compile(r'^(?:feat|fix|chore|docs|refactor|test|perf|ci|build|style|revert)(?:\([^)]*\))?!?\s*:', re.I)
DEVELOPER_MARKERS = re.compile(
    r'#\s*\d+|\bD\d+\b|\b(?:CI|tests?|refactors?|refactoring|tooling|benchmarks?|commits?|pull requests?|workflows?|pipelines?)\b', re.I)
SOURCE_FILE = re.compile(
    r'\.[a-z0-9_-]*(?:swift|kt|kts|ts|tsx|js|jsx|go|py|sh|c|h|cpp|m|mm|ya?ml|toml|gradle|pbxproj|json|lock)\b'
    r'|\b[\w-]+\.(?:md|txt|zip|opus|wav|mp3|m4a|flac|vtt|srt)\b', re.I)


def _fits(text):
    return len(text) <= NOTE_LIMIT and len(text.encode('utf-16-le')) // 2 <= NOTE_LIMIT


def _safe_text(text):
    if not isinstance(text, str) or not text.strip():
        raise ValueError('User release notes must not be empty')
    for char in text:
        category = unicodedata.category(char)
        if char != '\n' and category in ('Cc', 'Cf', 'Cs', 'Zl', 'Zp'):
            raise ValueError('User release notes contain control, bidi or invalid Unicode characters')
    if any(char in text for char in ('<', '>', '`', '/', '\\')) or re.search(r'\[[^\]]*\]\s*\(', text):
        raise ValueError('User release notes must contain plain text, without HTML, links, code or paths')
    if re.search(r'\b(?:www\.|[a-z][a-z0-9+.-]*:)', text, re.I):
        # Group labels are the only generated colon-prefixed forms.
        without_labels = re.sub(r'(?m)^(?:New|Better|Fixed): ', '', text)
        if re.search(r'\b(?:www\.|[a-z][a-z0-9+.-]*:)', without_labels, re.I):
            raise ValueError('User release notes must not contain links or technical prefixes')
    if DEVELOPER_MARKERS.search(text) or SOURCE_FILE.search(text):
        raise ValueError('Developer identifiers, CI, source files and tooling do not belong in user release notes')
    if any(DEVELOPER_PREFIX.match(line.strip()) for line in text.splitlines()):
        raise ValueError('Developer changelog prefixes do not belong in user release notes')
    return text


def validate_test_notes(text):
    """Validate the final store-facing sink, also when resuming a persisted pending release."""
    text = _safe_text(text).strip()
    if not _fits(text):
        raise ValueError('Test release notes must be under 500 characters and UTF-16 code units')
    return text


def _fragment_text(text, kind):
    _safe_text(text)
    lines = text.strip().splitlines()
    if any(not line.strip() or re.match(r'\s*(?:[-*+]\s|#|\d+\.\s)', line) for line in lines):
        raise ValueError('A fragment must be one plain paragraph, without Markdown lists or headings')
    text = ' '.join(line.strip() for line in lines)
    sentences = re.findall(r'[.!?][\u201d\u2019"]?(?=\s|$)', text)
    if not 1 <= len(sentences) <= 2 or not re.search(r'[.!?][\u201d\u2019"]?$', text):
        raise ValueError('A fragment must contain one or two complete sentences')
    if not _fits(kind.title() + ': ' + text + '\n' + OVERFLOW_NOTE):
        raise ValueError('A fragment is too long to publish whole; write a shorter user-facing sentence')
    return text


def collect_fragments(source, published):
    """Collect unpublished files from source/release-notes.d; ids are filenames, hashes cover raw bytes."""
    directory = Path(source) / 'release-notes.d'
    if directory.is_symlink():
        raise ValueError('The fragment directory must not be a symlink')
    if not directory.exists():
        return []
    if not directory.is_dir():
        raise ValueError('release-notes.d must be a directory')
    result = []
    for file in sorted(directory.glob('*.md')):
        if file.name == 'README.md':
            continue
        if not SLUG.fullmatch(file.name) or file.is_symlink() or not file.is_file():
            raise ValueError('Invalid release fragment filename or symlink: ' + file.name)
        raw = file.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if file.name in published:
            if published[file.name] != digest:
                raise ValueError('Published release fragment was edited: ' + file.name)
            continue
        text = raw.decode('utf-8').replace('\r\n', '\n')
        match = re.fullmatch(r'kind: (new|better|fixed)\n---\n(.+)', text, re.S)
        if not match:
            raise ValueError('Expected kind: new|better|fixed, separator ---, then user text: ' + file.name)
        kind, text = match.groups()
        result.append(dict(id=file.name, sha256=digest, kind=kind, text=_fragment_text(text, kind)))
    return result


def render_test_notes(fragments):
    """Choose whole fragments by kind then filename; all collected ids are published, including overflow."""
    if not fragments:
        return validate_test_notes(FALLBACK_NOTES)
    ordered = sorted(fragments, key=lambda f: (KINDS.index(f['kind']), f['id']))
    for fragment in ordered:
        if not SLUG.fullmatch(fragment['id']):
            raise ValueError('Invalid release fragment id')
        _fragment_text(fragment['text'], fragment['kind'])
    # Parallel changes may describe the same visible outcome. Keep its highest-priority entry once.
    unique, seen = [], set()
    for fragment in ordered:
        if fragment['text'] not in seen:
            seen.add(fragment['text'])
            unique.append(fragment)
    ordered = unique

    def grouped(selected):
        return '\n'.join(kind.title() + ': ' + ' '.join(f['text'] for f in selected if f['kind'] == kind)
                         for kind in KINDS if any(f['kind'] == kind for f in selected))

    complete = grouped(ordered)
    if _fits(complete):
        return validate_test_notes(complete)
    selected = []
    for fragment in ordered:
        if _fits(grouped(selected + [fragment]) + '\n' + OVERFLOW_NOTE):
            selected.append(fragment)
    return validate_test_notes(grouped(selected) + '\n' + OVERFLOW_NOTE)


def github_release_body(user_notes, developer_text):
    """Developer detail remains escaped and folded; it is never part of store-facing notes."""
    developer_text = developer_text.encode('utf-8', errors='backslashreplace').decode('utf-8')
    return (validate_test_notes(user_notes) + '\n\n<details>\n<summary>Developer changelog</summary>\n\n<pre>'
            + html.escape(developer_text, quote=True) + '</pre>\n</details>\n')


def require_stable_notes(path):
    """Stable publishers must supply curated notes; no automatic fragments/developer fallback exists."""
    if path is None or not Path(path).is_file():
        raise ValueError('Stable releases require a hand-curated release-notes file')
    text = Path(path).read_text(encoding='utf-8').strip()
    if not text:
        raise ValueError('Stable releases require nonempty hand-curated release notes')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', nargs='?', type=Path, default=Path.cwd())
    parser.add_argument('--published', type=Path, help='JSON object mapping published filenames to SHA-256')
    parser.add_argument('--stable', type=Path, help='Preview required hand-curated stable notes instead')
    args = parser.parse_args()
    try:
        published = json.loads(args.published.read_text()) if args.published else {}
        print(require_stable_notes(args.stable) if args.stable else render_test_notes(collect_fragments(args.source, published)))
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
