# Event-driven test harness waits

`scripts/test.sh` uses `scripts/test-events.py` (macOS's built-in Python and
kqueue) for process exits, log writes, lock readiness and parent death. There is
no sleep/check synchronization. The existing command, test-start and total-run
deadlines remain upper bounds, and the shell still reaps the command's actual
exit status. Timeout cleanup terminates the captured descendant tree before
releasing the host lock.

Startup markers begin after LF only; a carriage return does not start a new
line. Once a complete startup marker arrives, the log's vnode watch is removed.
The watcher then wakes only for process exit or its total deadline.

The lock helper retains one blocking `flock`: it never drops its place by
repeatedly trying the lock. The helper alone owns the non-inheritable descriptor,
and releases it when the shell ends, including an unreaped parent exit. A
waiting helper also exits if its parent dies. The readiness watcher observes the
held-file directory, changing holder note and helper exit. The existing five
second startup grace for `CASSINI_LOCK_MINUTES=0` is an upper bound, not a delay.
The readiness watcher reports only a different, nonempty holder note; the
current run's note is passed explicitly so publication cannot announce itself
as another holder.

Resource admission keeps the existing CPU and available-memory measurements,
thresholds and credit for this worktree's booted clones. A healthy initial sample
admits immediately. Otherwise it rechecks after same-user process exits or at
`CASSINI_ADMIT_MINUTES`. An unhealthy final sample now fails closed instead of
booting more simulators. `CASSINI_ADMIT_MINUTES=0` retains the explicit opt-out.
The two-second `iostat` interval measures CPU utilization; it is not a retry timer.
An initial admission check retains the existing shortcut while this run's Swift
suite is alive. After a resource-event wake, CPU is always sampled, including
beside that suite, so its short-lived children cannot drive a tight `ps` and
`vm_stat` recheck loop.

There is no notification for the exact free-memory or CPU-idle threshold. If CPU
activity stops, or a process frees memory, without any observable process exit,
admission conservatively waits until the deadline and checks again. Process
exit between sampling and arming can similarly defer a recheck. This avoids
periodic polling and never admits a measured unhealthy host.

## Lightweight validation and timing

Run `python3 scripts/test-test-events.py`. These real-kqueue lifecycle fixtures
cover immediate nonzero exit, startup versus total deadlines, anchored startup
markers, descendant cleanup, lock release with an unreaped parent, a waiting
lock helper's parent death, process-exit admission wake and fail-closed admission.
They build nothing and boot no simulator.

Three sequential `run_limited /usr/bin/true` samples on drmeyers (2026-11-09):

| Harness | Samples (seconds) | Median |
| --- | --- | --- |
| Before | 1.016345, 1.022131, 1.020559 | 1.020559 s |
| Events | 0.117303, 0.081449, 0.082698 | 0.082698 s |

This removes about 0.938 seconds (91.9%) of completion overhead per immediate
command. It is not a full-suite timing claim. Raw evidence is in the coordination
folder `evidence/ios/test-harness-events-2026-11-09/timings.json`.
