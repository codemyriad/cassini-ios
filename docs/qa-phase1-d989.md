# Phase 1 iOS QA (D-989)

Audit baseline: `0fc91b17ce8a53130d1c52ae74597902b0394482` (main).
Shared contracts: cassini-ux `994967ead64e1adc8e75774ca1455823d2c8ef3b`;
app token/catalog receipts remain at their existing immutable pins.

This audit separates regressions in merged code from implementation work already assigned to open Phase 1 PRs.
It does not certify the unmerged implementations. Recheck those surfaces after their own review and merge.

| Surface | Baseline finding | Disposition |
| --- | --- | --- |
| Library | Finished rows still have a Transcribed chip and quote; speaker and bookmark counts lack the final pill anatomy. | Existing WP2 [#145](https://github.com/codemyriad/cassini-ios/pull/145), D-954. |
| Search | Search and the Saturn mark are not yet in the pinned top capsule; result heading and snippets need the WP2 layout. | Existing WP2 #145. Preserve snippets in search and existing filters (L-34/L-35 remain open). |
| Meeting | One-step open, inline speakers, Find, speed-left/bookmark-right player, and scrolled title are implemented. Header speaker names use ink while their dots and transcript labels use the assigned speaker colour. | Fix the header names to use the same speaker tint (BRAND, HARMONY 10.10). Keep unnamed stone and existing rename targets. |
| Recording | Forced dark brand ground and waveform are present. Final Stop/All meetings/Pause layout and terminology are pending. | Existing WP4 [#146](https://github.com/codemyriad/cassini-ios/pull/146), D-960. |
| Transcribing | Live draft is present; the expanded processing card has not yet become the compact status line/details sheet. | Existing WP5 [#148](https://github.com/codemyriad/cassini-ios/pull/148), D-964. |
| Name a speaker | Native sheet, sample, saved voices and remember control are present. Final neutral duplicate notice and single-column layout are pending. | Existing WP6 [#147](https://github.com/codemyriad/cassini-ios/pull/147), D-968. |

## Contract boundaries

- Both system appearances use the pinned brand roles, including six named speaker slots repeating after six and stone before naming. Recording deliberately stays dark.
- iOS keeps Dynamic Type, native glass on iOS 26+, material fallback on iOS 18, bookmarks, Live Activity, and the existing export formats. Desktop-only chrome, export restrictions and Imported rename do not apply to phones (L-10 is open).
- No catalog or vector copy is edited. The speaker-name correction changes neither names nor speaker identity, ordering, timings, persistence or recording lifecycle.
- Bug classes 1–12 and 14–16 have no changed rule/data path; #13 uses the existing localized names; #17 uses the existing polling screenshot helpers; #18 branches directly from green main; #19 requires exact-head CI and the local full gate before readiness.

## Evidence

Use `scripts/screenshots.sh --device iphone --output qa/d989/before` on the baseline and the same command with `after` on the corrected head. The named seeds cover Library, Search, Meeting, Recording, Transcribing and Name a speaker in light and dark, plus seven speakers, Find and the compact title. `15-seven-speaker-meeting` is the direct regression comparison: unnamed stone, six named colours, and the first named colour repeating in the transcript.

Generated images and build outputs stay out of git. The before/after comparison boards are attached to D-989; validation results and the exact audited head are recorded in the PR.
