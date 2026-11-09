#!/usr/bin/env python3
"""macOS file/process event waits used by test.sh; deadlines are upper bounds only."""
import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import threading
import time


class Events:
    def __init__(self):
        self.queue = select.kqueue()
        self.files = []

    def close(self):
        self.queue.close()
        for fd in self.files:
            os.close(fd)

    def process(self, pid):
        try:
            self.queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT)], 0, 0)
            return True
        except ProcessLookupError:
            return False

    def file(self, path):
        fd = os.open(path, os.O_RDONLY)
        self.files.append(fd)
        self.queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
            flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
            fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)], 0, 0)
        return fd

    def unwatch_file(self, fd):
        # Closing the descriptor removes its vnode knote; keep close() from closing it twice.
        self.files.remove(fd)
        os.close(fd)

    def until(self, deadline):
        return self.queue.control(None, 128, max(0, deadline - time.monotonic()))

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def watch(args):
    """0 means process exit (shell reaps status); 124/125 mean deadline."""
    began = time.monotonic()
    started = args.start is None
    with Events() as events:
        if not events.process(args.pid):
            return 0
        log_event = events.file(args.log) if not started else None
        with open(args.log, "rb") as log:
            pending = b""
            while True:
                if not started:
                    pending += log.read()
                    lines = pending.split(b"\n")
                    # Only LF starts a new line; retain a marker split across writes.
                    pending = lines.pop()
                    started = any(line.startswith(args.start.encode()) for line in lines)
                    if started:
                        events.unwatch_file(log_event)
                        log_event = None
                elapsed = time.monotonic() - began
                if not started and elapsed >= args.limit:
                    return 124
                if elapsed >= args.total:
                    return args.total_status
                deadline = began + (args.total if started else min(args.limit, args.total))
                if any(event.filter == select.KQ_FILTER_PROC for event in events.until(deadline)):
                    return 0


def hold(args):
    """One blocking flock retains kernel waiter ordering; parent exit releases it."""
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    with Events() as events:
        if not events.process(args.parent) or os.getppid() != args.parent:
            return 1
        def parent_exited():
            try:
                events.queue.control(None, 1, None)
            except OSError:  # Normal SIGTERM cleanup may close the queue first.
                return
            os.kill(os.getpid(), signal.SIGTERM)
        threading.Thread(target=parent_exited, daemon=True).start()
        fd = os.open(args.path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                os.ftruncate(fd, 0)
                os.write(fd, (args.note + "\n").encode())
                Path(args.held).touch()
                signal.pause()
            finally:
                os.ftruncate(fd, 0)
        finally:
            os.close(fd)


def lock_ready(args):
    began = time.monotonic()
    deadline = began + max(5, args.seconds)
    shown = None
    with Events() as events:
        events.file(Path(args.held).parent)
        # Ensure the lock exists before watching its changing holder note.
        Path(args.path).touch(exist_ok=True)
        events.file(args.path)
        alive = events.process(args.pid)
        while True:
            if Path(args.held).exists():
                elapsed = int(time.monotonic() - began)
                if elapsed >= 2:
                    print(f"took the host lock after {elapsed // 60} min {elapsed % 60} s", flush=True)
                return 0
            if not alive:
                return 1
            holder = Path(args.path).read_text().strip()
            if holder and holder != args.note and holder != shown:
                print(f"waiting for the host: {holder} holds {args.path}", flush=True)
                shown = holder
            if time.monotonic() >= deadline:
                return 124
            alive = not any(event.filter == select.KQ_FILTER_PROC for event in events.until(deadline))


def resource_event(args):
    """Wait for same-user process exit or the admission deadline.

    CPU idle and exact available bytes have no recovery event: absence of exits
    conservatively waits to the deadline, when the caller checks admission again.
    """
    with Events() as events:
        parent = os.getppid()
        if parent == 1 or not events.process(parent):
            return 1
        table = subprocess.check_output(["/bin/ps", "-axo", "pid=,uid=,stat="]).decode()
        for row in table.splitlines():
            pid_text, uid_text, state = row.split()
            pid, uid = int(pid_text), int(uid_text)
            if not state.startswith("Z") and uid == os.getuid() and pid not in (os.getpid(), os.getppid()):
                with contextlib.suppress(PermissionError):
                    events.process(pid)
        events.until(time.monotonic() + max(0, args.deadline - time.time()))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("watch")
    command.add_argument("pid", type=int)
    command.add_argument("log")
    command.add_argument("limit", type=float)
    command.add_argument("total", type=float)
    command.add_argument("--start")
    command.add_argument("--total-status", type=int, default=124)
    command = commands.add_parser("hold")
    command.add_argument("path")
    command.add_argument("parent", type=int)
    command.add_argument("held")
    command.add_argument("note")
    command = commands.add_parser("lock-ready")
    command.add_argument("pid", type=int)
    command.add_argument("path")
    command.add_argument("held")
    command.add_argument("seconds", type=float)
    command.add_argument("--note", default=None)
    command = commands.add_parser("resource-event")
    command.add_argument("deadline", type=float)
    args = parser.parse_args()
    return {"watch": watch, "hold": hold, "lock-ready": lock_ready,
            "resource-event": resource_event}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
