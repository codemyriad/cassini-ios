# AWS iOS status — checkpoint at coordinator's 60-minute turn boundary

Updated: 2026-11-10 16:28 UTC
Deadline: this Mac is destroyed after **2026-11-11 12:09 UTC**; push continuously. Coordinator will move the agent to a second Mac.

## Completed
- Inventory PR 2: #84 merged into main c74b57c. Exact-head CI/full gate were green. Its own simulator clones cleaned; original checkout retained as the main worktree (now on main).

## Active — inventory PR 3 / draft PR #85
- Branch `test/d88-draft-growth`, worktree `~/agents/cassini-ios-d88-draft`, pushed clean head **3edd1a785c60725c79b40690a1a284d9d21b3543**, independent base c74b57c. https://github.com/codemyriad/cassini-ios/pull/85
- Implemented permit-driven synthetic draft append URL, injected fake pacing/uptime, optional producer timestamps across async event delivery, positive new-word checks, and Debug-only layout/scroll completion marker. Production timing keeps its prior path unless explicitly injected.
- Five package tests green. Before/after evidence: 3/3 runs of BOTH draft-following and opt-in ScreenshotTests/test03Transcribing passed on each side, 6 hogs/1 fresh boot; AWS and native locks held. All hogs exited. JSON summaries under `~/coordination/evidence/aws-ios-d88-draft/{before,after}-main-locked/` and remote handoff branch.
- Mutations detected: dropping producer timestamps leaves time left Calculating; forced follow after dragging causes final frame 816 to fail required >974. Early negative check was strengthened with real layout/end-geometry acknowledgement. Both mutations restored.
- Exact-head CI GREEN on 3edd1a7. First full gate FAILED after iPad WideScreen runner timeout/restart (1045 s); package tier, hosted 99/7 skipped/0 failures and all iPhone UI passed. Ended only the already-failed owned iPad shard. Failure status posted; PR stays DRAFT.
- Cleaned/recreated only this worktree's clones. Entire isolated WideScreen class then PASSED without source changes; Recording ~3.8 s, Rename ~5.7 s, Saved Voices ~4.9 s, Settings/Trash ~4.3 s. Log `/tmp/d88-draft-wide-isolated.log`.
- **Full-gate retry STILL RUNNING** on unchanged pushed 3edd1a7, under `~/.aws-heavy.lock` plus native test lock. Command: `CASSINI_UI_WORKERS=1 CASSINI_KEEP_SIMS=0 CASSINI_POST_STATUS=1 scripts/test.sh all`. Log `/tmp/d88-draft-full-gate-retry.log`; tool session **12011**; main test.sh PID **96448**, wrapper PID 96439. It acquired the AWS lock and will release it automatically on exit. Do NOT remove that directory while this gate runs.
- Retry hosted suite passed 99/7 skipped/0 failures; package tier green; UI just started at last check (3 iPhone, 2 iPad passes). Inspect completion/status before doing more heavy work. If green and exact-head CI remains green, update PR body evidence and mark #85 ready. Never force-push after ready.

## Prepared — inventory PR 6 (deliver after #85 ready)
- Branch `test/d88-recording-timers`, worktree `~/agents/cassini-ios-d88-recording`, pushed **2365f54** (WIP, NOT COMPILED/TESTED YET), independent base main c74b57c. No PR opened yet.
- Original baseline build passed 45 recording tests; short locked baseline 3/3 passed with 6 hogs, no overlapping gate, all hogs exited. Evidence `~/coordination/evidence/aws-ios-d88-recording/before-locked/`.
- WIP routes policy/title sleeps through parts.clock; settle awaits pending title work; harness advances a manual RecordingTestClock and cancels owned tasks on teardown. Replaces the fixed post-title sleep with event/task completion.
- Hosted TestGraph needs recording-specific real sleeps because its immediate FakeClock would spin an injected policy loop. Added optional AppEnvironment.recordingClock and a hosted RecordingClock forwarding FakeClock dates while retaining real sleeps; ordinary app defaults unchanged.
- Next: compile/run recording package subset, verify hosted composition, second-title-write mutation, 3 locked after runs, push fixes, open draft, CI + full gate green on exact head, then ready. Continue inventory PR 7 after PRs 3 and 6. AWS iOS owns only inventory PRs 3, 6, 7; PRs 8, 9, 10 are assigned to scw-ios on the Scaleway Mac and MUST NOT be started here. Do not wait for coordinator between ready PRs.

## Latest assignment split
AWS iOS owns inventory PRs **3, 6, 7 only**, in that order. PRs **8, 9, 10 belong to scw-ios on the Scaleway Mac**. No branches or implementation work for 8–10 have been started here; do not start them.

## Shared Mac / migration rules
- Atomic mkdir `~/.aws-heavy.lock` around EVERY hog/full gate, rmdir ONLY our acquired directory after owned processes exit. Retain native gate lock. No hogs during another active gate; check non-locking package gates too.
- Exactly 6 hogs, minimum 3 before + 3 after, one fresh boot for simulator evidence. At most 2 booted simulators. No current owned hogs. No foreign jobs/clones touched.
- Remote handoff branch `test/d88-aws-ios-handoff`, files `docs/coordination/aws-ios/`: status, evidence summaries, resumable draft driver. Keep this checkpoint current. Build outputs, models and xcresults excluded; regenerate on second Mac.

## Questions
None pending. Full retry is running; turn ended only to let coordinator's queued inputs land. iOS 18.2 was not installed at last check; verify when needed.
