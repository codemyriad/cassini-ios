#!/usr/bin/env python3
"""Download the models of scripts/ci-models.json from dist.gocassini.com into a model root with the app's layout.

Usage: scripts/fetch-ci-models.py [--dest DIR] [--print-key | --print-path ID | --ready ID... | --check-live]

The default DIR is .tools/ci-models (gitignored). Each model goes into DIR/models/<id>/<source_sha256>/, as the app
installs it into Application Support/CassiniModels (D4): every file comes as its own seekable Zstandard object, which
is resumed with Range and If-Range (the host's entity tag is the quoted SHA-256 of the compressed file) and asked for
with Accept-Encoding: identity. A 200 restarts from zero whatever its entity tag; a 206 without that tag or with another
range, and a 416, delete the part, so the next attempt starts clean; a 206 that stops short of the end, or an answer cut
off before its announced length, keeps its bytes for the next attempt. The file's SHA-256 is checked, then it is
decompressed and the decompressed size and SHA-256 are checked. The files and the host's NOTICE.txt are collected in
DIR/models/<id>/.<source_sha256>.staging/, which is renamed into place once complete. Files that are already correct are not downloaded again, so a restored cache costs
only the hash checks. Only https://dist.gocassini.com is contacted, and no redirect is followed. The env-gated
simulator tests (scripts/sherpa-bench.sh, scripts/speaker-smoke.sh) read the models from DIR.
It needs Python 3.10 or later, and the zstd tool before Python 3.14.

--print-key   prints a cache key made from the pins and the SHA-256 values of the list, and downloads nothing.
--print-path  prints the revision directory of the model ID under DIR, and downloads nothing.
--ready       exits 0 when every model ID named is installed under DIR (its files at their pinned sizes and a
              NOTICE.txt), 1 otherwise; downloads nothing.
--check-live  reads the live manifest (a small GET) and fails when its entries for the pins differ from the list;
              prints the SHA-256 of the live NOTICE.txt. Never run by scripts/test.sh.
"""

