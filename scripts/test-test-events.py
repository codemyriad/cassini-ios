#!/usr/bin/env python3
"""Lightweight real-kqueue lifecycle regressions; no builds or simulators."""
import contextlib
import fcntl
import importlib.util
import io
import os
from pathlib import Path
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


def function(name):
    start = SOURCE.index(name + "() {")
    return SOURCE[start:SOURCE.index("\n}\n", start) + 3]


def finish(process, seconds=5):
    with events.Events() as queue:
        if queue.process(process.pid):
            if not queue.until(time.monotonic() + seconds):
                process.kill()
                process.wait()
                raise AssertionError("process missed lifecycle deadline")
    return process.wait()


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
        process = self.shell(f'run_limited {str(self.log)!r} 5 /bin/sh -c "exit 23"')
        self.assertEqual(finish(process), 23)

    def test_timeout_ends_entire_command_tree(self):
        child = self.root / "child"
        script = self.root / "tree.py"
        script.write_text("import subprocess,sys,signal\n"
            "p=subprocess.Popen([sys.executable,'-c','import signal; signal.pause()'])\n"
            f"open({str(child)!r},'w').write(str(p.pid))\n"
            "signal.pause()\n")
        process = self.shell(f'run_limited {str(self.log)!r} 0.3 {sys.executable!r} {str(script)!r}')
        self.assertEqual(finish(process), 124)
        pid = int(child.read_text())
        # An unreaped zombie is harmless; ps state must never show a live orphan.
        state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="],
                               capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), state)

    def test_no_start_and_started_total_deadlines_have_distinct_statuses(self):
        for output, expected in [("", 124), ("Test Case 'example' started.\\n", 125),
                                 ("noise Test Case 'example' started.\\n", 124),
                                 ("noise\rTest Case 'example' started.\\n", 124)]:
            with self.subTest(output=output):
                command = "import signal,sys;sys.stdout.write(" + repr(output.replace('\\n', '\n')) + ");sys.stdout.flush();signal.pause()"
                import shlex
                process = self.shell(f'run_watched {str(self.log)!r} 0.15 0.3 {shlex.join([sys.executable,"-c",command])}')
                self.assertEqual(finish(process), expected, process.stderr.read().decode())

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
                    start="Test Case '", limit=5, total=5, total_status=125)), 0)
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
                    start="Test Case '", limit=5, total=5, total_status=125)), 0)
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
                    with contextlib.redirect_stdout(output), \
                         mock.patch.object(events.Events, "until", become_ready):
                        self.assertEqual(events.lock_ready(SimpleNamespace(pid=child.pid,
                            path=lock, held=held, seconds=5, note="our note")), 0)
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
                                  str(path), str(held), "5"], stdout=subprocess.PIPE)
        self.addCleanup(ready.stdout.close)
        self.assertEqual(finish(ready), 0)
        with path.open("r+") as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with events.Events() as queue:
                self.assertTrue(queue.process(helper))
                parent.kill()  # Deliberately leave the parent unreaped until helper exit.
                self.assertTrue(queue.until(time.monotonic() + 5))
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
                self.assertTrue(queue.until(time.monotonic() + 5))
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
            self.assertEqual(events.resource_event(SimpleNamespace(deadline=time.time() + 5)), 0)
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
