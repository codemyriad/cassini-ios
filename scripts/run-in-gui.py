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
import subprocess
import sys
import tempfile
import time


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
    with output.open("rb", buffering=0) as stream:
        directory = os.open(root, os.O_RDONLY)
        try:
            queue = select.kqueue()
            try:
                changes = [select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                         flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                         fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)
                           for fd in (stream.fileno(), directory)]
                queue.control(changes, 0, 0)  # Register before launch: even an immediate exit is observable.
                launched = subprocess.run([tmux, "-L", "gui", "new-window", "-d", "-t", "gui:",
                                           "-n", "run:" + Path(argv[0]).name,
                                           shlex.join(["/bin/zsh", str(script)])])
                if launched.returncode:
                    return 71
                while True:
                    while chunk := stream.read(65536):
                        sys.stdout.buffer.write(chunk)
                        sys.stdout.buffer.flush()
                    if done.exists():
                        # The command exited before completion was published; drain its remaining output.
                        while chunk := stream.read(65536):
                            sys.stdout.buffer.write(chunk)
                            sys.stdout.buffer.flush()
                        result = int(done.read_text().strip())
                        successful = True
                        return result
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not queue.control(None, 2, remaining):
                        print(f"GUI command timed out; it continues in tmux gui. Log: {output}", file=sys.stderr)
                        return 124
            finally:
                queue.close()
        finally:
            os.close(directory)
            if successful:
                shutil.rmtree(root)


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
