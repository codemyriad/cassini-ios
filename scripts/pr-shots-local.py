#!/usr/bin/env python3
"""Render a local base/head pair. Publishing is exclusively the coordinator's job."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def run_render(command, **kwargs):
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        code = process.wait()
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=30)  # Cancellation hang guard, never a successful wait condition.
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    if code:
        raise subprocess.CalledProcessError(code, command)


def render(head, base_ref, out, diff_tool=None):
    if os.environ.get("CASSINI_HEAVY_LOCK_HELD") == "1":
        raise ValueError("run outside the heavy lock; each screenshots.sh acquires it")
    head = head.resolve()
    sha = git(head, "rev-parse", "HEAD")
    if git(head, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("commit tracked changes before rendering: source SHAs must describe the UI")
    base_sha = git(head, "merge-base", base_ref, sha)
    out.mkdir(parents=True, exist_ok=False)
    session = uuid.uuid4().hex
    env = dict(os.environ, CASSINI_SIM_PREFIX="ts-prshots-" + session[:12], CASSINI_SHOTS_QUANTIZE="0",
               CASSINI_SHOTS_RUN_ID=session, CASSINI_SHOTS_RENDERER_SHA=sha,
               CASSINI_HEAVY_LOCK=os.environ.get("CASSINI_HEAVY_LOCK", str(Path.home() / ".scw-heavy.lock")))
    # Each screenshots.sh owns the host lock itself; never acquire a second non-reentrant lock here.
    env.pop("CASSINI_HEAVY_LOCK_HELD", None)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="cassini-prshots-") as temporary:
        base = Path(temporary) / "base"
        subprocess.run(["git", "-C", str(head), "worktree", "add", "--detach", str(base), base_sha], check=True)
        try:
            for name in ("screenshots.sh", "screenshot-manifest.py"):
                shutil.copy2(head / "scripts" / name, base / "scripts" / name)
            manifests = {}
            for side, tree in (("after", head), ("before", base)):
                print(f"Rendering {side}: {sha if side == 'after' else base_sha}", flush=True)
                with (out / f"{side}.log").open("w") as log:
                    run_render([str(tree / "scripts/screenshots.sh"), "--output", str(out / side)], cwd=tree,
                               env=env, stdout=log, stderr=subprocess.STDOUT)
                manifests[side] = json.loads((out / side / "shots.json").read_text())
                expected = sha if side == "after" else base_sha
                if manifests[side]["source_sha"] != expected:
                    raise ValueError(f"{side} renderer reported the wrong source SHA")
            for key in ("xcode", "image_version", "devices"):
                if manifests["before"][key] != manifests["after"][key]:
                    raise ValueError(f"render environments differ: {key}")
            report = dict(version=1, app="ios", base_sha=base_sha, head_sha=sha, run_id=session,
                          elapsed_seconds=round(time.monotonic() - started, 3), diff="pending canonical pr-shots.py")
            tool = diff_tool or head / "scripts/pr-shots.py"
            if tool.is_file():
                subprocess.run([sys.executable, "-I", str(tool), "diff", "--layout", "ios", "--before-dir",
                                str(out / "before"), "--after-dir", str(out / "after"), "--out", str(out / "pr-shots")], check=True)
                report["diff"] = "pr-shots"
            elif diff_tool:
                raise FileNotFoundError(tool)
            (out / "render.json").write_text(json.dumps(report, indent=2) + "\n")
        finally:
            # Only the private worktree/unique simulator prefix created by this invocation is removed.
            try:
                subprocess.run([str(head / "scripts/test.sh"), "clean"], cwd=head, env=env, check=True)
            finally:
                subprocess.run(["git", "-C", str(head), "worktree", "remove", "--force", str(base)], check=True)
    print(f"Render pair: {out}", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--head", type=Path, default=Path(__file__).resolve().parent.parent, help="head worktree")
    p.add_argument("--base", default="origin/main", help="ref whose merge base with head is rendered")
    p.add_argument("--out", type=Path, required=True, help="new output folder")
    p.add_argument("--diff-tool", type=Path, help="canonical tool, once merged; never publish")
    a = p.parse_args()
    render(a.head, a.base, a.out.resolve(), a.diff_tool.resolve() if a.diff_tool else None)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(128 + number))
    main()
