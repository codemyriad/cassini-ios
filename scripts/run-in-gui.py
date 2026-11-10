#!/usr/bin/env python3
"""Run a command in the existing Aqua tmux session, waiting on filesystem events.

The GUI session supplies Terminal's TCC/keychain context. Set GUIRUN_TIMEOUT for an
upper bound (default 86400 seconds); a timeout leaves the command and its log alive.
Pass command environment variables explicitly with `env NAME=value COMMAND ...`.
"""
import math
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupted(signum, _frame):
    raise Interrupted(signum)


def run(argv):
    if not argv:
        print("usage: run-in-gui.py COMMAND [ARGS...]", file=sys.stderr)
        return 64
    if not hasattr(select, "kqueue"):
        print("run-in-gui.py requires macOS kqueue", file=sys.stderr)
        return 69
    try:
        timeout = float(os.environ.get("GUIRUN_TIMEOUT", "86400"))
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError()
    except ValueError:
        print("GUIRUN_TIMEOUT must be positive seconds", file=sys.stderr)
        return 64
    tmux = shutil.which("tmux")
    if not tmux or subprocess.run([tmux, "-L", "gui", "has-session", "-t", "gui"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        print("GUI tmux session is unavailable. In the Mac's logged-in GUI Terminal, run "
              "~/bin/gui-tmux.command, then retry.", file=sys.stderr)
        return 69

    root = Path(tempfile.mkdtemp(prefix="cassini-guirun-"))
    output = root / "out"
    output.touch(mode=0o600)
    done = root / "done"
    script = root / "command.zsh"
    script.write_text("\n".join([
        "#!/bin/zsh",
        "finish() {",
        "  rc=$?",
        f"  print -r -- $rc > {shlex.quote(str(root / 'done.tmp'))}",
        f"  mv {shlex.quote(str(root / 'done.tmp'))} {shlex.quote(str(done))}",
        "}",
        "trap finish EXIT",
        f"exec >> {shlex.quote(str(output))} 2>&1",
        f"cd {shlex.quote(os.getcwd())} || exit 1",
        f"export GUIRUN_INSIDE=1 PATH={shlex.quote(os.environ.get('PATH', ''))}",
        shlex.join(argv),
        "exit $?",
        "",
    ]))
    script.chmod(0o600)
    deadline = time.monotonic() + timeout
    successful = False
    pane = "unknown (launch may still have succeeded)"
    handlers = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    for number in handlers:
        signal.signal(number, interrupted)

    def retained(reason):
        print(f"{reason}; GUI command was not stopped. Pane: {pane}. Log: {output}", file=sys.stderr)

    try:
        with output.open("rb", buffering=0) as stream:
            directory = os.open(root, os.O_RDONLY)
            try:
                queue = select.kqueue()
                try:
                    changes = [select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                             flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                             fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)
                               for fd in (stream.fileno(), directory)]
                    queue.control(changes, 0, 0)  # Register before launch: an immediate exit is observable.
                    launched = subprocess.run([tmux, "-L", "gui", "new-window", "-d", "-t", "gui:",
                                               "-P", "-F", "#{pane_pid} #{pane_id}",
                                               "-n", "run:" + Path(argv[0]).name,
                                               shlex.join(["/bin/zsh", str(script)])],
                                              stdout=subprocess.PIPE, text=True)
                    if launched.returncode:
                        retained("GUI command launch failed")
                        return 71
                    try:
                        pid_text, pane = launched.stdout.strip().split()
                        pid = int(pid_text)
                        if pid <= 0:
                            raise ValueError()
                    except ValueError:
                        retained("GUI command launch returned invalid process metadata")
                        return 71
                    exited = False
                    try:
                        queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                                     flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                                     fflags=select.KQ_NOTE_EXIT)], 0, 0)
                    except ProcessLookupError:
                        # A short command may exit before its process watch is installed. Check done first below.
                        exited = True

                    def drain():
                        while chunk := stream.read(65536):
                            sys.stdout.buffer.write(chunk)
                            sys.stdout.buffer.flush()

                    while True:
                        drain()
                        if done.exists():
                            # EXIT published completion after all foreground command output. Drain once more.
                            drain()
                            result = int(done.read_text().strip())
                            successful = True
                            return result
                        if exited:
                            retained("GUI process exited without publishing its completion status")
                            return 71
                        remaining = deadline - time.monotonic()
                        events = queue.control(None, 3, max(0, remaining)) if remaining > 0 else []
                        if not events:
                            retained("GUI command timed out")
                            return 124
                        exited = any(event.filter == select.KQ_FILTER_PROC for event in events)
                finally:
                    queue.close()
            finally:
                os.close(directory)
    except Interrupted as error:
        retained(f"GUI watcher interrupted by {signal.Signals(error.signum).name}")
        return 128 + error.signum
    except KeyboardInterrupt:
        retained("GUI watcher interrupted by SIGINT")
        return 130
    except BrokenPipeError:
        retained("GUI watcher output pipe closed")
        # Prevent Python's final stdout flush from replacing the intended status with another BrokenPipe error.
        with open(os.devnull, "wb") as discard:
            os.dup2(discard.fileno(), sys.stdout.fileno())
        return 141
    finally:
        for number, handler in handlers.items():
            signal.signal(number, handler)
        if successful:
            shutil.rmtree(root)


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