import argparse
import hashlib
import http.client
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "scripts/ci-models.json"
HOST = "dist.gocassini.com"
BASE = f"https://{HOST}"
ATTEMPTS = 3
CHUNK = 1024 * 1024
NOTICE = "NOTICE.txt"
NOTICE_MAX = 2 << 20
MANIFEST_MAX = 1 << 20


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """The model host answers without redirects; any redirect fails, as the app's allow-list has only the host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SystemExit(f"{req.full_url} redirects to {newurl}; only {BASE} is allowed.")


OPENER = urllib.request.build_opener(NoRedirect)


def allowed(url: str) -> str:
    if not url.startswith(BASE + "/"):
        raise SystemExit(f"{url} is not on {BASE}.")
    return url


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def matches(path: Path, pin: dict) -> bool:
    return path.is_file() and path.stat().st_size == pin["size"] and sha256(path) == pin["sha256"]


def read(url: str, limit: int) -> bytes:
    request = urllib.request.Request(allowed(url), headers={"User-Agent": "cassini-ios-ci", "Accept-Encoding": "identity"})
    with OPENER.open(request, timeout=60) as response:
        if response.headers.get("Content-Encoding", "identity").lower() != "identity":
            raise SystemExit(f"{url} came encoded.")
        body = response.read(limit + 1)
    if len(body) > limit:
        raise SystemExit(f"{url} is longer than {limit} bytes.")
    return body


def continues(content_range: str, offset: int, size: int) -> bool:
    """Whether a 206's Content-Range starts at `offset`, ends inside the file and has its pinned `size` as total (a host
    may cap an open-ended range; the next attempt resumes after it)."""
    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", content_range.strip())
    return bool(match) and int(match[1]) == offset and offset <= int(match[2]) < size and int(match[3]) == size


def download(pin: dict, partial: Path) -> None:
    """Downloads the compressed file `pin` into `partial`, resuming its bytes when the host still has the same file."""
    url, tag = allowed(pin["url"]), f'"{pin["sha256"]}"'
    for attempt in range(1, ATTEMPTS + 1):
        if partial.exists() and partial.stat().st_size > pin["size"]:
            partial.unlink()
        offset = partial.stat().st_size if partial.exists() else 0
        if offset == pin["size"]:
            return
        headers = {"User-Agent": "cassini-ios-ci", "Accept-Encoding": "identity"}
        if offset:
            headers.update({"Range": f"bytes={offset}-", "If-Range": tag})
        print(f"Downloading {url} from byte {offset} (attempt {attempt} of {ATTEMPTS})", flush=True)
        try:
            with OPENER.open(urllib.request.Request(url, headers=headers), timeout=60) as response:
                if response.headers.get("Content-Encoding", "identity").lower() != "identity":
                    raise SystemExit(f"{url} came encoded.")
                etag = response.headers.get("ETag")
                if response.status == 206:
                    if etag != tag or not continues(response.headers.get("Content-Range", ""), offset, pin["size"]):
                        # Not this file's bytes from the offset: the next attempt starts from zero.
                        partial.unlink(missing_ok=True)
                        raise OSError(f"a partial answer for another file or range ({etag}); the part is deleted")
                    mode = "ab"
                elif response.status == 200:
                    # A whole answer restarts from zero whatever its entity tag (a proxy may strip it): the size and
                    # SHA-256 checks decide whether it is the file.
                    mode = "wb"
                else:
                    raise SystemExit(f"{url}: HTTP {response.status}")
                with partial.open(mode) as output:
                    shutil.copyfileobj(response, output, CHUNK)
                # http.client ends a body cut off before its Content-Length without an error; `length` keeps the rest.
                ended = not response.length
            if partial.stat().st_size == pin["size"]:
                return
            if mode == "wb" and ended:
                # A whole answer that ended at its announced length at another size is not the file (a captive
                # portal): start over. One cut off early, or a capped range, keeps its bytes for the next attempt.
                partial.unlink()
            print(f"The download stopped at byte {partial.stat().st_size if partial.exists() else 0}", flush=True)
        except urllib.error.HTTPError as error:
            # An unsatisfiable range: the part does not fit the file served, so the next attempt starts from zero.
            # Other errors keep the part.
            if error.code == 416:
                partial.unlink(missing_ok=True)
            if attempt == ATTEMPTS:
                raise SystemExit(f"Cannot download {url}: {error}") from error
            print(f"The download failed: {error}", flush=True)
        except (OSError, http.client.HTTPException) as error:
            if attempt == ATTEMPTS:
                raise SystemExit(f"Cannot download {url}: {error}") from error
            print(f"The download failed: {error}", flush=True)
        time.sleep(10 * attempt)
    raise SystemExit(f"Cannot download {url}.")


def decompress(source: Path, target: Path) -> None:
    try:
        from compression import zstd  # Python 3.14+

        with zstd.open(source, "rb") as data, target.open("wb") as output:
            shutil.copyfileobj(data, output, CHUNK)
    except ImportError:
        try:
            subprocess.run(["zstd", "-q", "-d", "-f", str(source), "-o", str(target)], check=True)
        except FileNotFoundError:
            raise SystemExit(f"Install the zstd tool (or use Python 3.14 or later) to unpack {source.name}.") from None


def revision(model: dict, dest: Path) -> Path:
    return dest / model["directory"]


def ready(model: dict, dest: Path) -> bool:
    home = revision(model, dest)
    notice = home / NOTICE
    return notice.is_file() and notice.stat().st_size > 0 and all(
        (home / a["name"]).is_file() and (home / a["name"]).stat().st_size == a["size"] for a in model["artifacts"])


def install(model: dict, notice: bytes, dest: Path) -> None:
    home = revision(model, dest)
    if ready(model, dest) and all(matches(home / a["name"], a) for a in model["artifacts"]):
        print(f"Ready: {model['directory']}")
        return
    staging = home.parent / f".{model['sourceSha256']}.staging"
    staging.mkdir(parents=True, exist_ok=True)
    for artifact in model["artifacts"]:
        target = staging / artifact["name"]
        if matches(target, artifact):
            continue
        packed = artifact["download"]
        compressed = staging / f"{packed['sha256']}.part"
        download(packed, compressed)
        if not matches(compressed, packed):
            compressed.unlink()
            raise SystemExit(f"{packed['url']} does not have the pinned size and SHA-256.")
        unpacked = staging / f"{artifact['sha256']}.part"
        decompress(compressed, unpacked)
        if not matches(unpacked, artifact):
            unpacked.unlink()
            raise SystemExit(f"{target.name} does not have the pinned size and SHA-256 after decompression.")
        unpacked.replace(target)
        compressed.unlink()
    (staging / NOTICE).write_bytes(notice)
    keep = {a["name"] for a in model["artifacts"]} | {NOTICE}
    for leftover in staging.iterdir():
        if leftover.name not in keep:
            leftover.unlink()
    if home.exists():
        retired = home.parent / f".remove-{uuid.uuid4()}"
        home.rename(retired)
        shutil.rmtree(retired)
    staging.rename(home)
    print(f"Installed: {model['directory']}")


def check_live(listed: dict) -> None:
    manifest = json.loads(read(listed["manifest"], MANIFEST_MAX))
    if manifest.get("schema_version") != 2 or manifest.get("base_url") != BASE:
        raise SystemExit("The live manifest is not schema 2 of the model host.")
    entries = {a["key"]: a for a in manifest["artifacts"]}
    problems = []
    for model in listed["models"]:
        rows = [r for r in manifest["models"] if r["id"] == model["id"] and r["source_sha256"] == model["sourceSha256"]]
        if len(rows) != 1:
            problems.append(f"{model['id']}@{model['sourceSha256']} is not listed")
            continue
        paths = {f["path"]: f["artifact"] for f in rows[0]["files"] if f.get("required", True)}
        if set(paths) != {a["name"] for a in model["artifacts"]}:
            problems.append(f"{model['id']}: the live files are {sorted(paths)}")
            continue
        for artifact in model["artifacts"]:
            packed = artifact["download"]
            key = f"models/files/{packed['sha256']}/{artifact['name']}.zst"
            entry = entries.get(paths[artifact["name"]]) if paths[artifact["name"]] == key else None
            live = entry and (entry["url"], entry["size"], entry["sha256"], entry["uncompressed_size"],
                              entry["uncompressed_sha256"], entry.get("encoding"), entry.get("format_version"))
            pinned = (packed["url"], packed["size"], packed["sha256"], artifact["size"], artifact["sha256"],
                      "zstd-seekable", "0.1.0")
            if live != pinned:
                problems.append(f"{model['id']}: {artifact['name']} differs from the pins")
    notice = read(listed["notice"], NOTICE_MAX)
    print(f"Live NOTICE.txt: {len(notice)} bytes, sha256 {hashlib.sha256(notice).hexdigest()}")
    if problems:
        raise SystemExit("The live manifest differs from scripts/ci-models.json:\n" + "\n".join(problems))
    print("The live manifest has every pin of scripts/ci-models.json.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", type=Path, default=ROOT / ".tools/ci-models")
    parser.add_argument("--print-key", action="store_true")
    parser.add_argument("--print-path", metavar="ID")
    parser.add_argument("--ready", metavar="ID", nargs="+")
    parser.add_argument("--check-live", action="store_true")
    arguments = parser.parse_args()
    listed = json.loads(MODELS.read_text(encoding="utf-8"))
    models = {m["id"]: m for m in listed["models"]}
    if arguments.print_key:
        pins = [f"{m['id']}@{m['sourceSha256']}" for m in listed["models"]]
        digests = [a["download"]["sha256"] for m in listed["models"] for a in m["artifacts"]]
        print("models-" + hashlib.sha256("\n".join(sorted(pins) + digests).encode()).hexdigest()[:32])
        return
    if arguments.print_path:
        print(revision(models[arguments.print_path], arguments.dest))
        return
    if arguments.ready:
        sys.exit(0 if all(ready(models[i], arguments.dest) for i in arguments.ready) else 1)
    if arguments.check_live:
        check_live(listed)
        return
    notice = read(listed["notice"], NOTICE_MAX)
    if not notice:
        raise SystemExit(f"{listed['notice']} is empty.")
    for model in listed["models"]:
        install(model, notice, arguments.dest)


if __name__ == "__main__":
    main()
