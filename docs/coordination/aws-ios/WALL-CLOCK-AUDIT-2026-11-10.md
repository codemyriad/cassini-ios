# Fresh D88 audit — 2026-11-10

Scanned clean `origin/main` **dba4afae94b36df57819c8e695276b3654af1bb4**, fetched again after inventory 6 and 7 reached ready. This includes merged D88 PRs through #85. **#91 and #92 are ready, not merged at the scan time.** They account for all remaining engine/package violations found on this main revision. No additional engine/package conversion was found.

Rule source: cassini-ux main, `decisions/DECISIONS-UX.md` D88 and `review/BUG-CLASSES.md` class17 (read at commit 1e8a722060c3f014c67fa4eff13c454307cc31ea). Shared files were read, not edited. No vendored vectors/strings changed, so their pin is outside this change.

## Remaining on main, already converted in ready PRs

| Case | Main source | Conversion |
| --- | --- | --- |
| E7 title persistence | RecordingControllerTests.swift:77 fixed debounce ×2 sleep | #91 awaits pending title work |
| E8 recording policy/title scheduling | RecordingController+Capture.swift:12,66 uses real sleeps; RecordingHarness uses those timers | #91 routes sleeps through AppClock and advances registered deadlines; explicit injected-policy registration test |
| P1 cancellation inside native decode | ParakeetTranscriberTests.swift:99,650 uses 0.3 s fake decode delay | #92 signals decode started, cancels while held, captures count before release, asserts no later decode |
| P2 cumulative decode time | ParakeetTranscriberTests.swift:252 uses 20 ms real decode delays and lower-bound timing assertions | #92 advances injected nanoTime exactly per native call and checks cumulative sums |

#91 head573a66c: package46/46, hosted subset11/11, mutation2 title writes versus1 detected; loaded before3/3 and after3/3; exact-head CI and full gate763s green.
#92 heada8bd214: suite22/22, both mutations detected (cancel3 decodes versus captured1; sum80ms versus640ms); loaded before3/3 and after3/3; exact-head CI and full gate729s green.
Both full gates: hosted99/7 skipped/0 failures, iPhone102/23 skipped/0 failures, iPad12/0 failures. Evidence used6 hogs and both locks with no overlapping gate. An interrupted Parakeet attempt counted zero runs.

## Other timing candidates reviewed

- Positive event polling in RecordingHarness, RecordingScreenModelTests, QueueHarness, TranscriptionJobHarness, NativeBudgetTests, PlaybackControllerTests, LibraryStoreTests, ModelInstallsTests, ModelTestSupport and FakeJobRunner: predicates determine success; elapsed bounds only fail a hang. Poll sleeps do not stand in for completion.
- FakeCheckpoints/FakeAudioProcessing wait for explicit release flags. Scripted/windowed transcriber holds and ModelInstallerTests terminate by cancellation; 30s/60s values are hang bounds, not successful elapsed intervals. FakeTranscriber frozen/downloading/growing terminal holds never complete by their 3600s sleep.
- Parakeet model-verification cancellation test and waitUntil helper: positive start/release/cancel events with outer hang bounds. No elapsed-time assertion.
- FakeClock is virtual; FixedClock is an app/UI launch adapter retaining real cadence. FakeCapture has synthetic waveform pacing in hosted/UI graphs, but is not used by package test assertions. Its elapsed audio is not a performance budget. No package test depends on a fixed number of those real ticks.
- PlaybackControllerTests' 1850–2000ms position range is driven synchronously by ManualTicker and SessionPlayback, not host time. TranscriptionJob inference/elapsed assertions use ManualUptime or scripted window totals.
- TurnModelLongTranscriptTests, Export/LongExportTests and LibraryScalingTests use calling-thread CPU time/scaling. ThreadCPUTime.swift calls CLOCK_THREAD_CPUTIME_ID; scheduler delay is excluded.
- LongRunMeasurementTests and hosted smoke/benchmark tests print wall-time observations without performance assertions. They are opt-in diagnostics.
- CAF repair, file reader, imports, VoiceClipCache and recording recovery duration assertions inspect generated media/sample data. Date fixtures, TrashUndo's captured instant, export sweep's supplied future instant, and CheckpointState's explicitly changed modification timestamp are data inputs.

## Hosted/UI/scripts scope

Freshly searched hosted tests, UI helpers/callers and Python test scripts as well. Hosted polling uses positive conditions with outer hang guards; benchmark wall-time readings are report-only. UI negative absence checks, playback position races and helper retry/settle deadlines from inventory8/9/10 remain scw-ios's assignment. They were not edited or duplicated here. Main's draft-growing case is already fixed by merged #85. Script test timeouts are hang guards / stubbed timeout contracts following merged inventory11.

## Reproduction

Use `git fetch origin`, then a clean main checkout at the recorded revision. Search all Swift files under Packages, including EngineTesting fixtures:

```sh
rg -n 'Task\.sleep|Thread\.sleep|usleep\(|asyncAfter|DispatchTime|ContinuousClock|CFAbsoluteTime|CACurrentMediaTime|timeIntervalSinceNow|timeIntervalSince\(' Packages --glob '*.swift'
rg -n 'wait\(for:|waitForExpectations|XCTWaiter|measure\(' Packages --glob '*.swift'
rg -n '#expect\(.*(Date|Clock|Nanosecond|nanosecond|elapsed|seconds|duration|inferenceMs)' Packages --glob '*.swift'
rg -n 'Date|timeInterval|deadline|sleep|waitFor|poll\(|staysAbsent|monotonic|perf_counter' CassiniTests CassiniUITests scripts
```

Read each candidate's clock/data producer and assertion; textual matches alone do not establish a D88 violation. The saved package candidate list contains56 matching source lines at this revision. Audit was read-only; it required no extra hog runs or test gate. Re-scan after further merges change main; this report does not claim unmerged branches are present on main.
