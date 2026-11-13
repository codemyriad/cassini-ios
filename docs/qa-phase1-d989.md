# Phase 1 iOS QA (D-989)

Audit baseline: `0fc91b17ce8a53130d1c52ae74597902b0394482` (main).
Shared contracts: cassini-ux `994967ead64e1adc8e75774ca1455823d2c8ef3b`;
app token/catalog receipts remain at their existing immutable pins.

This audit separates regressions in merged code from implementation work already assigned to open Phase 1 PRs.
It does not certify the unmerged implementations. Recheck those surfaces after their own review and merge.

| Surface | Baseline finding | Disposition |
| --- | --- | --- |
| Library | Finished rows still have a Transcribed chip and quote; speaker and bookmark counts lack the final pill anatomy. | Existing WP2 [#145](https://github.com/codemyriad/cassini-ios/pull/145), D-954. |
| Search | A Thursday result displays only “…pause.” because paragraph breaks consume its two-line snippet. Library and Find also match synthetic inline-speaker labels. The top capsule/result heading remain WP2 work. | Fix spoken-word matching and single-line snippets here; retain existing WP2 #145 and filters (L-34/L-35 remain open). |
| Meeting | One-step open, inline speakers, Find, speed-left/bookmark-right player, and scrolled title are implemented. Header speaker names use ink while their dots and transcript labels use the assigned speaker colour. | Fix the header names to use the same speaker tint (BRAND, HARMONY 10.10). Keep unnamed stone and existing rename targets. |
| Recording | Forced dark brand ground and waveform are present. Final Stop/All meetings/Pause layout and terminology are pending. | Existing WP4 [#146](https://github.com/codemyriad/cassini-ios/pull/146), D-960. |
| Transcribing | Live draft is present; the expanded processing card has not yet become the compact status line/details sheet. | Existing WP5 [#148](https://github.com/codemyriad/cassini-ios/pull/148), D-964. |
| Name a speaker | Native sheet, sample, saved voices and remember control are present. Final neutral duplicate notice and single-column layout are pending. | Existing WP6 [#147](https://github.com/codemyriad/cassini-ios/pull/147), D-968. |

## Contract boundaries

- Both system appearances use the pinned brand roles, including six named speaker slots repeating after six and stone before naming. Recording deliberately stays dark.
- iOS keeps Dynamic Type, native glass on iOS 26+, material fallback on iOS 18, bookmarks, Live Activity, and the existing export formats. Desktop-only chrome, export restrictions and Imported rename do not apply to phones (L-10 is open).
- No catalog or vector copy is edited. Speaker names, identity, ordering, timings, persistence and recording lifecycle stay unchanged. Search uses the actual words in reading order, mapping Find ranges back to their displayed offsets across inline labels; a genuinely spoken name still matches after a speaker rename. Search snippets join words with spaces, as Android’s reading text joins paragraphs.
- Bug classes #1–3 and #5/#8–10 are covered by the spoken-search tests, existing cache/render checks and native interaction suite. The 50,000/100,000-word search test bounds scaling with calling-thread CPU, never elapsed time. #4/#6/#7 and #11–16 have no changed ordering, hit-target, format, localization or I/O rule. #17 uses viewport/event checks and CPU scaling; #18 branches from main; #19 requires exact-head CI and the local full gate before readiness.

## Evidence

Use `scripts/screenshots.sh --device iphone --output DerivedData.noindex/qa/d989/before` on the baseline and the same command with `after` on the corrected head. The named seeds cover Library, Search, Meeting, Recording, Transcribing and Name a speaker in light and dark, plus seven speakers, Find and the compact title. `15-seven-speaker-meeting` is the direct regression comparison: unnamed stone, six named colours, and the first named colour repeating in the transcript.

The baseline product binary was built at `4238ced` (app sources identical to main `0fc91b1`). Its Transcribing capture was repaired with the test-only viewport change described below before recapture; both comparison sets use that repaired screenshot check.

Generated images and build outputs stay out of git. The before/after comparison boards are attached to D-989; validation results and the exact audited head are recorded in the PR.

## Behaviour and accessibility coverage

The existing full gate provides the interaction checks alongside the visual capture:

| Area | Checks |
| --- | --- |
| Library and Search | `LibraryUITests.testEveryRowStatusShowsWithItsText`, `testSearchShowsFlatResultsAndSaysWhenNothingMatches`, `testSearchDateMenuNarrowsMatchesAndClearingResetsIt` |
| Meeting and Find | `NoteScreenTests.testAnInlineHeaderNameOpensNamingForThatSpeaker`, `testInNoteSearchCountsAndWraps`, `testANoteOpenedFromALibrarySearchScrollsToTheFirstMatch` |
| Scrolled title | `NoteScreenTests.testCompactTitleAppearsJustPastTheNavigationBarAndHidesTheOriginalFromAccessibility`, its iPad equivalent, and the Find/inset checks |
| Recording | `LibraryUITests.testDuringARecordingTheCardTheButtonAndTheRowReturnToIt`, `RecordingSelectionTests`, and the Recording accessibility audit |
| Live draft | `NoteScreenTests.testTheDraftFollowsItsEndBelowTheFixedCard`, inline-speaker naming and suggestion checks |
| Speaker naming | `SpeakerNamingFlowTests`, including Italian stored placeholders, saved-voice suggestion and duplicate-name question |
| Large text and colours | `StatusBadgeLayoutTests.testFrenchBadgesStayInsideTheRowAtLargestText`, `AccessibilityAuditTests`, `BrandTokenTests`, `ContrastTests` |

These checks establish existing behaviour; they do not substitute for the open work packages' acceptance checks.

## QA harness corrections

The initial Transcribing screenshot failed in both appearances because XCTest could not compute an activation point for the offscreen static draft heading. The capture now swipes the real scroll view and checks that the heading’s complete frame is inside its visible viewport below the pinned card before each gesture. The focused baseline recapture passes in both appearances.

The iOS 18 combined accessibility audit has a separately documented baseline failure on unchanged Settings/List screens (also reproduced during WP2/WP4 validation). Run clipping separately from element detection and the remaining checks, as in WP2’s harness repair. Every requested audit type, existing filter and issue-count limit remains enabled; the full native gate checks the result here.

`SearchSpokenWordsTests` reproduces the search defects against the baseline and covers label-only matches, genuinely spoken names across a cached rename, inline-reply source mapping, a phrase crossing an inline label, paragraph-spanning snippets, and an eleven-hour transcript’s CPU scaling.

The isolated worktree has no sibling cassini-format checkout. Validation therefore fetches the public `32f37a6200c88bdd4d23c1f44497f1761f3401da` vectors into the ignored build area and sets `CASSINI_CONFORMANCE` to that `spec/conformance` directory, with conformance required. The complete fast tier passes with independent schema validation enabled. The D84 integration check explicitly distinguishes labelled viewer text from spoken-only search text.

## iOS 18 XCTest logging crash

The full iOS 18.2 leg exposed two simulator-app crashes during ordinary accessibility queries, in the Versions/export flow and a fresh Settings launch. Both crash reports have the same stack: `_platform_strcmp` → `runtime_issue_os_log_fault_callback` in `XCTAutomationSupport` → `__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__`. The faults originate in injected XCTest logging, not app logic; generated app entrypoints appear at the bottom of the main-thread stacks. The failing run captured 123 MB of app-side XCTest query logs.

Only actual iOS 18 UI-test app launches now set `OS_ACTIVITY_MODE=disable`. The two affected flows passed together; their app log fell from 10,871,488 bytes/177 query dumps at the default level to 248 bytes/no query dumps. The complete gate verifies sustained execution. The environment setting leaves production launches, hosted tests and iOS 26+ unchanged.

This intentionally removes unified-log diagnostics, including logging-derived runtime-warning annotations, from the iOS 18 UI-test app process. Test assertions, accessibility audits, stdout/stderr and crash-report collection remain enabled. The test runner’s own logs remain available. [WebKit’s logging-mode reference](https://webkit.org/debugging-webkit/#logging) documents the process-level logging control.
