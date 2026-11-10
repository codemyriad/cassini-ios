Recording policy ticks and title debounce now use the injected AppClock. The recording harness advances to registered sleep deadlines while waiting for actual controller events; the debounce check awaits the pending title task instead of sleeping for twice the debounce interval. Controller settle includes pending title work, and fixture teardown cancels its owned timer/event tasks.

App composition permits a recording-specific clock. Hosted TestGraph forwards its fake dates while keeping the prior real sleep cadence, preventing its immediate-return search clock from spinning the policy loop. Ordinary app defaults are unchanged.

Inventory PR 6 (E7/E8), per ~/coordination/IOS-D88-INVENTORY.md and coordinator answers. Independent base main c74b57c.

Validation:
- Current pushed head `573a66c21a5f55b91ba37cc59b9950e0392210dc`: **46/46** recording package tests passed, including the new check that a policy tick registers on the injected clock before refreshing elapsed.
- Main baseline: **3/3** loaded runs passed (45 tests each). Final head: **3/3** loaded runs passed (46 tests each), 4.717/3.334/3.315 s. Exactly 6 hogs, AWS mkdir and native locks held, no overlapping gate. Earlier partial after batch is retained separately and not counted for this head.
- Hosted RecordingTests + LibraryScreenTests: **11/11** passed on the preceding head with identical production changes.
- Mutation: inserting an extra stale-title write before the correct debounced title fails with titleWrites **2 versus 1**; restored.
- CI **passed** on exact head (run 42860564858). Full local status-posting gate is running under the AWS/native locks, one iPhone worker and default iPad coverage. Remains draft until it passes.

## Checked bug classes
Reference: [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87).
- 1–3: checked; no model/row rebuilding or cache changes. Manual scheduling lives in test support; recording composition preserves the hosted search clock's immediate debounce (LibraryScreenTests green).
- 4–13: not applicable; no word ordering, identity/index mapping, chips, search indexing, previews, format/provenance or localized UI text changes.
- 14–16: checked where applicable; cancellation ends a sleeping policy/title task, and fixture teardown cancels owned waiters. Existing recording tests cover storage stops, interrupted capture, final titles, compression failures and handoff. No data format or protection changes.
- 17: checked; title persistence is gated on task completion; policy tests drive virtual deadlines and assert real state changes. Poll timeouts are hang bounds only, with no wall-clock pass conditions.
- 18: checked; independent branch from main, no draft/failing dependency.
- 19: pending; keep draft until CI and CASSINI_POST_STATUS=1 scripts/test.sh all are green on the exact pushed head.
