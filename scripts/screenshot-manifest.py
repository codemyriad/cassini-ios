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
    "10-note-export": ("Note export menu", "NoteExport", "test10NoteExport", "reading"),
    "11-library-export": ("Library export menu", "LibraryExport", "test11LibraryExport", "reading"),
    "12-delete-dialog": ("Delete confirmation", "DeleteDialog", "test12DeleteDialog", "trash"),
    "13-error-line": ("Transcription error", "ErrorLine", "test13ErrorLine", "brandSpeakers"),
    "14-success-badge": ("Finished meeting row", "Row-iOS", "test14SuccessBadge", "brandSpeakers"),
    "15-seven-speaker-meeting": ("Seven-speaker meeting", "Meeting", "test15SevenSpeakerMeeting", "brandSpeakers"),
    "16-seven-speaker-colours": ("Seven speaker colours", "Speakers", "test16SevenSpeakerColours", "brandSpeakers"),
    "17-status-badges": ("Status badges", "StatusBadges", "test17StatusBadges", "badge-gallery"),
    "18-meeting-find": ("Find in meeting", "Meeting-iOSFind", "test18MeetingFind", "reading"),
    "19-meeting-scrolled": ("Scrolled meeting", "Meeting-iOSScrolled", "test19MeetingScrolled", "long"),
    "20-library-scrolled": ("Scrolled Library", "Library-iOSScrolled", "test20LibraryScrolled", "statuses"),
    "21-one-speaker-row": ("One-speaker row", "Row-iOS", "test21OneSpeakerRow", "oneSpeaker"),

    "22-transcription-settings": ("Transcription settings", "P2Transcription-Phones", "test22TranscriptionSettings", "voices"),
    "23-speaker-settings": ("Speaker settings", "P2Speakers-Phones", "test23SpeakerSettings", "voices"),
    "24-about-settings": ("About", "P2About-Phones", "test24AboutSettings", "voices"),

    "25-backup-settings": ("Backup", "P2Backup-Phones", "test25BackupSettings", "voices"),
    "26-backup-details": ("Backup details", "P2BackupDetails-Phones", "test26BackupDetails", "voices"),
    "27-backup-notice": ("Backup notice", "P2BackupNote-Phones", "test27BackupNotice", "library"),

    "28-first-run": ("First run", "P2FirstRun-Phones", "test28FirstRun", "empty"),
    "29-voices-question": ("Voices question", "P2Voices-Phones", "test29VoicesQuestion", "speakers"),
    "31-first-run-largest-text": ("First run, largest text", "P2FirstRun-Phones", "test31FirstRunLargestText", "empty"),
    "30-model-download": ("Model download", "P2Download-Phones", "test30ModelDownload", "library"),
    "32-library-largest-text": ("Library, largest text", "Main", "test32LibraryLargestText", "search"),
    "33-read-and-listen-largest-text": ("Read and listen, largest text", "Meeting", "test33ReadAndListenLargestText", "brandSpeakers"),
    "34-meeting-long-press-menu": ("Meeting long-press menu", "LibraryMenu", "test34MeetingLongPressMenu", "brandSpeakers"),
    "35-meeting-more-menu": ("Meeting more menu", "NoteMenu", "test35MeetingMoreMenu", "brandSpeakers"),

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
        label, board, test, seed = SHOTS.get(file.stem, (file.stem[3:].replace('-', ' ').capitalize(), None, None, None))
        data = file.read_bytes()[:24]
        if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR" or len(data) != 24:
            raise ValueError(f"not a PNG: {relative}")
        width, height = struct.unpack(">II", data[16:24])
        rows.append(dict(path=relative.as_posix(), file=relative.as_posix(), screen=file.stem[3:], label=label, board=board,
                         scheme=scheme, lang=locale, device=device, locale=region, seed=seed,
                         test=f"CassiniUITests/ScreenshotTests/{test}" if test else None, pixel_width=width, pixel_height=height))
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
