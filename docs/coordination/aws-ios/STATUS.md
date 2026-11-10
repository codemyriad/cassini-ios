# AWS iOS status

Updated: 2026-11-10 15:52 UTC
Deadline: this Mac is destroyed after **2026-11-11 12:09 UTC**. Push work continuously; coordinator will move this agent to a replacement Mac.

## Completed
- Inventory PR 2, #84, merged into main c74b57c. Exact-head CI/full gate were green. Its simulator clones cleaned; original checkout is the main worktree, so it is retained.

## Active — inventory PR 3
- Draft [PR #85](https://github.com/codemyriad/cassini-ios/pull/85), pushed head 3edd1a7, branch `test/d88-draft-growth`, worktree `~/agents/cassini-ios-d88-draft`, independent main base c74b57c.
- Locked current-main baseline: 3/3 passes for BOTH draft-following and opt-in transcribing screenshot, 6 hogs/1 fresh boot, holding AWS + native gate locks. Evidence `~/coordination/evidence/aws-ios-d88-draft/before-main-locked/`.
- Implemented injected fake clocks, permit-driven draft append URL, producer timestamps across async delivery, actual new-word checks, and Debug-only real layout/scroll completion marker. Five package tests green; normal targeted UI pair passed.
- Mutations detected: dropped producer timestamps => screenshot time left stays Calculating; forced-follow after drag => final frame 816 failed required >974. The first scroll mutation exposed an early assertion race; layout/end-geometry marker strengthened it. Mutations restored; worktree clean.
- Clean head targeted pair passed again; exact-head CI green on 3edd1a7. Collecting 3 loaded after runs now, exactly 6 hogs and both AWS/native locks held; one fresh boot. Full gate still pending, keep draft.

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
