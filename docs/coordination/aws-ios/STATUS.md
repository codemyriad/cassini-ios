# AWS iOS status — checkpointed, turn ended at coordinator request

Updated: 2026-11-10 15:17 UTC

## Migration deadline
This Mac is destroyed after **2026-11-11 12:09 UTC**, superseding the brief's November 15 date. Push each branch as work proceeds. The coordinator will move this agent to a second Mac beforehand.

## Remote handoff
Branch `test/d88-aws-ios-handoff` contains this status, result summaries and the resumable draft evidence driver under `docs/coordination/aws-ios/`. On the second Mac, recover that branch alongside both working branches. PR #84's description also preserves its validation and mutation evidence. Generated projects, model weights, DerivedData and xcresult bundles must be regenerated; they are excluded from source commits.

## Pushed / ready
- Inventory PR 2: [PR #84](https://github.com/codemyriad/cassini-ios/pull/84), `test/d88-transcript-render`, head 2bedf598a11dc391e996ea594c08d8c300ab6731. Ready for coordinator review; no force pushes.
- Exact-head CI and full local gate green (706 s); drmeyers/test-all success posted. Hosted 99/7 skipped/0 failures; iPhone UI 102/23 skipped/0 failures; iPad UI 12/0 failures; package/string tiers green.
- Render evidence: original 10/10 loaded passes; final after 10/10 hosted/package passes, 3 fresh boots. Initial 120-update cap failed 6/10; 1,024 cap passed with actual 231/241-update warm-ups, keeping three consecutive correct render sets. Idle pair 3.494 s vs 12.603 s. Both mutation checks detected unrelated paragraph invalidation. Evidence: `~/coordination/evidence/aws-ios-d88-render/`.
- Inventory PR 3: empty checkpoint branch `test/d88-draft-growth` pushed, base main e5ff89f; worktree `~/agents/cassini-ios-d88-draft`. No source changes or PR yet. Untouched baseline build passed.

## Stopped / resumable
- PR 3 baseline completed just before stop inspection: 3/3 runs passed BOTH actual tests (draft-following + opt-in transcribing screenshot), 1 fresh boot, 6 hogs. Loads reached 498/560/569. All six owned yes processes exited automatically; verified no yes processes remain. No test/hog run still active.
- Evidence: `~/coordination/evidence/aws-ios-d88-draft/before/`; driver `/tmp/d88-draft-loaded.py`; logs `/tmp/d88-draft-loaded-before.log`, `/tmp/d88-draft-baseline-build.log`. Driver now requires the AWS mkdir lock before spawning hogs and releases it after killing/waiting for its own hogs.
- Next implementation: PR 3 event/clock-driven fake draft growth and pace; remaining inventory PRs 6, 7, 8, 9, 10. Older recording/Parakeet baselines are under `~/coordination/evidence/aws-ios-d88-{recording,parakeet}/before/`.
- Both worktrees clean. Simulators shut down by completed runs; no foreign clones touched. No merges or edits to others' PRs.

## Mandatory shared-Mac rule — latest coordinator update
- Acquire `~/.aws-heavy.lock` using atomic `mkdir` around EVERY hog evidence run AND every full local gate. aws-mac uses the same lock. If occupied, wait without starting work; never remove another holder's directory.
- Release our acquired directory with `rmdir` only after all owned hogs / gate processes exit. Keep the repository's existing test lock as well.
- Never run hogs while another gate is active, including CI gates; check running gates before starting, even after acquiring the AWS lock.
- Latest ceiling: at most 10 hogs. Continue using at most 6, 3 before + 3 after, 1 fresh boot; use only the minimum evidence runs needed. No long or unattended hog batches.
- Do not reuse the legacy unguarded render driver. The draft driver acquires the AWS lock; also check active gates before invoking it. Full gates now require the same outer AWS lock.
- No new run was started for this policy update.

## Blockers / Questions
No active blocker. iOS 18.2 is not installed yet (26.0 and 27.0 available); brief says it is arriving. Awaiting coordinator's queued messages; turn ended as requested.
