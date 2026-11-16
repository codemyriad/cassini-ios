# Observational simulator gate

`Simulator gate / Full simulator gate (observational)` runs `scripts/test.sh simulator` as a GitHub Actions check.
It runs alongside `drmeyers/test-all`; **it does not replace the coordinator's legacy merge gate**.
CI runs the string catalog and package tests once through `fast`; this workflow builds once and runs the hosted tests
and every default-runtime phone/iPad UI test. Ordinary PRs run the iOS 18 smoke list plus **all**
`AccessibilityAuditTests` and `WideScreenTests`, including their iPad cases, with one booted clone at a time.
Nightly, manual and `full-ci` PR runs run the full iOS 18 leg. Both legs reuse the same build.
The local/manual `all` tier retains its existing coverage, automatic view-change mode and status restrictions.
There are no signing, keychain, archive, TestFlight or App Store steps.

## Trust and source

The job is eligible only in `codemyriad/cassini-ios`, for nightly main schedules, manual main dispatches and same-repository
pull requests (opened, synchronized, reopened, or labeled `full-ci`). An opened PR already labeled `full-ci`
skips the opened gate: its labeled event starts the full gate. Reopening still starts a full gate because it emits
no labeled event. Unrelated label events do not allocate a runner.
CI still verifies every main push for TestFlight exact-head evidence; the simulator workflow no longer repeats after
each merge. This is a cadence decision, not reuse of PR success as proof of a merged tree. The job-level condition
rejects forks, missing head metadata and other events before allocating a
self-hosted runner or checking out code. It never uses `pull_request_target`. Both checkouts discard credentials;
the workflow token has only contents-read permission and is not passed to test commands.

This condition protects the normal workflow path, not a runner from a PR that edits workflow YAML to remove it or
add another job. The coordinator confirmed the repository's server-side Actions policy is
`approval_policy=all_external_contributors`: no fork workflow starts on any runner until a maintainer approves it,
including PRs that edit workflow YAML. Keep that approval boundary and never approve a fork for this pool. The job
guard is the second layer: trusted events and a same-repository head are required; forks skip the job rather than
falling back to another runner. A guard truth-table test alone is not proof of backend enforcement. Org runner-group
settings could not be inspected with the available token; no new group/label or permission was created here.

The app checkout is the immutable PR head SHA (the same source the legacy status tested), or the scheduled/dispatch SHA.
Full history supports the existing test script's change detection. Conformance vectors use the same pinned
cassini-format revision as ordinary CI. Xcode 27.0 is selected per process using `DEVELOPER_DIR`, without changing
the machine's global toolchain. Pool hosts must already have XcodeGen and iOS 27/18.2 runtimes; missing prerequisites
fail the job rather than silently omitting coverage. A PR's check is head evidence, not proof of a future merge SHA.

## Capacity and evidence

The verified pool label is `self-hosted, macOS, ARM64, cm-mac-m4`. These runners are registered to this repository
on the rented Macs; this label must never be attached to drmeyers. Serial UI mode bounds this run to one booted
test simulator at a time, including the iPad. On a host with `~/bin/heavy-run`, it acquires a configured host slot
on `.big-heavy.slot.{1,2,3}`. That wrapper's `CASSINI_HEAVY_LOCK_HELD=1` does **not** prove ownership of
`~/.cassini-heavy.lock`. The test script also takes that shared flock, which `cassini-mac/scripts/ci-heavy.py` uses,
so Mac jobs cannot overlap the iOS build/simulator tiers merely because they hold a different fleet slot.
Only `CASSINI_IOS_LOCK_HELD=1` bypasses a nested acquisition: the iOS 18 child and the repository's lockf-based
screenshot/benchmark/speaker wrappers use it. Those wrappers also pass the legacy marker to their locked command
for older checkout compatibility, but never trust that marker to skip acquisition. The flock helper waits on process
events and releases only after
owned children stop; the lock inode is retained. The local PR screenshot driver rejects either enclosing lock marker.
Without heavy-run, the test script takes the same flock directly.
The simulator gate explicitly allows 90 minutes to acquire this lock and 155 minutes overall, leaving
65 minutes for the roughly 50-minute full run and cleanup. The package/build CI job allows 120 minutes
to acquire the lock and 150 minutes overall, retaining its 30-minute work budget after two queued gates.
These budgets let the lock deadline report "host busy" before the runner cancels a waiting job, including
main-push CI used by unattended TestFlight. Existing CI concurrency groups remain unchanged: opened and
full-ci labeled events can both run CI, with labeled runs isolated to avoid cancelling code-push runs.
The existing resource-admission rules remain active. Runner slots share physical CPU/RAM; an idle runner service
does not imply an idle machine.

