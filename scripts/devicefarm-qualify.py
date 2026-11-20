#!/usr/bin/env python3
"""Build, package, upload, and run D-1126 HandsetQualificationTests on AWS Device Farm (D89).

Usage:
  AWS_PROFILE=cassini-devicefarm uv run --with boto3 python3 scripts/devicefarm-qualify.py \
      --device-arn <ARN> --name d1126-iphone11-5min --profile short --filter HandsetQualificationTests/test02PairedEquivalenceAnd5MinMetrics

Enforces the D89 $160/month deny ceiling before scheduling any new run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT_ARN = "arn:aws:devicefarm:us-west-2:613912634239:project:6c67e094-43ab-4c2a-af51-f93bd2b1bfac"
RATE_PER_MINUTE = 0.17
MONTHLY_DENY_USD = 160.0


def run(cmd: list[str], cwd: Path = ROOT) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=cwd, check=True)


def _paginate(fn, key: str, **kwargs) -> list[dict]:
    items: list[dict] = []
    next_token: str | None = None
    seen_tokens: set[str] = set()
    while True:
        call_kwargs = dict(kwargs)
        if next_token is not None:
            call_kwargs["nextToken"] = next_token
        resp = fn(**call_kwargs)
        items.extend(resp.get(key, []))
        next_token = resp.get("nextToken")
        if not next_token or next_token in seen_tokens:
            break
        seen_tokens.add(next_token)
    return items


def check_budget(df, now: dt.datetime | None = None) -> float:
    now = now or dt.datetime.now(dt.timezone.utc)
    runs = _paginate(df.list_runs, "runs", arn=PROJECT_ARN)
    metered = sum(
        (r.get("deviceMinutes", {}).get("metered", 0.0) or 0.0)
        for r in runs
        if r["created"].year == now.year and r["created"].month == now.month
    )
    spent = metered * RATE_PER_MINUTE
    print(f"Device Farm month-to-date: {metered:.1f} metered min (~${spent:.2f} / ${MONTHLY_DENY_USD:.0f} deny cap)", flush=True)
    if spent >= MONTHLY_DENY_USD:
        raise SystemExit(f"Budget guard (D89): ${spent:.2f} >= ${MONTHLY_DENY_USD:.2f} deny threshold.")
    return spent


def build_for_device(derived: Path) -> tuple[Path, Path]:
    run(["xcodegen", "generate"])
    run([
        "xcodebuild", "build-for-testing",
        "-project", "Cassini.xcodeproj",
        "-scheme", "Cassini",
        "-destination", "generic/platform=iOS",
        "-configuration", "Debug",
        "-derivedDataPath", str(derived),
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGN_IDENTITY=",
    ])
    products = derived / "Build/Products/Debug-iphoneos"
    app = products / "Cassini.app"
    xctest = app / "PlugIns/CassiniTests.xctest"
    if not app.is_dir() or not xctest.is_dir():
        raise SystemExit(f"Expected {app} and {xctest} after build-for-testing")
    return app, xctest


def package_artifacts(app: Path, xctest: Path, out_dir: Path, qual_config: dict) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Copy app & inject CassiniHandsetQual.json into CassiniTests.xctest
    stage = out_dir / "stage"
    if stage.exists():
        shutil.rmtree(stage)
    payload = stage / "Payload"
    payload.mkdir(parents=True)
    staged_app = payload / "Cassini.app"
    shutil.copytree(app, staged_app, symlinks=True)

    staged_xctest = staged_app / "PlugIns/CassiniTests.xctest"
    (staged_xctest / "CassiniHandsetQual.json").write_text(json.dumps(qual_config, indent=2) + "\n")

    ipa = out_dir / "Cassini.ipa"
    if ipa.exists():
        ipa.unlink()
    run(["zip", "-qry", str(ipa), "Payload"], cwd=stage)

    test_zip = out_dir / "CassiniTests.xctest.zip"
    if test_zip.exists():
        test_zip.unlink()
    run(["zip", "-qry", str(test_zip), "CassiniTests.xctest"], cwd=staged_app / "PlugIns")
    return ipa, test_zip


def upload_file(df, path: Path, upload_type: str) -> str:
    resp = df.create_upload(projectArn=PROJECT_ARN, name=path.name, type=upload_type)["upload"]
    arn = resp["arn"]
    put_url = resp["url"]
    print(f"Uploading {path.name} ({path.stat().st_size / (1024*1024):.1f} MiB) as {upload_type}...", flush=True)
    data = path.read_bytes()
    req = urllib.request.Request(put_url, data=data, method="PUT", headers={"Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=600) as r:
        if r.status not in (200, 201):
            raise SystemExit(f"Upload failed: HTTP {r.status}")
    while True:
        u = df.get_upload(arn=arn)["upload"]
        if u["status"] == "SUCCEEDED":
            return arn
        if u["status"] == "FAILED":
            raise SystemExit(f"Upload {path.name} failed: {u.get('metadata')}")
        time.sleep(3)


def _pool_matches_device(pool: dict, device_arn: str) -> bool:
    rules = pool.get("rules") or []
    if len(rules) != 1:
        return False
    rule = rules[0]
    if rule.get("attribute") != "ARN" or rule.get("operator") != "IN":
        return False
    try:
        arns = json.loads(rule.get("value", "[]"))
    except (TypeError, json.JSONDecodeError):
        return False
    return arns == [device_arn]


def ensure_device_pool(df, name: str, device_arn: str) -> str:
    for pool in _paginate(df.list_device_pools, "devicePools", arn=PROJECT_ARN, type="PRIVATE"):
        if pool["name"] == name:
            if not _pool_matches_device(pool, device_arn):
                raise SystemExit(
                    f"Device pool {name!r} ({pool['arn']}) does not match requested --device-arn {device_arn!r} "
                    f"(existing rules: {pool.get('rules')!r}). Use a distinct --pool-name."
                )
            return pool["arn"]
    return df.create_device_pool(
        projectArn=PROJECT_ARN,
        name=name,
        rules=[{"attribute": "ARN", "operator": "IN", "value": json.dumps([device_arn])}],
    )["devicePool"]["arn"]


def extract_reports(df, run_arn: str, out_dir: Path) -> list[dict]:
    reports = []
    out_dir.mkdir(parents=True, exist_ok=True)
    for job in _paginate(df.list_jobs, "jobs", arn=run_arn):
        for suite in _paginate(df.list_suites, "suites", arn=job["arn"]):
            for test in _paginate(df.list_tests, "tests", arn=suite["arn"]):
                for art_type in ("LOG", "FILE"):
                    for art in _paginate(df.list_artifacts, "artifacts", arn=test["arn"], type=art_type):
                        if art["name"] in ("Automation Output", "Application Output") or art["extension"] in ("log", "txt", "json"):
                            body = urllib.request.urlopen(art["url"], timeout=120).read().decode("utf-8", errors="replace")
                            safe = f"{suite['name']}-{test['name']}-{art['name']}".replace("/", "_")
                            (out_dir / safe).write_text(body)
                            marker = "CASSINI_HANDSET_QUAL_BEGIN:"
                            idx = 0
                            while True:
                                start = body.find(marker, idx)
                                if start == -1:
                                    break
                                nl = body.find("\n", start)
                                name = body[start + len(marker):nl].strip()
                                end_marker = f"CASSINI_HANDSET_QUAL_END:{name}"
                                end = body.find(end_marker, nl)
                                if end == -1:
                                    break
                                raw = body[nl + 1:end].strip()
                                try:
                                    reports.append(json.loads(raw))
                                except json.JSONDecodeError:
                                    pass
                                idx = end + len(end_marker)
    return reports


KNOWN_TEST_METHODS = frozenset({
    "testQualificationHarnessAndTelemetryContract",
    "testWordErrorRateEdgeCases",
    "testCanonicalSpeakerSlotAndVoiceMapComparison",
    "testContinuousCaptureContinuityRejectsEarlyPause",
    "test01RealCAFLiveReaderAndInterruptionLifecycle",
    "test02PairedEquivalenceAnd5MinMetrics",
    "test03ThirtyMinuteContinuousParakeet",
    "test04ThirtyMinuteContinuousWhistle",
})


def validate_filter_and_config(test_filter: str, qual_cfg: dict) -> list[tuple[str, str | None]]:
    """Validate --filter against known tests and qual_cfg enable flags; return expected (test, engine) report keys."""
    raw_parts = [t.strip() for t in test_filter.split(",")]
    if not raw_parts or any(not t for t in raw_parts):
        raise SystemExit(f"Invalid --filter {test_filter!r}: must be a comma-separated list of non-empty test selectors.")

    explicit_methods: set[str] = set()
    expanded_methods: set[str] = set()
    for token in raw_parts:
        parts = token.split("/")
        if parts == ["HandsetQualificationTests"] or parts == ["CassiniTests", "HandsetQualificationTests"]:
            expanded_methods.add("test01RealCAFLiveReaderAndInterruptionLifecycle")
            expanded_methods.add("test02PairedEquivalenceAnd5MinMetrics")
            if qual_cfg.get("runLongParakeet"):
                expanded_methods.add("test03ThirtyMinuteContinuousParakeet")
            if qual_cfg.get("runLongWhistle"):
                expanded_methods.add("test04ThirtyMinuteContinuousWhistle")
        elif (
            (len(parts) == 2 and parts[0] == "HandsetQualificationTests")
            or (len(parts) == 3 and parts[0] == "CassiniTests" and parts[1] == "HandsetQualificationTests")
        ):
            method = parts[-1]
            if method not in KNOWN_TEST_METHODS:
                raise SystemExit(
                    f"Unknown or misspelled test selector {token!r}; "
                    f"expected HandsetQualificationTests or one of {sorted(KNOWN_TEST_METHODS)}."
                )
            explicit_methods.add(method)
            expanded_methods.add(method)
        else:
            raise SystemExit(
                f"Unsupported test selector {token!r}; "
                "expected [CassiniTests/]HandsetQualificationTests[/<method>]."
            )

    if "test03ThirtyMinuteContinuousParakeet" in explicit_methods and not qual_cfg.get("runLongParakeet"):
        raise SystemExit(
            "Filter selects test03ThirtyMinuteContinuousParakeet without --long-parakeet; "
            "the test would XCTSkip and emit no report."
        )
    if "test04ThirtyMinuteContinuousWhistle" in explicit_methods and not qual_cfg.get("runLongWhistle"):
        raise SystemExit(
            "Filter selects test04ThirtyMinuteContinuousWhistle without --long-whistle; "
            "the test would XCTSkip and emit no report."
        )
    if "test02PairedEquivalenceAnd5MinMetrics" in expanded_methods and not (
        qual_cfg.get("runParakeet") or qual_cfg.get("runWhistle")
    ):
        raise SystemExit(
            "Filter includes test02PairedEquivalenceAnd5MinMetrics with both --no-parakeet and --no-whistle."
        )

    expected: list[tuple[str, str | None]] = []
    if "test01RealCAFLiveReaderAndInterruptionLifecycle" in expanded_methods:
        expected.append(("test01RealCAFLiveReaderAndInterruptionLifecycle", None))
    if "test02PairedEquivalenceAnd5MinMetrics" in expanded_methods:
        expected.append(("test02PairedEquivalenceAnd5MinMetrics", None))
    if "test03ThirtyMinuteContinuousParakeet" in expanded_methods:
        expected.append(("runThirtyMinuteContinuousCapture", "parakeet"))
    if "test04ThirtyMinuteContinuousWhistle" in expanded_methods:
        expected.append(("runThirtyMinuteContinuousCapture", "whistle"))
    return expected


def verify_reports(reports: list[dict], expected: list[tuple[str, str | None]], qual_cfg: dict) -> None:
    """Fail if any requested measurement lane is missing from the extracted qualification reports."""
    if not expected:
        return
    if not reports:
        raise SystemExit(
            f"Device Farm run PASSED but extracted 0 qualification reports (expected {len(expected)}: {expected})."
        )
    for test_name, engine in expected:
        matches = [
            rep for rep in reports
            if rep.get("test") == test_name and (engine is None or rep.get("engine") == engine)
        ]
        if not matches:
            label = f"{test_name} (engine={engine})" if engine else test_name
            raise SystemExit(f"Device Farm run PASSED but is missing expected qualification report: {label}.")
        if test_name == "test02PairedEquivalenceAnd5MinMetrics":
            if not (qual_cfg.get("runParakeet") or qual_cfg.get("runWhistle")):
                raise SystemExit(
                    "test02PairedEquivalenceAnd5MinMetrics requires at least one enabled engine (Parakeet or Whistle)."
                )
            if qual_cfg.get("runParakeet") and not any("parakeet" in rep for rep in matches):
                raise SystemExit("Device Farm run PASSED but test02 report is missing 'parakeet' section.")
            if qual_cfg.get("runWhistle") and not any("whistle" in rep for rep in matches):
                raise SystemExit("Device Farm run PASSED but test02 report is missing 'whistle' section.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device-arn", required=True)
    parser.add_argument("--pool-name", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--filter", default="HandsetQualificationTests")
    parser.add_argument("--short-seconds", type=int, default=300)
    parser.add_argument("--long-seconds", type=int, default=1800)
    parser.add_argument("--no-parakeet", action="store_true")
    parser.add_argument("--no-whistle", action="store_true")
    parser.add_argument("--long-parakeet", action="store_true")
    parser.add_argument("--long-whistle", action="store_true")
    parser.add_argument("--timeout-minutes", type=int, default=90)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--no-wait", action="store_true")
    args = parser.parse_args()

    qual_cfg = {
        "shortSeconds": args.short_seconds,
        "longSeconds": args.long_seconds,
        "runParakeet": not args.no_parakeet,
        "runWhistle": not args.no_whistle,
        "runLongParakeet": args.long_parakeet,
        "runLongWhistle": args.long_whistle,
    }
    expected_reports = validate_filter_and_config(args.filter, qual_cfg)

    import boto3
    df = boto3.client("devicefarm", region_name="us-west-2")
    check_budget(df)

    derived = ROOT / "DerivedData.noindex/devicefarm"
    out_dir = ROOT / "DerivedData.noindex/devicefarm-out" / args.name
    if args.skip_build:
        app = derived / "Build/Products/Debug-iphoneos/Cassini.app"
        xctest = app / "PlugIns/CassiniTests.xctest"
    else:
        app, xctest = build_for_device(derived)

    ipa, test_zip = package_artifacts(app, xctest, out_dir, qual_cfg)
    app_arn = upload_file(df, ipa, "IOS_APP")
    test_arn = upload_file(df, test_zip, "XCTEST_TEST_PACKAGE")
    pool_arn = ensure_device_pool(df, args.pool_name, args.device_arn)

    scheduled = df.schedule_run(
        projectArn=PROJECT_ARN,
        appArn=app_arn,
        devicePoolArn=pool_arn,
        name=args.name,
        test={"type": "XCTEST", "testPackageArn": test_arn, "filter": args.filter},
        executionConfiguration={"jobTimeoutMinutes": args.timeout_minutes},
    )["run"]
    run_arn = scheduled["arn"]
    print(f"Scheduled run: {args.name} -> {run_arn}", flush=True)
    if args.no_wait:
        return

    while True:
        r = df.get_run(arn=run_arn)["run"]
        print(f"  [{r['status']}] result={r.get('result')} counters={r.get('counters')} minutes={r.get('deviceMinutes')}", flush=True)
        if r["status"] == "COMPLETED":
            reports = extract_reports(df, run_arn, out_dir / "artifacts")
            (out_dir / "reports.json").write_text(json.dumps(reports, indent=2) + "\n")
            print(f"Extracted {len(reports)} qualification reports -> {out_dir / 'reports.json'}", flush=True)
            if r.get("result") != "PASSED":
                raise SystemExit(f"Device Farm run ended with {r.get('result')}")
            verify_reports(reports, expected_reports, qual_cfg)
            return
        time.sleep(30)


if __name__ == "__main__":
    main()
