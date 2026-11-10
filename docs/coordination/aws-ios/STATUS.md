# AWS iOS status

Updated: 2026-11-10 17:11 UTC — checkpoint, turn ending for queued inputs.
Mac destruction deadline: **2026-11-11 12:09 UTC**. Push continuously; remote handoff branch `test/d88-aws-ios-handoff` contains this status, resume notes, evidence summaries and drivers.

## Assignment
AWS iOS owns inventory **3, 6, 7 only**, in order. **8, 9, 10 belong to scw-ios on Scaleway; do not start them.** Continue between PRs without waiting for coordinator; never merge PRs.

## Completed
- Inventory 2: PR #84 merged; exact-head CI/full gate passed. Own clones cleaned.
- Inventory 3: PR #85 MERGED, head `3edd1a785c60725c79b40690a1a284d9d21b3543`. Exact-head CI and full gate green before ready; full retry 680 s, hosted 99/7 skipped/0 failures, iPhone 102/23 skipped/0 failures, iPad 12/0 failures. Initial iPad timeout resolved after recreating own clones, isolated WideScreen class and entire gate passed without source change. Locked before/after 3/3 each (both draft-follow and screenshot test), 6 hogs, fresh boot. Timestamp-drop and forced-follow mutations detected. Own clones cleaned and merged worktree removed/pruned at this checkpoint.

## Active — inventory 6 / draft PR #91
- https://github.com/codemyriad/cassini-ios/pull/91
- Branch `test/d88-recording-timers`, worktree `~/agents/cassini-ios-d88-recording`, clean and PUSHED exact head `573a66c21a5f55b91ba37cc59b9950e0392210dc`, independent base c74b57c. origin/main now dba4afa; fetch/inspect and integrate if appropriate before final validation.
- Routes policy/title sleeps through injected AppClock; settle awaits title work; deterministic harness advances registered sleeps and cancels owned tasks on teardown. Hosted graph retains real recording sleep cadence with its separate override. Added test proving policy registers an injected sleep before refreshing elapsed.
- Package **46/46 passed** at current head. Hosted recording/library **11/11 passed** on preceding 2365f54 (same production changes). Extra-title-write mutation failed clearly (2 writes versus 1); restored.
- Baseline main c74: **3/3 locked loaded runs passed**, 6 hogs. Initial after at older 2365f54: 2 valid passes; watcher detected foreign gate during third and immediately stopped all owned hogs/test. Preserved as partial evidence, not final proof for new head.
- Final current-head loaded batch `after-final` still pending: first attempt refused busy AWS lock without starting hogs. Run 3 current-head repetitions only when no CI/local gate is active, using saved package driver.
- CI run **42860564858 pending** at checkpoint (old 2365 CI passed). Full gate NOT YET RUN on 573. Stay draft until exact-head CI and status-posting full gate green; update PR body with final counts and Checked bug classes, then ready.
- Logs: `/tmp/d88-recording-clock-gate.log`, `/tmp/d88-recording-hosted.log`, `/tmp/d88-recording-mutation.log`. PR body draft `/tmp/d88-recording-pr-body.md` still needs final evidence updates.

## Prepared — inventory 7 (no edits or PR)
- Branch `test/d88-parakeet-clocks` PUSHED at c74b57c, pristine worktree `~/agents/cassini-ios-d88-parakeet`. Baseline selected two tests built/passed. **New-policy 3 locked before runs still needed before editing/building new code.** Historical 10-run baseline predates revised policy.
- Convert cancellation test to explicit native decode started/release gate; capture decode count BEFORE release, assert no later decode, never assume exactly one decode per window. Inject monotonic nanoTime into ParakeetTranscriber and nested Run, advance fake time per decode, assert exact cumulative sums. Remove decodeDelay sleeps. Mutate cancellation flag and cumulative timing to prove checks, restore, validate after 3 runs, CI and full gate. Deliver only after #91 ready.

## Resume / shared Mac rules
- No own hogs or gate running at checkpoint. AWS lock absent at last check. Do not remove another owner's lock.
- Atomic `mkdir ~/.aws-heavy.lock` around EVERY hog or full gate; `rmdir` only our acquired directory after all owned children exit. Retain native `~/.cassini-heavy.lock` too. Exactly **6 hogs, 3 before + 3 after**, one fresh simulator boot when relevant. At most 2 booted simulators. No hogs during any other gate, including non-locking package CI.
- `package-evidence.py` acquires both locks, checks foreign gates and immediately stops owned hogs/test if another gate begins. Run from relevant worktree: `python3 /tmp/aws-ios-package-evidence.py recording after-final 'RecordingControllerTests|RecordingScreenModelTests'`; for pristine Parakeet baseline use `parakeet before-locked 'aCancelStopsBeforeTheNextNativeCall|theInferenceTimeIsEachWindowsDecode'`. Copy saved driver to /tmp after migration. Resumes same-head valid rows; never overwrite other-head evidence.
- Full gate: push clean head, acquire AWS lock, run `CASSINI_UI_WORKERS=1 CASSINI_KEEP_SIMS=0 CASSINI_POST_STATUS=1 scripts/test.sh all`, release own AWS lock on exit. Require CI + drmeyers/test-all success on same head before ready. Never force-push ready PRs.
- No source work for inventory 8–10. Build outputs, models, recordings, generated Xcode projects and xcresults excluded from Git. Only synthetic audio fixtures. Primary checkout remains on main; fetch before use.

## Questions
None. Checkpoint complete; ending turn for queued coordinator inputs.
