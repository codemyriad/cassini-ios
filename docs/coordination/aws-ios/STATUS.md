# AWS iOS status

Updated: 2026-11-10 17:44 UTC.
**Assigned inventory list FINISHED: 3 merged as #85; 6 and 7 READY as #91/#92.** Follow-up fresh-main audit completed; no additional engine/package wall-clock conversion found beyond these two ready PRs.

Mac destruction deadline: **2026-11-11 12:09 UTC**. All useful work is pushed. Remote handoff: branch `test/d88-aws-ios-handoff`, directory `docs/coordination/aws-ios/`, including STATUS, resume notes, evidence summaries/drivers and fresh audit report. No build products/models/recordings/xcresults committed.

## Completed
- Inventory2 / #84 merged, exact-head CI/full gate green, own clones cleaned. Primary checkout retained on main.
- Inventory3 / #85 merged at head3edd1a7. Permit-driven draft growth and uptime, producer timestamps, layout/end-geometry acknowledgement. Loaded before3/3 and after3/3 (both draft-follow and screenshot), 6 hogs/fresh boot/both locks. Dropped-timestamp and forced-follow mutations detected. Full retry680s green, exact-head CI green; initial iPad timeout resolved with own fresh clones and isolated WideScreen check. Own clones cleaned, merged worktree removed and pruned.

## Inventory6 / #91 — READY, awaiting coordinator review/merge
- https://github.com/codemyriad/cassini-ios/pull/91
- Clean PUSHED head `573a66c21a5f55b91ba37cc59b9950e0392210dc`, branch `test/d88-recording-timers`, worktree `~/agents/cassini-ios-d88-recording`. Independent main c74b57c base, no draft dependency. Never force-push after ready.
- Policy/title sleeps use AppClock; settle awaits title task; manual harness drives registered deadlines/cancels owned tasks. Hosted recording-specific clock retains real sleep cadence while shared FakeClock dates/search debounce stay unchanged.
- Package46/46 current head, hosted subset11/11 on preceding head with identical production changes. Duplicate stale-title mutation detected (2 writes vs1), restored. Baseline3/3 and final after3/3 loaded green with6 hogs/both locks/no overlap. Older partial2-run batch retained separately and not counted for final head.
- CI run42860564858 SUCCESS and exact-head full gate **PASSED763s**, drmeyers/test-all SUCCESS. Hosted99/7 skipped/0 failures, iPhone102/23 skipped/0 failures, iPad12/0 failures, packages/catalogs green. Body and D87 checklist updated before ready. Log `/tmp/d88-recording-full-gate.log`.

## Inventory7 / #92 — READY, awaiting coordinator review/merge
- https://github.com/codemyriad/cassini-ios/pull/92
- Clean PUSHED head `a8bd214e2488e0dd92f051179b1eec9fe2c98123`, branch `test/d88-parakeet-clocks`, worktree `~/agents/cassini-ios-d88-parakeet`. Independent main c74b57c base. No force pushes.
- Native decode signals started and holds until test releases; cancel/capture count happen before release, final count must match (no assumption of exactly1 decode per window). Injected nanoTime advances20ms per decode; exact cumulative window/result sums replace real delays.
- Suite22/22 passed after both mutations restored. Ignored cancel flag fails3 decodes vs captured1 and missing CancellationError; cumulative assignment fails80ms vs expected640ms. Selected observations1.343s versus baseline1.497s are not pass conditions.
- Before3/3 and after3/3 loaded green with6 hogs/both locks/no overlap. First after attempt stopped immediately on foreign gate start, zero runs counted; all owned hogs exited.
- CI run42865585963 SUCCESS, exact-head full gate **PASSED729s**, drmeyers/test-all SUCCESS. Hosted99/7 skipped/0 failures, iPhone102/23 skipped/0 failures, iPad12/0 failures, packages/catalogs green. Body/checklist updated before ready. Log `/tmp/d88-parakeet-full-gate.log`.

## Follow-up audit — completed
- Freshly fetched clean main **dba4afae94b36df57819c8e695276b3654af1bb4**, including all merged D88 changes through #85. #91/#92 were still open ready at scan time; report explicitly accounts for their unmerged conversions.
- `docs/coordination/aws-ios/WALL-CLOCK-AUDIT-2026-11-10.md` on handoff branch records scope, reproduction commands,56 package timing candidate lines, remaining known cases and reasons for exclusions.
- Remaining main engine/package violations are E7/E8 in ready #91 and P1/P2 in ready #92. **No additional conversion found.** Other matches are positive event polling, cancelable holds/hang guards, fixed input dates/media lengths, thread CPU/scaling checks, or report-only diagnostics.
- UI absence/playback/helper work (inventory8/9/10) remains scw-ios on Scaleway. No code or branch for those was started here. Re-scan main after further merges change its revision.

## Shared sources and Mac rules
- Shared decisions/contracts/vectors/strings/design/bug classes now sourced from **codemyriad/cassini-ux main**, read D87/D88 and review/BUG-CLASSES.md there at1e8a722. PR bodies cite it. No vendored strings/vectors touched; re-pin to cassini-ux at a commit when next touched. Propose shared changes to coordinator, never edit local shared copies. cassini-coordination keeps briefs/status/reviews/evidence only.
- No owned hogs or gate active. Both gates shut down owned simulators and released locks. At most2 booted simulators while running. No foreign processes/clones touched.
- Atomic mkdir `~/.aws-heavy.lock` around EVERY hog/full gate; rmdir only our acquired directory after owned processes exit; retain native lock. Exactly6 hogs,3 before+3 after, one fresh simulator boot when relevant. Never hog during another gate. Saved `package-evidence.py` monitors foreign gate starts and immediately stops owned hogs/test; `draft-loaded.py` preserves UI evidence driver.
- Before marking ready: clean pushed head, exact-head CI plus `CASSINI_UI_WORKERS=1 CASSINI_KEEP_SIMS=0 CASSINI_POST_STATUS=1 scripts/test.sh all` green under AWS/native locks. After #91/#92 merge, clean only that worktree's clones, remove its worktree, prune. Never merge PRs ourselves.

## Questions
None. Assigned inventory and follow-up audit are complete. No additional engine/package code changes remain from this scan; coordinator review/merge of ready #91/#92 is pending.
