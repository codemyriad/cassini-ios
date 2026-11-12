#!/usr/bin/env python3
"""Explicit W0.8 screenshot inventory; standard library only, no image recompression."""
import argparse
import json
import os
from pathlib import Path
import platform
import struct
import subprocess

# filename: (label, gallery board, XCTest method, seed)
SHOTS = {
    "01-library": ("Library", "Main", "test01Library", "search"),
    "02-read-and-listen": ("Read and listen", "Meeting", "test02ReadAndListen", "reading"),
    "03-transcribing": ("Transcribing", "Transcribing", "test03Transcribing", "processing"),
    "04-name-a-speaker": ("Name a speaker", "Speakers", "test04NameASpeaker", "speakers"),
    "05-settings": ("Settings", "Settings", "test05Settings", "library"),
    "06-recording": ("Recording", "Recording", "test06Recording", "recording"),
    "07-search": ("Search", "Search", "test07Search", "search"),
    "08-recently-deleted": ("Recently deleted", "Trash", "test08RecentlyDeleted", "trash"),
    "09-saved-voices": ("Saved voices", "SavedVoices", "test09SavedVoices", "voices"),
    "01-split-landscape": ("Split view landscape", "Meeting", "testSplitViewLandscape", "reading"),
    "02-split-portrait": ("Split view portrait", "Meeting", "testSplitViewPortrait", "reading"),
}


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def inventory(out, files, locale, region):
    rows = []
    for file in files:
        relative = file.resolve().relative_to(out.resolve())
        device = "ipad" if relative.parts[0] == "ipad" else "iphone"
        scheme = relative.parts[-2]
        if scheme not in ("light", "dark"):
            raise ValueError(f"unknown appearance: {relative}")
        label, board, test, seed = SHOTS[file.stem]
        data = file.read_bytes()[:24]
        if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR" or len(data) != 24:
            raise ValueError(f"not a PNG: {relative}")
        width, height = struct.unpack(">II", data[16:24])
        rows.append(dict(path=relative.as_posix(), file=relative.as_posix(), screen=file.stem[3:], label=label, board=board,
                         scheme=scheme, lang=locale, device=device, locale=region, seed=seed,
                         test=f"CassiniUITests/ScreenshotTests/{test}", pixel_width=width, pixel_height=height))
    keys = [(r["screen"], r["scheme"], r["lang"], r["device"]) for r in rows]
    if not rows or len(keys) != len(set(keys)):
        raise ValueError("empty or duplicate screenshot inventory")
    return sorted(rows, key=lambda r: (r["device"], r["file"]))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "output", "written", "prefix", "locale", "region"):
        p.add_argument("--" + name, required=True)
    a = p.parse_args()
    root, out = Path(a.root), Path(a.output)
    rows = inventory(out, [Path(x) for x in Path(a.written).read_text().splitlines()], a.locale, a.region)
    devices = json.loads(capture("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    runtime_info = json.loads(capture("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    selected = {}
    for runtime, entries in devices.items():
        for entry in entries:
            for device in ("iphone", "ipad"):
                if entry["name"] == f"{a.prefix}-shots-{device}":
                    selected[device] = dict(udid=entry["udid"], type=entry["deviceTypeIdentifier"], runtime=runtime,
                                           runtime_version=next(r["version"] for r in runtime_info if r["identifier"] == runtime),
                                           runtime_build=next(r["buildversion"] for r in runtime_info if r["identifier"] == runtime))
    manifest = dict(version=1, app="ios", source_sha=capture("git", "-C", str(root), "rev-parse", "HEAD"),
                    renderer_sha=os.environ.get("CASSINI_SHOTS_RENDERER_SHA"),
                    run_id=os.environ.get("CASSINI_SHOTS_RUN_ID"), runner_label=f"macOS-{platform.machine()}",
                    image_version=f"macOS {platform.mac_ver()[0]}", xcode=capture("xcodebuild", "-version"),
                    devices=selected, clock="2026-10-08T09:41:00Z", timezone="UTC", max_pixel_dimension=1200,
                    quantized=os.environ.get("CASSINI_SHOTS_QUANTIZE", "0") != "0", shots=rows)
    temporary = out / "shots.json.tmp"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(out / "shots.json")


if __name__ == "__main__":
    main()
