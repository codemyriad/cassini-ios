# AWS iOS status

Updated: 2026-11-10 18:18 UTC.
**#91 agy fix-first findings FIXED; READY again on71274c4 with exact-head CI/full gate green. #92 MERGED.** Assigned inventory3/6/7 complete to merged/ready. Refreshed main audit found no additional engine/package conversion beyond E7/E8 in ready #91.

Mac destruction deadline: **2026-11-11 12:09 UTC**. All useful source/evidence/docs are pushed. Handoff branch `test/d88-aws-ios-handoff`, directory `docs/coordination/aws-ios/`. Build products, models, recordings, generated projects and xcresults excluded.

## Inventory6 / #91 — READY AGAIN, coordinator review/merge pending
- https://github.com/codemyriad/cassini-ios/pull/91
- Clean PUSHED exact head **71274c47e98a3c450ead6ec4741021aaaa3822fc**, normal additional commit (no force push). Branch `test/d88-recording-timers`, worktree `~/agents/cassini-ios-d88-recording`. Independent base main c74b57c. PR put back to draft for agy fixes, then ready only after new CI + full gate green.
- Review1 FIXED: title test registers50ms sleep, checks no write after10/20/30ms policy ticks, edits again and verifies cancellation of that sleep ID. Crosses old50ms deadline with no write through70ms; at80ms only the replacement title writes, once. Clock stores exact Duration deadlines, cancellation IDs; wait helpers can observe events without auto-advancing time.
- Review2 FIXED: policy captures only clock/interval across suspension, re-acquires weak self inside each loop iteration; deinit cancels policy/title/event tasks. Lifetime test executes a policy tick, waits for the next registered sleep, drops owner, requires controller deallocation and cancelled policy completion.
- Revised recording suites **47/47 passed**, restored1.527s. Mutations detected: bypass debounce (sleep count0 vs1), remove cancellation (old ID not cancelled), retain self across loop (deallocation failure). All restored. Earlier duplicate-title mutation detected2 writes vs1.
- Main baseline **3/3** loaded passes retained. Revised exact-head after **3/3 passed** (4.152/3.291/3.305s),6 hogs, AWS/native locks, no overlapping gate. All hogs exited before full gate. Evidence `evidence/recording/after-agy-fix/` on handoff branch.
- Current-head CI **SUCCESS**, run42871363925; full gate **PASSED724s**, drmeyers/test-all SUCCESS. Hosted99/7 skipped/0 failures, iPhone102/23 skipped/0 failures, iPad12/0 failures, packages/catalogs green. One iPhone worker/default iPad, AWS/native locks. Log `/tmp/d88-recording-agy-full-gate.log`. Gate exited, own sims shut down, locks released. Body/D87 checklist updated before ready. Prior573a66c gate763s is historical only.

## Completed / cleanup
- Inventory2 / #84 merged, own clones cleaned, primary checkout retained on main.
- Inventory3 / #85 merged, head3edd1a7, CI/full retry680s green, loaded before3/3 and after3/3, two mutations detected. Own clones cleaned, merged worktree removed/pruned.
- Inventory7 / **#92 MERGED** as dac3495 into main. Head `a8bd214e2488e0dd92f051179b1eec9fe2c98123`, branch `test/d88-parakeet-clocks` pushed. Suite22/22; decode cancellation gate/count-before-release, virtual nanoTime exact cumulative sums. Cancel and timing mutations detected/restored. Before3/3 and after3/3 loaded,6 hogs/both locks/no overlap. CI run42865585963 and exact-head full gate729s green before ready, hosted99/iPhone102/iPad12 with no failures. Own clones cleaned with test.sh clean, merged worktree removed/pruned at18:16. Historical logs `/tmp/d88-parakeet-full-gate.log`; summaries remote.

## Follow-up fresh main audit — refreshed, complete
- Fetched clean main **711606f56e9daaf5b5ae1673966450bdd2302506** at18:16; includes merged #92 and #89 artifact request retry. Primary checkout now on that main revision.
- Report `docs/coordination/aws-ios/WALL-CLOCK-AUDIT-2026-11-10.md`, package timing candidates and extended semaphore/timer candidates pushed on handoff branch.
- Remaining main engine/package D88 cases are only E7/E8 in ready #91. P1/P2 are now fixed on main by merged #92. **No additional conversion found.** New ArtifactRequestRetryTests inject synchronous errors/responses; no real timeout/network/clock. Other candidates are positive event polling, release/cancel gates and hang bounds, fixed date/media inputs, CPU/scaling checks or report-only diagnostics.
- Inventory8/9/10 remains scw-ios on Scaleway. No code/branch for those started here. Never touch others' PRs. Re-scan after later main merges.

## Shared sources / execution rules
- Shared decisions/contracts/vectors/strings/design/bug classes sourced from codemyriad/cassini-ux main. D87/D88 and review/BUG-CLASSES.md read at1e8a722; PR bodies cite it. No vendored vectors/strings changed here. Re-pin to cassini-ux at a commit when next touched; propose shared edits to coordinator, do not edit local shared copies. Coordination repo keeps status/briefs/reviews/evidence only.
- No owned hogs or gate active. At most2 booted sims during gates; owned sims shut down afterwards. No foreign processes/clones touched.
- Atomic mkdir `~/.aws-heavy.lock` around EVERY hog/full gate; rmdir only own acquired directory after owned children exit, retain native lock too. Exactly6 hogs,3 before+3 after; one fresh simulator boot when relevant. No hogs during any other gate. Saved package-evidence.py stops owned hogs/test immediately if a foreign gate starts; draft-loaded.py preserves UI evidence driver.
- Ready requires clean pushed head, exact-head CI plus `CASSINI_UI_WORKERS=1 CASSINI_KEEP_SIMS=0 CASSINI_POST_STATUS=1 scripts/test.sh all` green. No force pushes; never merge ourselves. After coordinator merges #91, clean only its worktree's clones, remove worktree, prune.

## Questions
None. Both agy findings addressed and #91 ready again; assigned inventory and follow-up audit complete. Coordinator review/merge of #91 pending.
