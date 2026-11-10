#!/usr/bin/env python3
"""Lightweight real-kqueue lifecycle regressions; no builds or simulators."""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "scripts/test-events.py"
spec = importlib.util.spec_from_file_location("events", HELPER)
events = importlib.util.module_from_spec(spec)
spec.loader.exec_module(events)
SOURCE = (ROOT / "scripts/test.sh").read_text()
# Hang guard only (D88): every wait below passes on an event, and running out fails the test.
HANG_GUARD = 60


def function(name):
    start = SOURCE.index(name + "() {")
    return SOURCE[start:SOURCE.index("\n}\n", start) + 3]


def finish(process):
    with events.Events() as queue:
        if queue.process(process.pid):
            if not queue.until(time.monotonic() + HANG_GUARD):
                process.kill()
                process.wait()
                raise AssertionError(f"process still running after the {HANG_GUARD} s hang guard")
    return process.wait()


def kill_quietly(pid):
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)


class FakeClock:
    """Virtual monotonic time for events.watch: a wait jumps straight to its deadline."""

    def __init__(self):
        self.now = 1000.0
        self.waits = []
        self.reads = 0

    def monotonic(self):
        # Caps a loop that spins without waiting, which would otherwise hang the test.
        self.reads += 1
        if self.reads > 100:
            raise AssertionError("watch kept reading the clock without waiting")
        return self.now

    def until(self, deadline):
        self.waits.append(deadline - 1000.0)
        if len(self.waits) > 10:
            raise AssertionError("watch kept waiting after its deadline")
        self.now = max(self.now, deadline)
        return []


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cassini events ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "log"

    def shell(self, code):
        functions = "\n".join(function(name) for name in (
            "process_tree", "signal_all", "end_tree", "run_limited", "run_watched"))
        process = subprocess.Popen(["/bin/bash", "-c", f'root={str(ROOT)!r}\n' + functions + "\n" + code],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.stderr.close)
        return process

    def test_immediate_exit_preserves_status_without_one_second_poll(self):
        process = self.shell(f'run_limited {str(self.log)!r} {HANG_GUARD} /bin/sh -c "exit 23"')
        self.assertEqual(finish(process), 23)

    def test_end_tree_ends_entire_command_tree(self):
        child = self.root / "child"
        script = self.root / "tree.py"
        script.write_text("import os,subprocess,sys,signal\n"
            "p=subprocess.Popen([sys.executable,'-c','import signal; signal.pause()'])\n"
            f"open({str(child)!r}+'.tmp','w').write(str(p.pid))\n"
            f"os.replace({str(child)!r}+'.tmp',{str(child)!r})\n"
            "signal.pause()\n")
        with events.Events() as queue:
            queue.file(self.root)
            tree = subprocess.Popen([sys.executable, str(script)])
            self.addCleanup(lambda: tree.poll() is None and (tree.kill(), tree.wait()))
            # The tree is complete once it publishes the grandchild's pid.
            while not child.exists():
                if not queue.until(time.monotonic() + HANG_GUARD):
                    self.fail(f"tree did not start its child within the {HANG_GUARD} s hang guard")
        pid = int(child.read_text())
        self.addCleanup(kill_quietly, pid)
        with events.Events() as queue:
            self.assertTrue(queue.process(pid), f"grandchild {pid} ended before end_tree ran")
            self.assertEqual(finish(self.shell(f"end_tree {tree.pid}")), 0)
            self.assertTrue(queue.until(time.monotonic() + HANG_GUARD),
                            f"end_tree left the grandchild {pid} running")
        self.assertIn(finish(tree), (-signal.SIGTERM, -signal.SIGKILL))

    def watch_stub(self, status):
        """A test-events.py stand-in that records each call and answers at once."""
        stub, calls = self.root / "stub", self.root / "calls"
        (stub / "scripts").mkdir(parents=True, exist_ok=True)
        calls.write_text("")
        (stub / "scripts/test-events.py").write_text(
            "import json,sys\n"
            f"open({str(calls)!r},'a').write(json.dumps(sys.argv[1:])+'\\n')\n"
            f"sys.exit(0 if sys.argv[3] == '/dev/null' else {status})\n")
        return stub, calls

    def test_limited_and_watched_runs_pass_the_watch_status_through(self):
        # run_limited and run_watched trust the helper's answer: 0 reaps the command's own
        # status, 124 and 125 end the command tree and report which deadline ran out.
        pause = shlex.join([sys.executable, "-c", "import signal; signal.pause()", str(self.root)])
        self.addCleanup(subprocess.run, ["/usr/bin/pkill", "-KILL", "-f", re.escape(str(self.root))])
        cases = [
            ("run_limited", "0.3", 0, '/bin/sh -c "exit 23"', 23, None),
            ("run_limited", "0.3", 124, pause, 124, "test.sh: still running after 0.3s; ended"),
            ("run_watched", "0.15 0.3", 0, '/bin/sh -c "exit 23"', 23, None),
            ("run_watched", "0.15 0.3", 124, pause, 124, "test.sh: no test started within 0.15s; ending xcodebuild"),
            ("run_watched", "0.15 0.3", 125, pause, 125, "test.sh: still running after 0.3s; ending xcodebuild"),
        ]
        for name, limits, status, command, expected, message in cases:
            with self.subTest(name=name, status=status):
                stub, calls = self.watch_stub(status)
                process = self.shell(f"root={str(stub)!r}\n{name} {str(self.log)!r} {limits} {command}")
                self.assertEqual(finish(process), expected, process.stderr.read().decode())
                made = [json.loads(line) for line in calls.read_text().splitlines()]
                pid = made[0][1]
                watched = ["watch", pid, str(self.log)] + limits.split()
                if name == "run_limited":
                    watched += [limits]
                else:
                    watched += ["--start", "Test Case '", "--total-status", "125"]
                self.assertEqual(made[0], watched)
                if message is None:
                    self.assertEqual(made[1:], [])
                else:
                    self.assertEqual(made[1:], [["watch", pid, "/dev/null", "5", "5"]])
                    self.assertEqual(self.log.read_text().splitlines()[-1], message)
                # The helper parses exactly what test.sh passes.
                parsed = []
                with mock.patch.object(events, "watch", lambda args: parsed.append(args) or 0), \
                     mock.patch.object(sys, "argv", ["test-events.py"] + made[0]):
                    self.assertEqual(events.main(), 0)
                self.assertEqual((parsed[0].pid, parsed[0].limit, parsed[0].total),
                                 (int(pid), float(limits.split()[0]), float(limits.split()[-1])))
                self.assertEqual((parsed[0].start, parsed[0].total_status),
                                 ("Test Case '", 125) if name == "run_watched" else (None, 124))

    def test_no_start_and_started_total_deadlines_have_distinct_statuses(self):
        # Virtual time: the watched pid (this process) never exits, so only the deadlines decide.
        for output, start, expected, waits in [
                (b"", "Test Case '", 124, [10]),
                (b"Test Case 'example' started.\n", "Test Case '", 125, [20]),
                (b"noise Test Case 'example' started.\n", "Test Case '", 124, [10]),
                (b"noise\rTest Case 'example' started.\n", "Test Case '", 124, [10]),
                (b"Test Case 'example' started.\n", None, 124, [20])]:
            with self.subTest(output=output, start=start):
                self.log.write_bytes(output)
                clock = FakeClock()
                with mock.patch.object(events, "time", clock), \
                     mock.patch.object(events.Events, "until", lambda queue, deadline: clock.until(deadline)):
                    status = events.watch(SimpleNamespace(pid=os.getpid(), log=self.log, start=start,
                        limit=10 if start else 20, total=20, total_status=125 if start else 124))
                self.assertEqual(status, expected)
                self.assertEqual(clock.waits, waits)

    def test_started_watch_ignores_further_log_writes_and_keeps_process_exit(self):
        child = subprocess.Popen([sys.executable, "-c", "import sys;sys.stdin.read()"],
                                 stdin=subprocess.PIPE)
        self.log.write_bytes(b"Test Case 'example' started.\n")
        original = events.Events.until
        def write_then_exit(queue, deadline):
            with self.log.open("ab") as log:
                log.write(b"later xcodebuild output\n")
            child.stdin.close()
            result = original(queue, deadline)
            self.assertTrue(result)
            self.assertTrue(all(event.filter == events.select.KQ_FILTER_PROC for event in result))
            return result
        try:
            with mock.patch.object(events.Events, "until", write_then_exit):
                self.assertEqual(events.watch(SimpleNamespace(pid=child.pid, log=self.log,
                    start="Test Case '", limit=HANG_GUARD, total=HANG_GUARD, total_status=125)), 0)
        finally:
            if not child.stdin.closed:
                child.stdin.close()
            finish(child)

    def test_fragmented_start_marker_is_retained_until_newline(self):
        child = subprocess.Popen([sys.executable, "-c", "import sys;sys.stdin.read()"],
                                 stdin=subprocess.PIPE)
        self.log.write_bytes(b"Test C")
        original = events.Events.until
        wakes = []
        def advance(queue, deadline):
            wakes.append(True)
            if len(wakes) == 1:
                with self.log.open("ab") as log:
                    log.write(b"ase 'example' started.\n")
            else:
                child.stdin.close()
            return original(queue, deadline)
        try:
            with mock.patch.object(events.Events, "until", advance):
                self.assertEqual(events.watch(SimpleNamespace(pid=child.pid, log=self.log,
                    start="Test Case '", limit=HANG_GUARD, total=HANG_GUARD, total_status=125)), 0)
            self.assertEqual(len(wakes), 2)
        finally:
            if not child.stdin.closed:
                child.stdin.close()
            finish(child)

    def test_lock_ready_only_reports_a_different_nonempty_holder(self):
        for note, expected in [("our note", ""), ("", ""), ("another holder", "another holder")]:
            with self.subTest(note=note):
                lock, held = self.root / "lock", self.root / "ready"
                held.unlink(missing_ok=True)
                lock.write_text(note)
                child = subprocess.Popen([sys.executable, "-c", "import sys;sys.stdin.read()"],
                                         stdin=subprocess.PIPE)
                def become_ready(queue, deadline):
                    held.touch()
                    return []
                output = io.StringIO()
                try:
                    # Virtual time keeps the "took the host lock after" line out of the output.
                    with contextlib.redirect_stdout(output), \
                         mock.patch.object(events, "time", FakeClock()), \
                         mock.patch.object(events.Events, "until", become_ready):
                        self.assertEqual(events.lock_ready(SimpleNamespace(pid=child.pid,
                            path=lock, held=held, seconds=HANG_GUARD, note="our note")), 0)
                    if expected:
                        self.assertIn("waiting for the host: " + expected, output.getvalue())
                    else:
                        self.assertEqual(output.getvalue(), "")
                finally:
                    child.stdin.close()
                    finish(child)

    def test_parent_death_releases_fair_lock_without_parent_reaping(self):
        path, held = self.root / "lock", self.root / "held"
        parent = subprocess.Popen([sys.executable, "-c",
            "import subprocess,sys,os; a=sys.argv[1:];a[a.index('PARENT')]=str(os.getpid());"
            "p=subprocess.Popen(a);print(p.pid,flush=True);sys.stdin.read()",
            sys.executable, "-I", str(HELPER), "hold", str(path), "PARENT", str(held), "fixture"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(parent.stdin.close)
        self.addCleanup(parent.stdout.close)
        self.addCleanup(parent.stderr.close)
        helper = int(parent.stdout.readline())
        ready = subprocess.Popen([sys.executable, "-I", str(HELPER), "lock-ready", str(helper),
                                  str(path), str(held), str(HANG_GUARD)], stdout=subprocess.PIPE)
        self.addCleanup(ready.stdout.close)
        self.assertEqual(finish(ready), 0)
        with path.open("r+") as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with events.Events() as queue:
                self.assertTrue(queue.process(helper))
                parent.kill()  # Deliberately leave the parent unreaped until helper exit.
                self.assertTrue(queue.until(time.monotonic() + HANG_GUARD))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(path.read_text(), "")
        parent.wait()

    def test_waiting_lock_helper_exits_when_parent_dies(self):
        path, held = self.root / "busy-lock", self.root / "held"
        with path.open("w+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            parent = subprocess.Popen([sys.executable, "-c",
                "import subprocess,sys,os;a=sys.argv[1:];a[a.index('PARENT')]=str(os.getpid());"
                "p=subprocess.Popen(a);print(p.pid,flush=True);sys.stdin.read()",
                sys.executable, "-I", str(HELPER), "hold", str(path), "PARENT", str(held), "waiting"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for stream in (parent.stdin, parent.stdout, parent.stderr):
                self.addCleanup(stream.close)
            helper = int(parent.stdout.readline())
            with events.Events() as queue:
                self.assertTrue(queue.process(helper))
                parent.kill()
                self.assertTrue(queue.until(time.monotonic() + HANG_GUARD))
            parent.wait()
            self.assertFalse(held.exists())

    def test_resource_wait_wakes_on_process_exit(self):
        child = subprocess.Popen([sys.executable, "-c", "import sys;sys.stdin.read()"], stdin=subprocess.PIPE)
        original = events.Events.until
        def release_then_wait(queue, deadline):
            child.stdin.close()
            result = original(queue, deadline)
            self.assertTrue(any(event.filter == events.select.KQ_FILTER_PROC for event in result))
            return result
        with mock.patch.object(events.subprocess, "check_output", return_value=f"{child.pid} {os.getuid()} S\n".encode()), \
             mock.patch.object(events.Events, "until", release_then_wait):
            self.assertEqual(events.resource_event(SimpleNamespace(deadline=time.time() + HANG_GUARD)), 0)
        self.assertEqual(child.wait(), 0)

    def test_admission_healthy_immediate_and_unhealthy_deadline_fails_closed(self):
        for free, expected in [(4096, 0), (1024, 1)]:
            with self.subTest(free=free):
                stamp = self.root / "stamp"
                stamp.unlink(missing_ok=True)
                code = function("wait_for_room") + "\n" + f"""
                    admit_minutes=1; prefix=fixture
                    our_clones() {{ :; }}
                    free_mb() {{ echo {free}; }}
                    cpu_idle() {{ echo 100; }}
                    die() {{ echo "$*" >&2; exit 1; }}
                    date() {{ if [ -e {str(stamp)!r} ]; then echo 160; else touch {str(stamp)!r}; echo 100; fi; }}
                    wait_for_room
                """
                process = self.shell(code)
                self.assertEqual(finish(process), expected, process.stderr.read().decode())

    def test_cpu_recheck_samples_iostat_while_fast_suite_is_alive(self):
        sampled = self.root / "sampled"
        code = function("cpu_idle") + "\n" + f"""
            fast_pid=$$
            iostat() {{ touch {str(sampled)!r}; echo '0 0 37'; }}
            [ "$(cpu_idle)" = 100 ] || exit 11
            [ ! -e {str(sampled)!r} ] || exit 12
            [ "$(cpu_idle 1)" = 37 ] || exit 13
            [ -e {str(sampled)!r} ] || exit 14
        """
        process = self.shell(code)
        self.assertEqual(finish(process), 0, process.stderr.read().decode())

    def test_admission_requests_real_cpu_sample_after_resource_wake(self):
        wake, samples = self.root / "wake", self.root / "samples"
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "test-events.py").write_text(f"from pathlib import Path\nPath({str(wake)!r}).touch()\n")
        code = function("wait_for_room") + "\n" + f"""
            root={str(self.root)!r}; admit_minutes=1; prefix=fixture
            our_clones() {{ :; }}
            free_mb() {{ if [ -e {str(wake)!r} ]; then echo 4096; else echo 1024; fi; }}
            cpu_idle() {{ echo "$1" >> {str(samples)!r}; echo 100; }}
            die() {{ echo "$*" >&2; exit 1; }}
            wait_for_room
        """
        process = self.shell(code)
        self.assertEqual(finish(process), 0, process.stderr.read().decode())
        self.assertEqual(samples.read_text().splitlines(), ["0", "1"])



if __name__ == "__main__":
    unittest.main()
