# AWS iOS status

Updated: 2026-11-10 15:36 UTC
Deadline: this Mac is destroyed after **2026-11-11 12:09 UTC**. Push work continuously; coordinator will move this agent to a replacement Mac.

## Completed
- Inventory PR 2, #84, merged into main c74b57c. Exact-head CI/full gate were green. Its simulator clones cleaned; original checkout is the main worktree, so it is retained.

## Active — inventory PR 3
- Worktree `~/agents/cassini-ios-d88-draft`, branch `test/d88-draft-growth`, fast-forwarded to main c74b57c before implementation.
- New baseline from that main: 3/3 runs passed both draft-following and opt-in ScreenshotTests/test03Transcribing, 6 hogs, one fresh boot, holding BOTH ~/.aws-heavy.lock and the native gate lock. Hogs exited; no run still active. Evidence: `~/coordination/evidence/aws-ios-d88-draft/before-main-locked/`.
- Implemented pending validation: injected fake pacing clock, permit-driven draft append URL, positive new-sentence checks after dragging, virtual uptime and optional producer timestamps across async queue delivery. Production event timestamps remain unchanged unless explicitly injected.
- Added package checks for exact permitted growth, cancellation while waiting, exact virtual pace and queued progress samples. Package subset passed; targeted UI/mutation checks, 3 loaded after runs, exact-head CI and full gate remain in progress.
- Pushed c97404c; draft PR #85: https://github.com/codemyriad/cassini-ios/pull/85 . Five package checks green; targeted UI build green and virtual-time screenshot passed. Draft-following words were not found by the inherited section label; verifying a direct word query now. CI/full gate and 3 loaded after runs remain pending. Source selector adjustment pending its UI result.

## Next
Continue inventory PRs 6, 7, 8, 9, 10 IN ORDER, independent main-based branches, no waiting for coordinator between ready PRs.

## Shared Mac rules
- Atomic mkdir ~/.aws-heavy.lock around EVERY hog or full gate, rmdir only our acquired directory after owned processes exit. Retain native test lock too. No hogs during another active gate.
- Exactly 6 hogs; minimum 3 before + 3 after, 1 fresh boot. No long unattended batches. At most 2 booted simulators.
- Mark ready only when CI and CASSINI_POST_STATUS=1 scripts/test.sh all are green on exact pushed head. Never force-push after ready; never merge.

## Remote handoff
`test/d88-aws-ios-handoff` preserves status, evidence summaries and the driver under docs/coordination/aws-ios. Update it at checkpoints. Generated projects, weights, build products and xcresults stay out of commits.

## Blockers / Questions
None. iOS 18.2 was not installed at last check; verify when needed. No messages sent to others or edits to others' PRs.
