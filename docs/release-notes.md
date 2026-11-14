# Release notes

The developer changelog and tester notes have different readers. Developer PR titles and direct commit subjects
remain automatic, precise audit material. TestFlight’s What to Test comes only from hand-written
[user fragments](../release-notes.d/README.md), never from developer titles. Test notes are English and under
500 characters, including headings and overflow text. With no user-visible changes, publish:

> Fixes and improvements under the hood. Nothing changes in how you use Cassini.

Preview pending fragments with `python3 scripts/testflight_notes.py .`. `--published ledger.json` accepts a
JSON filename-to-SHA-256 map for an operator preview. CI checks all repository fragments without private state
and runs renderer and publication/recovery regressions (all through `scripts/test-daily-testflight.py`). The real release collects the frozen main checkout’s
unpublished fragments against `published_fragments` in the existing private release state. Store-ready notes and
the fragment hashes are saved in the durable upload intent; failure does not consume them. Recovery uses that
same frozen text/hash set, never later edits. Only successful internal distribution and note publication advance
the ledger. Older pending intents containing developer notes migrate to the honest fallback; their original text
is retained for audit and their binary is never resubmitted.

`release-notes-testflight.txt` is the store text. `release-notes.txt` retains the developer list;
`release-notes-github.md` puts user notes first and folds the escaped developer list below them. This iOS tool
publishes only to the existing internal TestFlight group: generating a GitHub-format body does not create a
GitHub release. No new public distribution path is added.

## Stable releases

Stable notes are an editing task, not automatic concatenation. Gather every change since the last stable notes;
sort it into highlights, improvements, fixes, action required, or leave out. Group by the part of Cassini the
reader recognizes. Say what changed for them, with one concrete outcome per sentence. Leave out development
work and fixes to bugs nobody received. Use a number only when it helps a person decide. Anything they must do,
a changed default or new requirement goes under “Before you update”, including what happens if they do nothing.
Keep only sections with content, and have someone other than the author review the wording.

Supply the curated file explicitly: `python3 scripts/testflight_notes.py --stable path/to/notes.md`.
Missing/empty notes are refused; `require_stable_notes(None)` also refuses, with no developer/test fallback.
There is no App Store/public publisher in this repository; a future one must call that same guard before any
distribution action. This command only validates/previews text. Public submission still needs Silvio’s approval.
