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


def verify_schemes(folder, rows):
    from PIL import Image
    pairs = {}
    for row in rows:
        pairs.setdefault((row['screen'], row['lang'], row['device']), set()).add(row['scheme'])
        # Recording deliberately forces a dark canvas in both appearances.
        if row['screen'] != 'recording':
            with Image.open(folder / row['path']) as image:
                rgb = image.convert('RGB').getpixel((8, 8))  # Unobscured canvas above the status bar.
            if (sum(rgb) > 3 * 128) != (row['scheme'] == 'light'):
                raise ValueError(f"appearance label disagrees with image: {row['path']}")
    if not pairs or any(schemes != {'light', 'dark'} for schemes in pairs.values()):
        raise ValueError('each screen/language/device needs a light/dark pair')


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


def render(head, base_ref, out, diff_tool=None, pr=None, repo="codemyriad/cassini-ios", render_only=False):
    if os.environ.get("CASSINI_HEAVY_LOCK_HELD") == "1":
        raise ValueError("run outside the heavy lock; each screenshots.sh acquires it")
    head = head.resolve()
    sha = git(head, "rev-parse", "HEAD")
    if git(head, "status", "--porcelain"):
        raise ValueError("commit changes and remove untracked files before rendering: source SHAs must describe the UI")
    if out == head or head in out.parents:
        raise ValueError("put the output folder outside the head worktree")
    base_sha = git(head, "merge-base", base_ref, sha)
    tool = None if render_only else diff_tool or head / "scripts/pr-shots.py"
    if diff_tool and not diff_tool.is_file():
        raise FileNotFoundError(diff_tool)
    if tool and tool.is_file() and (pr is None or pr < 1):
        raise ValueError("--pr is required for the canonical diff (or use --render-only)")
    if tool and tool.is_file():
        from PIL import Image  # Fail before expensive rendering if the diff environment is missing.
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
        try:
            subprocess.run(["git", "-C", str(head), "worktree", "add", "--detach", str(base), base_sha], check=True)
            for name in ("scripts/screenshots.sh", "scripts/screenshot-manifest.py", "CassiniUITests/ScreenshotTests.swift"):
                shutil.copy2(head / name, base / name)
            manifests = {}
            for side, tree in (("after", head), ("before", base)):
                print(f"Rendering {side}: {sha if side == 'after' else base_sha}", flush=True)
                with (out / f"{side}.log").open("w") as log:
                    try:
                        run_render([str(tree / "scripts/screenshots.sh"), "--output", str(out / side)], cwd=tree,
                                   env=env, stdout=log, stderr=subprocess.STDOUT)
                    finally:
                        diagnostics = out / "logs" / side
                        diagnostics.mkdir(parents=True, exist_ok=True)
                        for file in (tree / "DerivedData.noindex/screenshots").glob("*.log"):
                            shutil.copy2(file, diagnostics / file.name)
                manifests[side] = json.loads((out / side / "shots.json").read_text())
                expected = sha if side == "after" else base_sha
                if manifests[side]["source_sha"] != expected:
                    raise ValueError(f"{side} renderer reported the wrong source SHA")
            for key in ("xcode", "image_version", "devices"):
                if manifests["before"][key] != manifests["after"][key]:
                    raise ValueError(f"render environments differ: {key}")
            if git(head, "rev-parse", "HEAD") != sha or git(head, "status", "--porcelain"):
                raise ValueError("head changed during rendering; outputs are diagnostic only")
            report = dict(version=1, app="ios", base_sha=base_sha, head_sha=sha, run_id=session,
                          repo=repo, pr=pr, diff="pending canonical pr-shots.py")
            if tool and tool.is_file():
                for side in ('before', 'after'):
                    verify_schemes(out / side, manifests[side]['shots'])
                command = [sys.executable, "-I", str(tool), "diff", "--layout", "ios", "--repo", repo,
                           "--pr", str(pr), "--before-dir", str(out / "before"), "--after-dir", str(out / "after"),
                           "--out", str(out / "pr-shots")]
                for side, source_sha in (("before", base_sha), ("after", sha)):
                    prefix = 'base' if side == 'before' else 'head'
                    m = manifests[side]
                    versions = sorted({v["runtime_version"] for v in m["devices"].values() if isinstance(v, dict)})
                    image = m["image_version"] + "; " + m["xcode"].replace("\n", "; ") + "; iOS " + ",".join(versions)
                    command += [f"--{prefix}-sha", source_sha, f"--{prefix}-run", session,
                                f"--{prefix}-runner", m.get("runner_label", "local"), f"--{prefix}-image", image]
                subprocess.run(command, check=True)
                report["diff"] = "pr-shots"
        finally:
            # Only the private worktree/unique simulator prefix created by this invocation is removed.
            try:
                subprocess.run([str(head / "scripts/test.sh"), "clean"], cwd=head, env=env, check=True)
            finally:
                records = git(head, "worktree", "list", "--porcelain").splitlines()
                if any(line.startswith("worktree ") and Path(line[9:]).resolve() == base.resolve() for line in records):
                    subprocess.run(["git", "-C", str(head), "worktree", "remove", "--force", "--force", str(base)], check=True)
    report["elapsed_seconds"] = round(time.monotonic() - started, 3)
    (out / "render.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Render pair: {out}", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--head", type=Path, default=Path(__file__).resolve().parent.parent, help="head worktree")
    p.add_argument("--base", default="origin/main", help="ref whose merge base with head is rendered")
    p.add_argument("--out", type=Path, required=True, help="new output folder")
    p.add_argument("--pr", type=int, help="PR number, required only for canonical diff")
    p.add_argument("--repo", default="codemyriad/cassini-ios")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--diff-tool", type=Path, help="canonical tool, once merged; never publish")
    mode.add_argument("--render-only", action="store_true", help="render without the optional canonical diff")
    a = p.parse_args()
    render(a.head, a.base, a.out.resolve(), a.diff_tool.resolve() if a.diff_tool else None, a.pr, a.repo, a.render_only)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(128 + number))
    main()
