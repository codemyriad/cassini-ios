# Observational simulator gate

`Simulator gate / Full simulator gate (observational)` runs `scripts/test.sh all` as a GitHub Actions check.
It runs alongside `drmeyers/test-all`; **it does not replace the coordinator's legacy merge gate**.
The first slice keeps every package/hosted/UI assertion and always runs the full iOS 18 leg as well as the default
runtime's phone and iPad tiers. There are no signing, keychain, archive, TestFlight or App Store steps.

## Trust and source

The job is eligible only in `codemyriad/cassini-ios`, for main pushes, manual main dispatches and same-repository
pull requests. The job-level condition rejects forks, missing head metadata and other events before allocating a
self-hosted runner or checking out code. It never uses `pull_request_target`. Both checkouts discard credentials;
the workflow token has only contents-read permission and is not passed to test commands.

This condition protects the normal workflow path, not a runner from a PR that edits workflow YAML to remove it or
add another job. The coordinator confirmed the repository's server-side Actions policy is
`approval_policy=all_external_contributors`: no fork workflow starts on any runner until a maintainer approves it,
including PRs that edit workflow YAML. Keep that approval boundary and never approve a fork for this pool. The job
guard is the second layer: trusted events and a same-repository head are required; forks skip the job rather than
falling back to another runner. A guard truth-table test alone is not proof of backend enforcement. Org runner-group
settings could not be inspected with the available token; no new group/label or permission was created here.

The app checkout is the immutable PR head SHA (the same source the legacy status tested), or the push/dispatch SHA.
Full history supports the existing test script's change detection. Conformance vectors use the same pinned
cassini-format revision as ordinary CI. Xcode 27.0 is selected per process using `DEVELOPER_DIR`, without changing
the machine's global toolchain. Pool hosts need XcodeGen and iOS 27/18.6 simulator runtimes for qualification.
The app deployment target remains iOS 18.0. A PR's check is head evidence, not proof of a future merge SHA.

The iOS 18.6 requirement works around SDK-injected XCTest instrumentation, not an app compatibility change.
iOS 18.2's `XCTAutomationSupport.runtime_issue_os_log_fault_callback` can call `strcmp` with a null subsystem;
the official iOS 18.6 runtime's framework guards that call. Changing only the active Xcode does not replace the
framework loaded from the simulator runtime. Keep the older failures and their diagnostics; do not suppress logs,
remove assertions or count those failures as passes.

Leave `CASSINI_RUNTIME` and `CASSINI_IOS18_RUNTIME` unset. The normal iOS 18 selector chooses the newest installed
18.x runtime; explicit runtime overrides intentionally prevent the legacy script from posting a commit status.
Verify that the qualification log identifies actual iOS 18.6 and full execution before accepting its result.
A host with only 18.2 does not meet this prerequisite. The workflow lists installed runtimes during preflight;
it does not install them or independently enforce the 18.6 prerequisite.

## Capacity and evidence

The verified pool label is `self-hosted, macOS, ARM64, cm-mac-m4`. These runners are registered to this repository
on the rented Macs; this label must never be attached to drmeyers. Serial UI mode bounds this run to one booted
test simulator at a time, including the iPad. On a host with `~/bin/heavy-run`, it acquires a configured host slot
and tells the test script the lock is held; otherwise the script acquires its normal event-driven host lock itself.
The existing resource-admission rules remain active. Runner slots share physical CPU/RAM; an idle runner service
does not imply an idle machine.

Simulator names include the registered runner name, so concurrent services on one host cannot reuse a simulator.
Each service executes one job at a time. Initial and always-run cleanup remove only that service's clones; after
a host crash, its next job cleans the same owned prefix rather than abandoning a new generation of clones.
Cancellation ends this run's build/shard descendants even when a host slot was acquired outside the test script.
Logs and result bundles from both runtime legs
are uploaded on success or failure and retained for seven days, identified by run and attempt. Native step failure
fails the job; no upload retry or test retry is added. This observational workflow adds no automatic cancellation
or pending-run eviction. Cancelling an obsolete run is an explicit action; ordinary CI's existing PR cancellation
policy remains separate.
`CASSINI_POST_STATUS=0` means this job cannot manufacture the legacy status; its token has no statuses-write scope.

## Qualification snapshot (12 November 2026)

The last pushed head, `cd86914`, has green ordinary [CI 43211182033](https://github.com/codemyriad/cassini-ios/actions/runs/43211182033),
but the native [Simulator gate 43211182014](https://github.com/codemyriad/cassini-ios/actions/runs/43211182014) and
its legacy `drmeyers/test-all` status failed. The native job used `scw32-ios-2` with Xcode 27.0 (27A266a),
completed the default phone/iPad tiers, then reported iOS 18.2 Rename assertions with a residual `T` in the field.
Cleanup and artifact upload succeeded; artifact `13944132739` preserves its results. This summary does not assign
the Rename assertion failure to the separate instrumentation crash without its diagnostic evidence.

The branch now includes main `bcb751e`, including its newer Rename keyboard-focus and clear-state checks, brand
checks and unfiltered main-push CI. These merged sources have not yet been qualified by either full gate.
A read-only check of the rented `scw32` host on 12 November found iOS 18.2, 26.0 and 27.0 available, but no 18.6.
The remote runtime prerequisite is therefore unmet on that host. Installing the official runtime under the remote
host's admission lock is separate work; no installation, workflow dispatch or status update is implied here.

Keep this PR draft until the prerequisites are verified and both native and legacy full gates pass on the same
new pushed head. Refresh the PR's qualification narrative with those exact-head results. Earlier green local or
other-PR gates establish neither this branch's result nor the remote pool's runtime configuration.

## One-day comparison, then a separate decision

After merge, compare at least 24 hours of workflow and legacy exact-head results: test counts/coverage in both
runtimes, failures, queue/run durations, resource contention, cancellation cleanup and artifacts. Keep the old
status and merge policy throughout. Any flaky or infrastructure failure needs evidence and the existing D20 policy.
Only the coordinator may approve a later branch-protection/cutover change. UI sharding and iOS 18 cadence changes
are outside this slice. Physical-device testing and release signing/uploads remain on drmeyers.
