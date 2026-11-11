# D82: CI and full-gate profile (2026-11-11)

Measurements are diagnostic, never test pass conditions. Every existing command and assertion remains enabled.

## Ten slowest steps

Ranked by median observed wall time. CI samples are six successful jobs; full-gate samples are two successful runs
on the rented M4/32 GB Mac, with one phone shard plus iPad and the iOS 18 smoke leg. These are different workloads,
so the ranking identifies places to investigate, not an additive prediction. Package tests overlap the default
build in `all`; phone and iPad tests overlap each other. Simulator admission includes waiting for other jobs.

| Rank | Step | Median seconds | Range | Samples |
| --- | --- | ---: | ---: | ---: |
| 1 | Full gate: default-runtime phone + iPad UI | 781 | 753–809 | 2 |
| 2 | Full gate: Swift package lane (beside build) | 158 | 133–183 | 2 |
| 3 | Full gate: iOS 18 smoke UI | 123 | 102–144 | 2 |
| 4 | Full gate: default simulator admission/setup | 122.5 | 34–211 | 2 |
| 5 | CI: string catalogs + Swift packages | 103.5 | 98–118 | 6 |
| 6 | Full gate: build for testing | 96.5 | 52–141 | 2 |
| 7 | CI: harness regressions | 95 | 88–231 | 6 |
| 8 | Full gate: iOS 18 hosted tests including launch | 75.5 | 64–87 | 2 |
| 9 | Full gate: iOS 18 simulator admission/setup | 69 | 7–131 | 2 |
| 10 | Full gate: default hosted tests including launch | 68.5 | 42–95 | 2 |

Full gates: `2957f77e490208bfed991778dec480b172f47754` (#107, 1317 s total) and
`19e7340ccbaf3b49dd0c5d543ae7d30c97fb9f9b` (#110, 1464 s total).
The iOS 18 leg totals (179/368 s) contain hosted, admission and UI steps already represented above and are not
ranked again. Default package-lane elapsed time includes compilation and all package test products.

CI job-step timestamps (one-second precision):
[42976867764](https://github.com/codemyriad/cassini-ios/actions/runs/42976867764),
[42972286291](https://github.com/codemyriad/cassini-ios/actions/runs/42972286291),
[42972232244](https://github.com/codemyriad/cassini-ios/actions/runs/42972232244),
[42972224163](https://github.com/codemyriad/cassini-ios/actions/runs/42972224163),
[42970102285](https://github.com/codemyriad/cassini-ios/actions/runs/42970102285),
[42963881354](https://github.com/codemyriad/cassini-ios/actions/runs/42963881354).
CI build-for-testing is next at 38 s median (37–44 s). Whistle regressions are below timestamp resolution in these
samples; GUI regressions take 1–2 s.
Raw job metadata and full-gate summaries are retained under `~/coordination/evidence/scw-ios-d82/` on the
coordination Mac; the original full-gate evidence is under the model-events/playback-events directories.

## Test-level hotspots

The retained #107 iOS 18 smoke log reports 28.374 s for
`AccessibilityAuditTests.testNoTextIsClippedAtTheLargestTextSize`, 12.388 s for the acceptance walk and 7.244 s for
the unavailable-recognizer flow. The #106 default-runtime logs (a separate 16 GB host, not included in the table)
report 69.029 s for the iPad screen audit and 40.834/36.852/33.174 s for largest-text/Portuguese/French clipping
audits. These exercise different screen, locale and accessibility coverage; their cost alone does not justify
removing them. Launch/navigation costs are included in test durations. Future UI work should measure shared setup
and shard balance while retaining every audit; the current change targets the measured CI serial dependency.

## Change

Run harness regressions in a separate CI job alongside package tests and the build. The harnesses use temporary
fixtures and fake tool invocations; they do not consume the package build or simulator outputs. Both jobs retain
normal failure propagation and the workflow's PR cancellation rule. The package job keeps Xcode 27.0 selection,
required conformance vectors, string validation, package tests, simulator build, embedded-minimum-OS checks and
failure artifacts. All seven Python regression scripts move together to the harness job, with the same arguments
and conformance environment. No retries, assertions, timeouts or test lists change.

This removes a serial dependency, not CPU work. It costs one extra checkout and requires an available runner for
the second job; with one runner the jobs queue and there is no latency benefit. The simulator full gate and its
`drmeyers/test-all` requirement remain unchanged. UI scheduling is already owned by #54 and is outside this PR.

## Controlled recipe comparison

Pending measurement on the rented Mac: warm the package/build caches, then alternate the original serial recipe
and the same seven scripts beside the package/build lane. A heavy-run slot encloses each measurement. Record every
command exit and per-step elapsed time; use no elapsed-time assertions. This isolates scheduling from runner queue
and checkout time; actual CI job results provide the end-to-end check.