Simulator names include the registered runner name, so concurrent services on one host cannot reuse a simulator.
Each service executes one job at a time. Initial and always-run cleanup remove only that service's clones; after
a host crash, its next job cleans the same owned prefix rather than abandoning a new generation of clones.
The gate step uses exec through its workflow wrapper and records the actual test owner's PID in a run/attempt-specific
file under RUNNER_TEMP. Always-run cleanup sends TERM to that owner if needed and waits for its process-exit event
before deleting clones. Cleanup first suspends any `test-events.py hold` helpers so their parent-exit
watchers cannot release the lock early, then sends TERM (and KILL if needed) to the owner and other descendants.
Only after all those processes exit does it terminate, resume and await the lock helpers. If workers fail to
exit, the helpers stay suspended with the lock held. A timeout or PID identity mismatch fails cleanup without
deleting clones. Cancellation ends this run's build/shard descendants even when a host slot was acquired outside
the test script.
Logs and result bundles from both runtime legs
are uploaded on success or failure and retained for seven days, identified by run and attempt. Native step failure
fails the job; no upload retry or test retry is added. No automatic cancellation is configured.
`CASSINI_POST_STATUS=0` means this job cannot manufacture the legacy status; its token has no statuses-write scope.

## One-day comparison, then a separate decision

After merge, compare at least 24 hours of workflow and legacy exact-head results: test counts/coverage in both
runtimes, failures, queue/run durations, resource contention, cancellation cleanup and artifacts. Keep the old
status and merge policy throughout. Any flaky or infrastructure failure needs evidence and the existing D20 policy.
Only the coordinator may approve a later branch-protection/cutover change. D20 still forbids adding automatic
cancellation or a concurrency group that evicts pending runs (commit `5d9ad2a`); the existing CI concurrency policy
is unchanged. Physical-device testing and release signing/uploads remain on drmeyers.

## D-1065 expected savings and validation boundary

The observed baseline supplied with D-1065 was roughly two minutes of repeated package work, then hosted tests,
about 21 minutes of default-runtime UI tests and about 21 minutes of full iOS 18 UI tests. Removing the second
`fast` eliminates duplicate package/XPC work, though its overlap with compilation means the full two minutes are
not necessarily on the critical path. Removing the merge-push simulator trigger saves an entire roughly 45-minute
run per merge. A nightly full run replaces that per-merge cadence.

The expanded PR smoke must retain the slower iPad and language/large-text audits. Therefore the old phone-only
smoke estimate (about 5.5 minutes) is not an estimate for this workflow. At this revision the expanded selection is
30 phone entries and seven iPad entries, versus 171 phone and 27 iPad entries in full (198 total). The committed
timing table, with the harness default of 15 seconds for an unmeasured test, plans about 917 seconds for the
expanded smoke UI selection. These estimates include phone entries that skip on that device and omit boot/hosted
overhead; they are not measured iOS 18 wall time. Measured before/after rented-runner durations, lock queue time
and both runtime shard logs are
still required after staging. No full simulator run is performed on the staging laptop. No signing or release-runner
policy changes accompany this optimization.
