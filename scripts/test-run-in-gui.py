#!/usr/bin/env python3
"""GUI-runner lifecycle tests using a fake tmux launcher; no GUI or simulator needed."""
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

RUNNER = Path(__file__).with_name("run-in-gui.py")


class GUIRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gui runner's test-")
        self.root = Path(self.temporary.name)
        tmux = self.root / "tmux"
        tmux.write_text("#!" + sys.executable + "\n" + '''import os,shlex,subprocess,sys
if "has-session" in sys.argv:
    raise SystemExit(0 if os.environ.get("TEST_GUI_AVAILABLE", "1") == "1" else 1)
if "new-window" in sys.argv:
    if os.environ.get("TEST_GUI_LAUNCH_FAIL"):
        raise SystemExit(1)
    process = subprocess.Popen(shlex.split(sys.argv[-1]), start_new_session=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.environ.get("TEST_GUI_PID_FILE"):
        with open(os.environ["TEST_GUI_PID_FILE"], "w") as record:
            record.write(str(process.pid))
    print(str(process.pid) + " %123", flush=True)
    raise SystemExit(0)
raise SystemExit(2)
''')
        tmux.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"])

    def tearDown(self):
        self.temporary.cleanup()

    def launch(self, *args, **env):
        return subprocess.run([sys.executable, str(RUNNER), *args], cwd=self.root,
                              env=dict(self.env, **env), capture_output=True, timeout=10)

    def test_drains_all_output_and_returns_command_failure(self):
        result = self.launch(sys.executable, "-c",
                             "import os,sys;os.write(1,b'x'*150000);os.write(2,b'END');sys.exit(23)")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(result.stdout, b"x" * 150000 + b"END")

    def test_preserves_literal_arguments_working_directory_and_environment(self):
        marker = self.root / "must-not-be-created"
        values = ["with spaces", "a'b", "two\nlines", "$(touch " + str(marker) + ")", "`false`", "$HOME"]
        result = self.launch(sys.executable, "-c",
                             "import json,os,sys;print(json.dumps([sys.argv[1:],os.getcwd(),os.getenv('GUIRUN_INSIDE'),os.getenv('PATH')]))",
                             *values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [values, str(self.root.resolve()), "1", self.env["PATH"]])
        self.assertFalse(marker.exists())

    def test_unavailable_gui_has_actionable_error(self):
        result = self.launch("true", TEST_GUI_AVAILABLE="0")
        self.assertEqual(result.returncode, 69)
        self.assertIn(b"~/bin/gui-tmux.command", result.stderr)

    def test_invalid_timeouts_are_rejected_before_launch(self):
        for value in ["0", "-1", "nan", "inf", "not-a-number"]:
            with self.subTest(timeout=value):
                result = self.launch("true", GUIRUN_TIMEOUT=value)
                self.assertEqual(result.returncode, 64)
                self.assertIn(b"GUIRUN_TIMEOUT must be positive seconds", result.stderr)

    def test_launch_failure_is_reported_without_waiting_for_completion(self):
        result = self.launch("true", TEST_GUI_LAUNCH_FAIL="1")
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assertIn(b"GUI command launch failed", result.stderr)
        log = Path(result.stderr.decode().split("Log: ", 1)[1].strip())
        self.assertTrue(log.exists())
        shutil.rmtree(log.parent)

    def test_wrapper_death_without_completion_is_reported(self):
        result = self.launch(sys.executable, "-c", "import os,signal;os.kill(os.getppid(),signal.SIGKILL)")
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assertIn(b"exited without publishing its completion status", result.stderr)
        self.assertIn(b"Pane: %123", result.stderr)
        log = Path(result.stderr.decode().split("Log: ", 1)[1].strip())
        self.assertFalse((log.parent / "done").exists())
        shutil.rmtree(log.parent)

    def started_line(self, watcher):
        # Read readiness as an event, with a hang guard even if startup produces no newline.
        deadline = time.monotonic() + 10
        data = bytearray()
        while b"\n" not in data:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, "GUI child did not announce startup")
            readable, _, _ = select.select([watcher.stdout], [], [], remaining)
            self.assertTrue(readable, "No GUI child startup event")
            chunk = os.read(watcher.stdout.fileno(), 65536)
            self.assertTrue(chunk, "GUI watcher exited before startup")
            data.extend(chunk)
        return bytes(data)

    def release_gate(self, barrier, barrier_fd):
        # Keep the FIFO open until the synthetic GUI wrapper exits, including after a failed assertion.
        queue = select.kqueue()
        try:
            record = Path(str(barrier) + ".pid")
            watching = False
            if record.exists():
                try:
                    queue.control([select.kevent(int(record.read_text()), filter=select.KQ_FILTER_PROC,
                                                 flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                                 fflags=select.KQ_NOTE_EXIT)], 0, 0)
                    watching = True
                except ProcessLookupError:
                    pass
            os.write(barrier_fd, b"xx")  # Release either one or both pending reads.
            if watching:
                self.assertTrue(queue.control(None, 1, 10), "Released GUI wrapper did not exit")
        finally:
            queue.close()
            os.close(barrier_fd)

    def finish_retained_command(self, log, barrier_fd, expected="started\nfinished\n"):
        directory = os.open(log.parent, os.O_RDONLY)
        queue = select.kqueue()
        try:
            queue.control([select.kevent(directory, filter=select.KQ_FILTER_VNODE,
                                         flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                         fflags=select.KQ_NOTE_WRITE)], 0, 0)
            os.write(barrier_fd, b"x")
            deadline = time.monotonic() + 10
            done = log.parent / "done"
            while not done.exists():
                remaining = deadline - time.monotonic()
                self.assertGreater(remaining, 0, "Retained command did not finish after release")
                self.assertTrue(queue.control(None, 1, remaining), "No completion after release")
            self.assertEqual(done.read_text().strip(), "0")
            self.assertEqual(log.read_text(), expected)
        finally:
            queue.close()
            os.close(directory)
            shutil.rmtree(log.parent)

    def test_local_signals_preserve_the_gui_command_and_report_its_log(self):
        for number in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number):
                barrier = self.root / ("release-" + str(number))
                os.mkfifo(barrier, 0o600)
                barrier_fd = os.open(barrier, os.O_RDWR | os.O_NONBLOCK)
                watcher = subprocess.Popen(
                    [sys.executable, str(RUNNER), sys.executable, "-c",
                     "import sys;print('started',flush=True);open(sys.argv[1],'rb',buffering=0).read(1);print('finished',flush=True)",
                     str(barrier)], cwd=self.root,
                    env=dict(self.env, GUIRUN_TIMEOUT="10", TEST_GUI_PID_FILE=str(barrier) + ".pid"),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    self.assertEqual(self.started_line(watcher), b"started\n")
                    watcher.send_signal(number)
                    _out, error = watcher.communicate(timeout=10)
                    self.assertEqual(watcher.returncode, 128 + number, error)
                    self.assertIn(signal.Signals(number).name.encode(), error)
                    self.assertIn(b"GUI command was not stopped. Pane: %123", error)
                    log = Path(error.decode().split("Log: ", 1)[1].strip())
                    self.assertTrue(log.exists())
                    self.assertFalse((log.parent / "done").exists())
                    self.finish_retained_command(log, barrier_fd)
                finally:
                    try:
                        self.release_gate(barrier, barrier_fd)
                    finally:
                        if watcher.poll() is None:
                            watcher.kill()
                            watcher.wait(timeout=10)

    def test_closed_local_output_preserves_the_gui_command_and_reports_its_log(self):
        barrier = self.root / "release-pipe"
        os.mkfifo(barrier, 0o600)
        barrier_fd = os.open(barrier, os.O_RDWR | os.O_NONBLOCK)
        watcher = subprocess.Popen(
            [sys.executable, str(RUNNER), sys.executable, "-c",
             "import sys;f=open(sys.argv[1],'rb',buffering=0);print('started',flush=True);f.read(1);print('more',flush=True);f.read(1);print('finished',flush=True)",
             str(barrier)], cwd=self.root,
            env=dict(self.env, GUIRUN_TIMEOUT="10", TEST_GUI_PID_FILE=str(barrier) + ".pid"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(self.started_line(watcher), b"started\n")
            watcher.stdout.close()
            watcher.stdout = None
            os.write(barrier_fd, b"x")
            _out, error = watcher.communicate(timeout=10)
            self.assertEqual(watcher.returncode, 141, error)
            self.assertIn(b"output pipe closed", error)
            self.assertIn(b"GUI command was not stopped. Pane: %123", error)
            log = Path(error.decode().split("Log: ", 1)[1].strip())
            self.assertFalse((log.parent / "done").exists())
            self.finish_retained_command(log, barrier_fd, "started\nmore\nfinished\n")
        finally:
            try:
                self.release_gate(barrier, barrier_fd)
            finally:
                if watcher.poll() is None:
                    watcher.kill()
                    watcher.wait(timeout=10)

    def test_timeout_preserves_command_and_durable_output(self):
        barrier = self.root / "release"
        os.mkfifo(barrier, 0o600)
        barrier_fd = os.open(barrier, os.O_RDWR | os.O_NONBLOCK)
        try:
            result = self.launch(sys.executable, "-c",
                                 "import sys;print('started',flush=True);open(sys.argv[1],'rb',buffering=0).read(1);print('finished',flush=True)",
                                 str(barrier), GUIRUN_TIMEOUT="0.05", TEST_GUI_PID_FILE=str(barrier) + ".pid")
            self.assertEqual(result.returncode, 124, result.stderr)
            log = Path(result.stderr.decode().split("Log: ", 1)[1].strip())
            self.assertTrue(log.exists())
            directory = os.open(log.parent, os.O_RDONLY)
            queue = select.kqueue()
            try:
                queue.control([select.kevent(directory, filter=select.KQ_FILTER_VNODE,
                                             flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                             fflags=select.KQ_NOTE_WRITE)], 0, 0)
                os.write(barrier_fd, b"x")
                deadline = time.monotonic() + 10
                done = log.parent / "done"
                while not done.exists():
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, "GUI command did not finish after release event")
                    self.assertTrue(queue.control(None, 1, remaining), "No completion event after releasing command")
                self.assertEqual(done.read_text().strip(), "0")
                self.assertEqual(log.read_text(), "started\nfinished\n")
            finally:
                queue.close()
                os.close(directory)
                shutil.rmtree(log.parent)
        finally:
            self.release_gate(barrier, barrier_fd)


if __name__ == "__main__":
    unittest.main()
