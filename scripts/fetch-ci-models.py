#!/usr/bin/env python3
"""Download the models of scripts/ci-models.json into a directory with the layout of the app's files/.

Usage: scripts/fetch-ci-models.py [--dest DIR] [--print-key]

The default DIR is .tools/ci-models (gitignored). Each model goes into DIR/<directory>/ and gets its marker file after
every file has its pinned size and SHA-256, as the app installs it into Application Support/CassiniModels. Files that
are already correct are not downloaded again, so a restored cache costs only the hash checks. The env-gated simulator
tests (scripts/sherpa-bench.sh) can read the models from DIR. This is Android's script with the same list.
It needs Python 3.10 or later, and the zstd tool before Python 3.14.
--print-key prints a cache key made from the SHA-256 values of the list and downloads nothing.
"""

import argparse
import hashlib
import http.client
import json
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "scripts/ci-models.json"
ATTEMPTS = 3
CHUNK = 1024 * 1024


def matches(path: Path, artifact: dict) -> bool:
    if not path.is_file() or path.stat().st_size != artifact["size"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest() == artifact["sha256"]


def download(artifact: dict, target: Path) -> None:
    partial = target.with_name(target.name + ".part")
    request = urllib.request.Request(artifact["url"], headers={"User-Agent": "cassini-ios-ci"})
    for attempt in range(1, ATTEMPTS + 1):
        print(f"Downloading {artifact['url']} (attempt {attempt} of {ATTEMPTS})", flush=True)
        partial.unlink(missing_ok=True)
        try:
            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
                shutil.copyfileobj(response, output, CHUNK)
            break
        except (OSError, http.client.HTTPException) as error:
            partial.unlink(missing_ok=True)
            if attempt == ATTEMPTS:
                raise SystemExit(f"Cannot download {artifact['url']}: {error}") from error
            print(f"The download failed: {error}", flush=True)
            time.sleep(10 * attempt)
    if not matches(partial, artifact):
        partial.unlink()
        raise SystemExit(f"{artifact['url']} does not have the pinned size and SHA-256.")
    partial.replace(target)


def decompress(source: Path, target: Path) -> None:
    partial = target.with_name(target.name + ".part")
    try:
        from compression import zstd  # Python 3.14+

        with zstd.open(source, "rb") as data, partial.open("wb") as output:
            shutil.copyfileobj(data, output, CHUNK)
    except ImportError:
        try:
            subprocess.run(["zstd", "-q", "-d", "-f", str(source), "-o", str(partial)], check=True)
        except FileNotFoundError:
            raise SystemExit(f"Install the zstd tool (or use Python 3.14 or later) to unpack {source.name}.") from None
    partial.replace(target)


def install(model: dict, dest: Path) -> None:
    home = dest / model["directory"]
    home.mkdir(parents=True, exist_ok=True)
    marker = home / model["marker"]
    for artifact in model["artifacts"]:
        target = home / artifact["name"]
        if matches(target, artifact):
            continue
        marker.unlink(missing_ok=True)
        packed = model.get("download")
        if packed:
            compressed = dest / ".downloads" / packed["name"]
            compressed.parent.mkdir(exist_ok=True)
            if not matches(compressed, packed):
                download(packed, compressed)
            decompress(compressed, target)
            compressed.unlink()
            if not matches(target, artifact):
                raise SystemExit(f"{target} does not have the pinned size and SHA-256 after decompression.")
        else:
            download(artifact, target)
    marker.write_text(model["markerValue"], encoding="utf-8")
    print(f"Ready: {model['directory']}/{model['marker']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", type=Path, default=ROOT / ".tools/ci-models")
    parser.add_argument("--print-key", action="store_true")
    arguments = parser.parse_args()
    models = json.loads(MODELS.read_text(encoding="utf-8"))["models"]
    if arguments.print_key:
        digests = [a["sha256"] for m in models for a in m["artifacts"] + ([m["download"]] if "download" in m else [])]
        print("models-" + hashlib.sha256("\n".join(digests).encode()).hexdigest()[:32])
        return
    for model in models:
        install(model, arguments.dest)
    shutil.rmtree(arguments.dest / ".downloads", ignore_errors=True)


if __name__ == "__main__":
    main()
