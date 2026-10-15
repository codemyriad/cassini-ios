#!/usr/bin/env python3
"""Make the two-speaker fixture of the speaker smoke test (scripts/speaker-smoke.sh) from two public FLEURS clips.

Usage: scripts/fetch-speaker-fixture.py --android DIR [--dest DIR]

Android has no public meeting recording, so this mixes two FLEURS it_it dev clips (CC-BY-4.0, Google FLEURS
contributors, revision 70bb2e84b976b7e960aa89f1c648e09c59f894dd) of two different speakers:
  A  10017639081645832204.wav (female; Android's fixtures/audio/fleurs-it-short.wav, read from the checkout)
  B  12260888470575533291.wav (male; streamed out of dev.tar.gz, which is read only up to that file)
into A, 0.5 s of silence, B, 0.5 s of silence, A again: 16 kHz mono PCM16 (B's 32-bit float samples rounded to
16 bits), with no other edit. It writes DIR/fleurs-two-speakers.wav and DIR/fleurs-two-speakers.json (the three
spans in milliseconds and their speakers).
Every input and the output are checked against the SHA-256 pins below. The default DIR is .tools/fixtures
(gitignored); audio is never committed.
"""

import argparse
import hashlib
import io
import json
import struct
import tarfile
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
ARCHIVE = f"https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data/it_it/audio/dev.tar.gz"
A = ("10017639081645832204.wav", "645193ec85e7945fe992ca287bac0f2d233ea2f7a552f3b3344596adefe8fe40")
B = ("12260888470575533291.wav", "b4b900d650deb6985c4f1bcf630715da8e6464a6d7cc6ec3144dce2c06f2a6e3")
OUTPUT = "fleurs-two-speakers"
OUTPUT_SHA256 = "1f9753c9126817b97b46c42e6977064c52d2e5c392827939d583bf9c5d88dc32"
RATE = 16000
GAP_FRAMES = RATE // 2


def checked(data: bytes, sha: str, name: str) -> bytes:
    actual = hashlib.sha256(data).hexdigest()
    if actual != sha:
        raise SystemExit(f"{name} has SHA-256 {actual}, the pin is {sha}.")
    return data


def frames(data: bytes, name: str) -> bytes:
    """The clip's samples as 16-bit PCM: PCM16 as it is, 32-bit float (FLEURS's raw clips) rounded and clipped."""
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise SystemExit(f"{name} is not a WAV file.")
    chunks, offset = {}, 12
    while offset + 8 <= len(data):
        size = struct.unpack_from("<I", data, offset + 4)[0]
        chunks.setdefault(data[offset:offset + 4], data[offset + 8:offset + 8 + size])
        offset += 8 + size + (size & 1)
    tag, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", chunks[b"fmt "])
    if tag == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE: the sub-format's first two bytes are the tag
        tag = struct.unpack_from("<H", chunks[b"fmt "], 24)[0]
    if (channels, rate) != (1, RATE):
        raise SystemExit(f"{name} is not 16 kHz mono.")
    body = chunks[b"data"]
    if (tag, bits) == (1, 16):
        return body
    if (tag, bits) == (3, 32):
        floats = struct.unpack(f"<{len(body) // 4}f", body)
        return struct.pack(f"<{len(floats)}h", *(max(-32768, min(32767, round(x * 32767))) for x in floats))
    raise SystemExit(f"{name} has WAV format {tag} with {bits} bits.")


def streamed(name: str) -> bytes:
    with urllib.request.urlopen(ARCHIVE, timeout=60) as response, tarfile.open(fileobj=response, mode="r|gz") as tar:
        for member in tar:
            if member.isfile() and member.name.rsplit("/", 1)[-1] == name:
                return tar.extractfile(member).read()
    raise SystemExit(f"{name} is not in {ARCHIVE}.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--android", required=True, type=Path, help="a cassini-android checkout")
    parser.add_argument("--dest", type=Path, default=ROOT / ".tools/fixtures")
    args = parser.parse_args()
    target = args.dest / f"{OUTPUT}.wav"
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == OUTPUT_SHA256:
        print(target)
        return
    a = frames(checked((args.android / "fixtures/audio/fleurs-it-short.wav").read_bytes(), A[1], A[0]), A[0])
    b = frames(checked(streamed(B[0]), B[1], B[0]), B[0])
    gap = bytes(2 * GAP_FRAMES)
    mixed = a + gap + b + gap + a
    output = io.BytesIO()
    with wave.open(output, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(mixed)
    data = checked(output.getvalue(), OUTPUT_SHA256, target.name)
    ms = lambda n: n * 1000 // RATE  # noqa: E731
    na, nb = len(a) // 2, len(b) // 2
    spans = [
        {"speaker": "A", "startMs": 0, "endMs": ms(na), "source": A[0]},
        {"speaker": "B", "startMs": ms(na + GAP_FRAMES), "endMs": ms(na + GAP_FRAMES + nb), "source": B[0]},
        {"speaker": "A", "startMs": ms(na + 2 * GAP_FRAMES + nb), "endMs": ms(2 * na + 2 * GAP_FRAMES + nb), "source": A[0]},
    ]
    args.dest.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    meta = {"source": ARCHIVE, "revision": REVISION, "license": "CC-BY-4.0",
            "attribution": "Google FLEURS contributors (https://huggingface.co/datasets/google/fleurs)",
            "sha256": OUTPUT_SHA256, "durationMs": ms(len(mixed) // 2), "spans": spans}
    (args.dest / f"{OUTPUT}.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(target)


if __name__ == "__main__":
    main()
