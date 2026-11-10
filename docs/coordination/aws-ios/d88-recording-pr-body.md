Recording policy ticks and title debounce now use the injected AppClock. The harness advances exact virtual deadlines and controller settle awaits pending title work instead of waiting a fixed interval. Hosted recording composition retains real sleep cadence while keeping shared fake dates/search debounce unchanged.

The title test registers the first 50 ms debounce sleep, advances three 10 ms policy ticks and verifies no persisted title/write. A newer edit must cancel that exact registered sleep. Four more ticks cross the cancelled sleep's old deadline while staying below the replacement deadline; only the final tick releases the replacement write, and only the last title is persisted once.

The policy task captures its clock and interval across suspension, re-acquiring weak self only inside each loop iteration. Controller deinit cancels its policy/title/event tasks. A deallocation test starts recording, executes one policy tick, waits for the next registered sleep, drops the owner and requires immediate controller release plus policy completion/cancelled sleep cleanup. These address both agy fix-first findings.

Inventory PR6 (E7/E8), independent base main c74b57c. Current pushed head `71274c47e98a3c450ead6ec4741021aaaa3822fc`.

Validation:
- Revised recording suites **47/47 passed**, including after restoring all mutations (1.527 s).
- New mutation checks: removing debounce fails the full-50ms registration requirement; removing cancellation fails the cancelled-sleep identity requirement; retaining self before the loop fails the controller deallocation requirement. All restored. Earlier duplicate-title mutation also detected 2 writes versus1.
- Main baseline **3/3** loaded passes retained. Current revised head **3/3** loaded passes (4.152/3.291/3.305 s), exactly6 hogs, AWS mkdir/native locks, no overlapping gate. All hogs exited before full gate.
- Current-head CI **PASSED** (run42871363925). Full status-posting gate **PASSED724s** on clean pushed `71274c47e98a3c450ead6ec4741021aaaa3822fc`: hosted99/7 skipped/0 failures, iPhone102/23 skipped/0 failures, iPad12/0 failures, packages/catalogs green. One iPhone worker/default iPad under AWS/native locks; `drmeyers/test-all` success confirmed. Owned simulators shut down, locks released. Prior573a66c gate763s is historical; this724s run establishes revised-head readiness.

## Checked bug classes
Reference: [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87).
- 1–3: checked; no model/row rebuilding or cache changes. Manual scheduling is test support. The policy's strong controller reference ends before each sleep; explicit after-one-tick deallocation coverage. Hosted graph keeps the search clock's immediate debounce.
- 4–13: not applicable; no word ordering/index identity, chips, search indexing, previews, format/provenance or localized UI text changes.
- 14–16: checked where applicable; new edits cancel the actual registered title sleep, controller teardown cancels timer/event tasks, and sleeping policy cannot retain its owner. Existing recording tests cover storage stops, interruptions, final titles, compression failures and handoff. No data format/protection changes.
- 17: checked; title no-write checks advance exact virtual ticks gated on actual policy progress, then await the final task. Cancellation identity and deallocation are explicit assertions; timeouts only bound hangs. Mutations prove the assertions detect the protected bugs.
- 18: checked; independent branch from main, no draft/failing dependency; normal additional commit after review, no force push.
- 19: checked; exact-head CI and full `CASSINI_POST_STATUS=1 scripts/test.sh all` both green on `71274c47e98a3c450ead6ec4741021aaaa3822fc`.
