#!/usr/bin/env python3
"""Build-time only: pin-check, strict-link and embed the private D75.2 runtime.

Run as an Xcode build phase, under the build's heavy-job lock on drmeyers.
No source load commands are changed; deployment warnings remain visible.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.request
from whistle_binary_identity import identity

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / "Whistle/pins.json").read_text())
EXPORTS = ["needle_load", "needle_models", "needle_last_error", "needle_transcribe", "needle_reset"]


def digest(path):
    hashed = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hashed.update(block)
    return hashed.hexdigest()


def verify(path, pin):
    if not path.is_file() or path.stat().st_size != pin["bytes"] or digest(path) != pin["sha256"]:
        raise ValueError(f"Whistle pinned input differs: {path.name}")


def fetch(cache, name, offline=False):
    pin = PINS["artifacts"][name]
    path = cache / name
    if path.exists():
        verify(path, pin)  # Corruption is an error, never silently replaced.
        return path
    if offline:
        raise FileNotFoundError(f"Whistle offline input absent: {name}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    try:
        with urllib.request.urlopen(pin["url"], timeout=120) as source, temporary.open("wb") as target:
            copied = 0
            for block in iter(lambda: source.read(1024 * 1024), b""):
                copied += len(block)
                if copied > pin["bytes"]:
                    raise ValueError(f"Whistle input exceeds pinned size: {name}")
                target.write(block)
        verify(temporary, pin)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def check_imports(kind, imports):
    evidence = json.loads((ROOT / "Whistle/sdk26-imports.json").read_text())
    if evidence["engineRevision"] != PINS["engineRevision"] or evidence["sourceArchiveSha256"][kind] != PINS["artifacts"][kind + "/libneedle.a"]["sha256"]:
        raise ValueError("Whistle archive changed without fresh SDK26 evidence")
    allowed = evidence["targets"][kind]
    missing = sorted(set(imports) - allowed.keys())
    if missing:
        raise ValueError(f"Whistle imports without SDK26 evidence: {missing}")


def run(command):
    print("Whistle:", " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True)


def bundle(cache, offline=False):
    env = os.environ
    sdk = env["SDKROOT"]
    platform = env["PLATFORM_NAME"]
    architectures = set(env["ARCHS"].split())
    app = Path(env["TARGET_BUILD_DIR"]) / env["WRAPPER_NAME"]
    framework = app / "Frameworks/CassiniWhistleRuntime.framework"
    resources = app / "Whistle"
    if architectures != {"arm64"} or platform not in {"iphoneos", "iphonesimulator"}:
        # There is no pinned x86_64 artifact. Never pretend another architecture can load arm64.
        shutil.rmtree(framework, ignore_errors=True)
        shutil.rmtree(resources, ignore_errors=True)
        if platform == "iphonesimulator" and architectures == {"x86_64"}:
            print("Whistle unavailable: no pinned x86_64 simulator archive")
            return
        raise ValueError(f"Whistle unsupported build target: {platform}/{architectures}")
    kind = "ios-sim-arm64" if platform == "iphonesimulator" else "ios-arm64"
    executable = app / env["EXECUTABLE_NAME"]
    app_links = subprocess.check_output(["otool", "-L", executable], text=True)
    if "CassiniWhistleRuntime.framework" in app_links:
        raise ValueError("Whistle must be lazy-loaded after privacy checks, never linked for app launch")
    archive = fetch(cache, kind + "/libneedle.a", offline)
    fetch(cache, kind + "/needle.h", offline)
    model = fetch(cache, "whistle.cact", offline)
    vad = fetch(cache, "silero-vad-6.2.1.onnx", offline)
    framework.parent.mkdir(parents=True, exist_ok=True)
    # Stage on the same filesystem as the build products. Never leave a partial embedded bundle.
    with tempfile.TemporaryDirectory(prefix="whistle-", dir=framework.parent) as staging:
        staged = Path(staging) / framework.name
        staged.mkdir()
        binary = staged / "CassiniWhistleRuntime"
        exports = Path(staging) / "exports.txt"
        exports.write_text("".join("_" + name + "\n" for name in EXPORTS))
        target = "arm64-apple-ios26.0" + ("-simulator" if platform == "iphonesimulator" else "")
        run(["xcrun", "clang++", "-target", target, "-isysroot", sdk, "-dynamiclib",
             "-Wl,-undefined,error", "-Wl,-no_weak_imports", "-Wl,-force_load," + str(archive),
             "-Wl,-exported_symbols_list," + str(exports), "-install_name",
             "@rpath/CassiniWhistleRuntime.framework/CassiniWhistleRuntime", "-lc++", "-o", binary])
        imports = subprocess.check_output(["nm", "-uj", binary], text=True).splitlines()
        check_imports(kind, imports)
        build = subprocess.check_output(["xcrun", "vtool", "-show-build", binary], text=True)
        print(build, flush=True)
        expected_platform = "IOSSIMULATOR" if kind == "ios-sim-arm64" else "IOS"
        if not re.search(r"\bminos\s+26\.0\b", build) or not re.search(r"\bplatform\s+" + expected_platform + r"\b", build):
            raise ValueError("Whistle final deployment command is not the reviewed target26 platform")
        dependencies = subprocess.check_output(["otool", "-L", binary], text=True)
        print(dependencies, flush=True)
        linked = {line.strip().split(" ")[0] for line in dependencies.splitlines()[1:]}
        allowed = {"@rpath/CassiniWhistleRuntime.framework/CassiniWhistleRuntime",
                   "/usr/lib/libc++.1.dylib", "/usr/lib/libSystem.B.dylib"}
        if linked - allowed:
            raise ValueError(f"Whistle unreviewed runtime dependency: {sorted(linked - allowed)}")
        (staged / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": binary.name, "CFBundleIdentifier": "io.codemyriad.cassini.whistle.runtime",
            "CFBundleName": "CassiniWhistleRuntime", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "FMWK", "CFBundleVersion": "1", "CFBundleShortVersionString": "3.3.0",
            "MinimumOSVersion": "26.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator" if kind == "ios-sim-arm64" else "iPhoneOS"],
        }))
        signing_identity = env.get("EXPANDED_CODE_SIGN_IDENTITY", "")
        if platform == "iphoneos" and env.get("CODE_SIGNING_ALLOWED") != "NO" and not signing_identity:
            raise ValueError("Whistle device framework requires the build's signing identity")
        if signing_identity or platform == "iphonesimulator":
            run(["codesign", "--force", "--sign", signing_identity or "-", "--timestamp=none", staged])
            run(["codesign", "--verify", "--strict", staged])
        # Section identity survives distribution re-signing; the OS verifies the complete code signature.
        manifest = {"engineRevision": PINS["engineRevision"], "modelSha256": PINS["artifacts"]["whistle.cact"]["sha256"],
                    "runtimeIdentity": identity(binary.read_bytes()), "identitySchema": "cassini-whistle-sections-v1", "target": kind, "minimumOS": "26.0", "sourceArchiveMinimumOS": "27.0"}
        verify(archive, PINS["artifacts"][kind + "/libneedle.a"])
        shutil.rmtree(framework, ignore_errors=True)
        shutil.move(staged, framework)
        resources.mkdir(exist_ok=True)
        shutil.copyfile(model, resources / "whistle.cact")
        verify(resources / "whistle.cact", PINS["artifacts"]["whistle.cact"])
        shutil.copyfile(vad, resources / "silero-vad-6.2.1.onnx")
        verify(resources / "silero-vad-6.2.1.onnx", PINS["artifacts"]["silero-vad-6.2.1.onnx"])
        (resources / "manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")
    fixtures = app / "WhistleTests"
    if env["CONFIGURATION"] == "Debug" or env.get("CASSINI_WHISTLE_LAB_FIXTURES") == "1":
        fixtures.mkdir(exist_ok=True)
        shutil.copyfile(fetch(cache, "jfk.wav", offline), fixtures / "jfk.wav")
        verify(fixtures / "jfk.wav", PINS["artifacts"]["jfk.wav"])
        shutil.copyfile(ROOT / "Whistle/jfk-golden.json", fixtures / "golden.json")
    else:
        shutil.rmtree(fixtures, ignore_errors=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    bundle(args.cache, args.offline)
