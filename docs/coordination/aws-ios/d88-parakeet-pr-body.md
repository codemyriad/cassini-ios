Parakeet package tests now cancel while a native decode is held at an explicit gate. The fixture signals when decode starts; the test cancels, captures the decode count, then releases the gate and verifies that no later decode starts. It permits multiple speech spans per window.

An injected monotonic nanoTime (defaulting to DispatchTime uptime) lets the decode fixture advance exactly 20 ms per native call. The inference-time test checks exact cumulative sums for each published window and the final result, without real decode delays. This is inventory PR 7 (P1/P2), independent from main c74b57c.

Validation:
- ParakeetTranscriberTests: **22/22 passed**, including after restoring both mutations (3.102 s). Selected converted tests 1.343 s versus baseline 1.497 s; these observations are not pass conditions.
- Before: **3/3** loaded runs passed on pristine c74b57c, exactly 6 hogs and both AWS/native locks, no overlapping gate. Final after evidence pending until the recording gate finishes.
- Cancellation mutation: ignoring CancelFlag.set() makes the final decode count **3 versus captured 1**, and returns a result instead of CancellationError. Restored.
- Timing mutation: replacing cumulative addition with assignment produces **80 ms versus expected 640 ms**. Restored.
- Exact-head CI/full gate pending; remain draft until both green.

## Checked bug classes
Reference: [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87).
- 1–3: checked; same linear inference path, no model/row rebuilding or cache changes. Only the time source is injectable; default remains monotonic uptime. Gate blocks the dedicated inference thread, never the Swift cooperative pool.
- 4–14: not applicable; no ordering/index/chip/search/preview/format/provenance/localization/download completion changes.
- 15–16: checked where applicable; cancellation test verifies CancellationError and recognizer release, and its defer releases the native gate on failure. No persistence/protection changes. Existing package tests cover partial and failed model preparation.
- 17: checked; decode starts/release are actual events; timing assertions use exact virtual nanoseconds. One-minute test limit and release polling bound are hang guards only.
- 18: checked; independent branch from main, no draft/failing dependency.
- 19: pending exact-head CI and full status-posting gate.
