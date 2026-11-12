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
add another job. **Before enabling the new workflow on the public pool, confirm server-side fork exclusion** that
PR code cannot change (for example an administratively enforced runner policy). Repository API access currently
denies inspection of that policy; the draft stays blocked on coordinator confirmation. Existing CI's editable
guards have the same limitation. Do not treat a passing guard truth-table test as proof of backend enforcement.

The app checkout is the immutable PR head SHA (the same source the legacy status tested), or the push/dispatch SHA.
Full history supports the existing test script's change detection. Conformance vectors use the same pinned
cassini-format revision as ordinary CI. Xcode 27.0 is selected per process using `DEVELOPER_DIR`, without changing
the machine's global toolchain. Pool hosts must already have XcodeGen and iOS 27/18.2 runtimes; missing prerequisites
fail the job rather than silently omitting coverage. A PR's check is head evidence, not proof of a future merge SHA.

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
fails the job; no upload retry or test retry is added. Superseded PR runs cancel; main/manual runs do not cancel.
`CASSINI_POST_STATUS=0` means this job cannot manufacture the legacy status; its token has no statuses-write scope.

## One-day comparison, then a separate decision

After merge, compare at least 24 hours of workflow and legacy exact-head results: test counts/coverage in both
runtimes, failures, queue/run durations, resource contention, cancellation cleanup and artifacts. Keep the old
status and merge policy throughout. Any flaky or infrastructure failure needs evidence and the existing D20 policy.
Only the coordinator may approve a later branch-protection/cutover change. UI sharding and iOS 18 cadence changes
are outside this slice. Physical-device testing and release signing/uploads remain on drmeyers.
