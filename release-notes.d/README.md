# Fragments for people using Cassini

Each change someone can notice adds one new `release-notes.d/short-slug.md`:

```text
kind: new
---
You can now export a transcript as Markdown from a note.
```

Choose `new`, `better` or `fixed`. Write one or two complete, plain English sentences about what you can do or
what works better. Use the words on screen: note, Library, Saved voices, Record and Stop. Use sentence case and
typographic apostrophes. Do not write “please”, PR titles/numbers, decision ids, paths, source filenames, tests,
refactors or tooling. Describe the outcome; a runtime version or implementation detail rarely helps someone decide
what to try. CI rejects developer markers and unsafe text rather than copying it into TestFlight.

No user-visible change means no fragment. In particular, most CI, test and release-tooling changes have none.
Do not describe an already-shipped feature as new, or list a bug introduced and fixed before anyone received it.
The current adoption baseline is TestFlight 0.1.0 (15), source `f437a99`: it already includes Markdown, zip,
date filters, recording dates, 4 GB Parakeet support and speaker-download fixes, with human-written tester notes.
Those changes have no *pending* fragments here. Future user-visible changes add their fragments normally.

Files are immutable after publication: do not edit, rename or reuse a published slug. Add a corrective fragment
instead. The release state records filename plus SHA-256 only after Apple confirms internal testing and its notes.
An edited published fragment fails the next release before archive/upload.

Notes group whole fragments as New, Better and Fixed, in that order, then by slug. Use a sorting prefix when a
highlight needs to come first. Keep each fragment short enough to fit a group and “and smaller fixes” under the
499-character/UTF-16-unit limit. Overflow keeps the highest-priority complete fragments and ends with that phrase;
all covered fragment hashes are recorded together, including the smaller changes summarized by it.

See [the release-note procedure](../docs/release-notes.md) for preview, bookkeeping and stable curation.
