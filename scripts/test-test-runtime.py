#!/usr/bin/env python3
"""CASSINI_RUNTIME regressions for scripts/test.sh with fake xcrun, xcodebuild and xcodegen: no simulators or builds.

Covers the runtime pick, the device types per runtime, clone names and leases per runtime, never reusing a clone of
another runtime, which clones clean and the disk reclaim (also an older copy of it) treat as whose, separate logs and
timing tables, and that without CASSINI_RUNTIME a run issues the commands it always did.

Ios18LegTests cover the iOS 18 leg of `all` (CASSINI_IOS18): off by default with the commands of a run without it,
its order after the default runtime's clones are shut down, smoke and full, a missing runtime failing the run and the
status, the opt-out posting none, the status text, separate logs and timings, and the real smoke list.
"""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "scripts/test.sh").read_text()

R26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
R27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
R185 = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
R186 = "com.apple.CoreSimulator.SimRuntime.iOS-18-6"
NEW_TYPES = ["iPhone 17", "iPhone 16", "iPad Pro 13-inch (M5)", "iPad Pro 13-inch (M4)"]
OLD_TYPES = ["iPhone 16", "iPad Pro 13-inch (M4)"]


def runtime(identifier, version, types, available=True):
    return {"identifier": identifier, "version": version, "platform": "iOS", "isAvailable": available,
            "supportedDeviceTypes": [{"name": t, "identifier": type_id(t)} for t in types]}


def type_id(name):
    return "com.apple.CoreSimulator.SimDeviceType." + name.replace(" (", "-").replace(")", "").replace(" ", "-")


INSTALLED = [runtime(R26, "26.0", NEW_TYPES), runtime(R27, "27.0", NEW_TYPES)]
WITH_18 = [runtime(R185, "18.5", OLD_TYPES), runtime(R186, "18.6", OLD_TYPES)] + INSTALLED


def function(name):
    start = SOURCE.index(name + "() {")
    return SOURCE[start:SOURCE.index("\n}\n", start) + 3]


# simctl over a JSON device set; every call is appended to calls, one per line, arguments separated by " | ".
FAKE_XCRUN = r'''#!/usr/bin/python3 -I
import fcntl, json, os, sys
stub = os.environ["STUB"]
args = sys.argv[1:]
with open(os.path.join(stub, "calls"), "a") as f:
    f.write("xcrun | " + " | ".join(args) + "\n")
with open(os.path.join(stub, "state.lock"), "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    path = os.path.join(stub, "state.json")
    state = json.load(open(path))
    def find(udid):
        for rt, devices in state["devices"].items():
            for d in devices:
                if d["udid"] == udid: return rt, d
        return None, None
    if args[:1] != ["simctl"]: sys.exit(0)
    cmd = args[1:]
    if cmd == ["list", "runtimes", "-j"]: print(json.dumps({"runtimes": state["runtimes"]}))
    elif cmd == ["list", "devices", "-j"]: print(json.dumps({"devices": state["devices"]}))
    elif cmd[0] == "create":
        name, kind, rt = cmd[1:4]
        r = [r for r in state["runtimes"] if r["identifier"] == rt]
        if not r or kind not in [t["name"] for t in r[0]["supportedDeviceTypes"]]:
            print("Invalid device type: " + kind, file=sys.stderr); sys.exit(1)
        state["next"] += 1
        udid = "%08X-0000-4000-8000-%012X" % (state["next"], state["next"])
        state["devices"].setdefault(rt, []).append({"name": name, "udid": udid, "state": "Shutdown", "isAvailable": True})
        print(udid)
    elif cmd[0] == "bootstatus": find(cmd[1])[1]["state"] = "Booted"
    elif cmd[0] == "shutdown":
        d = find(cmd[1])[1]
        if d: d["state"] = "Shutdown"
    elif cmd[0] == "delete":
        rt, d = find(cmd[1])
        if not d: sys.exit(1)
        state["devices"][rt].remove(d)
    json.dump(state, open(path + ".tmp", "w")); os.replace(path + ".tmp", path)
'''

# build-for-testing writes an .xctestrun; test-without-building passes every test it is given.
FAKE_XCODEBUILD = r'''#!/usr/bin/python3 -I
import json, os, plistlib, sys
stub = os.environ["STUB"]
args = sys.argv[1:]
# The iOS 18 facts a run gives the UI test runner are recorded after the arguments.
facts = ["TEST_RUNNER_CASSINI_IOS18_FACTS=1"] if os.environ.get("TEST_RUNNER_CASSINI_IOS18_FACTS") == "1" else []
with open(os.path.join(stub, "calls"), "a") as f:
    f.write("xcodebuild | " + " | ".join(args + facts) + "\n")
if "build-for-testing" in args:
    products = os.path.join(args[args.index("-derivedDataPath") + 1], "Build", "Products")
    os.makedirs(products, exist_ok=True)
    with open(os.path.join(products, "Cassini_Cassini_iphonesimulator27.0-arm64.xctestrun"), "wb") as f:
        plistlib.dump({"CassiniTests": {}, "CassiniUITests": {}, "__xctestrun_metadata__": {"FormatVersion": 1}}, f)
    # The app the embedded-minimum check reads: its own minimum, and an extension whose minimum is STUB_EMBEDDED_MINOS
    # (the app's when unset), so a test can make that check fail.
    app = os.path.join(products, "Debug-iphonesimulator", "Cassini.app")
    os.makedirs(os.path.join(app, "PlugIns", "CassiniActivity.appex"), exist_ok=True)
    with open(os.path.join(app, "Info.plist"), "wb") as f:
        plistlib.dump({"MinimumOSVersion": "18.0"}, f)
    with open(os.path.join(app, "PlugIns", "CassiniActivity.appex", "Info.plist"), "wb") as f:
        plistlib.dump({"MinimumOSVersion": os.environ.get("STUB_EMBEDDED_MINOS", "18.0")}, f)
elif "test-without-building" in args:
    # STUB_FAIL_RUNTIME: every test fails on a clone of that runtime.
    udid = [a for a in args if a.startswith("platform=iOS Simulator,id=")][0].split("id=")[1]
    state = json.load(open(os.path.join(stub, "state.json")))
    fails = any(d["udid"] == udid for d in state["devices"].get(os.environ.get("STUB_FAIL_RUNTIME", ""), []))
    verdict = "failed" if fails else "passed"
    # STUB_HOST_FAILS: the hosted tests' host never launches, so no test runs and nothing is counted.
    if os.environ.get("STUB_HOST_FAILS") and "-only-testing:CassiniTests" in args:
        print("xcodebuild: error: Failed to launch the test host")
        sys.exit(65)
    for a in args:
        if a == "-only-testing:CassiniTests":
            print("Test Case '-[CassiniTests.HostedTests testHosted]' started.")
            print("Test Case '-[CassiniTests.HostedTests testHosted]' %s (0.100 seconds)." % verdict)
            print("Test Case '-[CassiniTests.HostedTests testSkipped]' started.")
            print("Test Case '-[CassiniTests.HostedTests testSkipped]' skipped (0.001 seconds).")
            print("Executed 2 tests, with 1 test skipped and %d failures (0 unexpected)" % fails)
        elif a.startswith("-only-testing:CassiniUITests/"):
            cls, method = a.split("/", 1)[1].split("/")
            print("Test Case '-[CassiniUITests.%s %s]' started." % (cls, method))
            print("Test Case '-[CassiniUITests.%s %s]' %s (4.000 seconds)." % (cls, method, verdict))
    sys.exit(65 if fails else 0)
'''

FAKE_SWIFT = r'''#!/bin/sh
echo "swift | $*" >> "$STUB/calls"
case "$*" in *--help-hidden*) exit 0 ;; esac
echo "✔ Test run with 1 test passed after 0.1 seconds."
'''

FAKE_GH = r'''#!/bin/sh
{ printf 'gh'; for a in "$@"; do printf ' | %s' "$a"; done; echo; } >> "$STUB/calls"
'''

UI_TESTS = textwrap.dedent('''\
    import XCTest
    final class AlphaTests: XCTestCase {
        func testOne() {}
        func testIPadTwo() {}
    }
    final class BetaTests: XCTestCase {
        func testThree() {}
    }
''')


# The repository's default for the iOS 18 leg of `all`, and the fixture's.
LEG_ON = "\nios18_default=smoke\n"
LEG_OFF = "\nios18_default=off\n"


class Harness:
    """A copy of the repository's scripts in a temporary worktree called wt, with fake tools first on PATH."""

    def __init__(self, case, runtimes=INSTALLED, devices=None):
        self.temp = tempfile.TemporaryDirectory(prefix="cassini runtime ")
        case.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root = base / "wt"
        self.stub = base / "stub"
        self.home = base / "home"
        self.cache = base / "cache"
        for d in (self.root / "scripts", self.root / "CassiniUITests", self.stub / "bin", self.home, self.cache):
            d.mkdir(parents=True)
        for name in ("test.sh", "test-events.py", "check-embedded-minos.py", "ui-test-durations.tsv"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        # The fixture starts with the leg off by default, so the tests of everything else run without an iOS 18 runtime;
        # Ios18LegTests switch the line back to the repository's value where the default is what they test.
        script = self.root / "scripts/test.sh"
        text = script.read_text()
        assert text.count(LEG_ON) == 1, "scripts/test.sh no longer has the line " + LEG_ON.strip()
        script.write_text(text.replace(LEG_ON, LEG_OFF))
        (self.root / "Package.swift").write_text("// fixture\n")
        (self.root / "Package.resolved").write_text("{}\n")
        (self.root / "CassiniUITests/Fixture.swift").write_text(UI_TESTS)
        (self.root / "scripts/ios18-smoke-tests.txt").write_text("# the fixture's smoke list\nAlphaTests/testOne\n")
        (self.root / "scripts/check-strings.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.root / "scripts/check-strings.sh").chmod(0o755)
        tools = {"xcrun": FAKE_XCRUN, "xcodebuild": FAKE_XCODEBUILD, "xcodegen": "#!/bin/sh\nexit 0\n",
                 "swift": FAKE_SWIFT, "gh": FAKE_GH}
        for name, text in tools.items():
            (self.stub / "bin" / name).write_text(text)
            (self.stub / "bin" / name).chmod(0o755)
        self.write_state(runtimes, devices or {})

    def git(self):
        """Makes the worktree a clean checkout with a GitHub origin, so `all` can post its status (to the fake gh)."""
        (self.root / ".gitignore").write_text("DerivedData*\n.build\n")
        git = ["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@example.com"]
        for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"],
                     ["remote", "add", "origin", "https://github.com/owner/repo.git"]):
            subprocess.run(git + args, check=True, capture_output=True, env=self.env())

    def statuses(self):
        """(state, description) of each status posted."""
        found = []
        for c in self.calls():
            if c.startswith("gh | api"):
                fields = dict(f.split("=", 1) for f in c.split(" | ") if "=" in f and not f.startswith("repos/"))
                found.append((fields["state"], fields["description"]))
        return found

    def write_state(self, runtimes, devices):
        (self.stub / "state.json").write_text(json.dumps({"runtimes": runtimes, "devices": devices, "next": 0}))

    def state(self):
        return json.loads((self.stub / "state.json").read_text())

    def names(self):
        return {d["name"]: (rt, d["udid"]) for rt, ds in self.state()["devices"].items() for d in ds}

    def calls(self):
        path = self.stub / "calls"
        text = path.read_text() if path.exists() else ""
        return text.replace(str(self.temp.name), "<TMP>").splitlines()

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CASSINI_")}
        env.update(PATH=f"{self.stub / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(self.home),
                   STUB=str(self.stub), CASSINI_TEST_CACHE=str(self.cache), CASSINI_HEAVY_LOCK_HELD="1",
                   CASSINI_ADMIT_MINUTES="0", CASSINI_UI_WORKERS="2", TMPDIR=str(self.home))
        env.update(extra)
        return env

    def run(self, tier, *args, **extra):
        return subprocess.run(["/bin/bash", str(self.root / "scripts/test.sh"), tier, *args],
                              env=self.env(**extra), capture_output=True, text=True, timeout=120)

    def shell(self, names, code, **extra):
        """Runs functions of test.sh with the script's variables for this worktree set as they would be."""
        prelude = textwrap.dedent(f'''\
            set -euo pipefail
            root={str(self.root)!r}; cache={str(self.cache)!r}; leases="$cache/sim-leases"
            prefix="ts-wt"; logs={str(self.root / 'logs')!r}; mkdir -p "$logs" "$leases"
            die() {{ echo "error: $*" >&2; exit 1; }}
        ''')
        script = prelude + "\n".join(function(n) for n in names) + "\n" + code
        return subprocess.run(["/bin/bash", "-c", script], env=self.env(**extra), capture_output=True, text=True,
                              timeout=60)


def dev(name, udid, state="Shutdown"):
    return {"name": name, "udid": udid, "state": state, "isAvailable": True}


def udid(n):
    return "%08X-1111-4000-8000-%012X" % (n, n)


class RuntimePickTests(unittest.TestCase):
    def pick(self, wanted, iphone="", ipad="", runtimes=WITH_18):
        h = Harness(self, runtimes)
        tag = wanted.split("SimRuntime.iOS-")[-1].replace("-", ".")
        env = {"CASSINI_RUNTIME": wanted}
        if iphone: env["CASSINI_IPHONE"] = iphone
        if ipad: env["CASSINI_IPAD"] = ipad
        code = f'runtime_tag={tag!r}; iphone_type="iPhone 17"; ipad_type="iPad Pro 13-inch (M5)"\n' \
               'select_runtime\nprintf "%s|%s|%s|%s\\n" "$runtime" "$runtime_version" "$iphone_type" "$ipad_type"'
        return h.shell(["pick_runtime", "select_runtime"], code, **env)

    def test_a_major_version_picks_its_newest_runtime_and_the_devices_it_can_run(self):
        result = self.pick("18")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], f"{R186}|18.6|iPhone 16|iPad Pro 13-inch (M4)")
        self.assertIn("clones ts-wt-iphone18-N (iPhone 16), ts-wt-ipad18-1 (iPad Pro 13-inch (M4))", result.stdout)

    def test_an_exact_version_or_identifier_picks_that_runtime(self):
        for wanted in ("18.5", R185):
            with self.subTest(wanted=wanted):
                result = self.pick(wanted)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.splitlines()[-1].startswith(f"{R185}|18.5|iPhone 16|"))

    def test_runtime_26_and_later_keeps_the_default_devices(self):
        for wanted, identifier in (("26", R26), ("27.0", R27)):
            with self.subTest(wanted=wanted):
                result = self.pick(wanted)
                self.assertEqual(result.stdout.splitlines()[-1],
                                 f"{identifier}|{wanted if '.' in wanted else '26.0'}|iPhone 17|iPad Pro 13-inch (M5)")

    def test_a_prefix_matches_whole_version_components_only(self):
        result = self.pick("2", runtimes=INSTALLED)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no available iOS simulator runtime matches CASSINI_RUNTIME=2 (available: 26.0, 27.0)",
                      result.stderr)

    def test_a_missing_or_unavailable_runtime_fails_and_never_falls_back(self):
        runtimes = [runtime(R186, "18.6", OLD_TYPES, available=False)] + INSTALLED
        for wanted in ("18", R186, "17"):
            with self.subTest(wanted=wanted):
                result = self.pick(wanted, runtimes=runtimes)
                self.assertEqual(result.returncode, 1)
                self.assertIn("no available iOS simulator runtime matches", result.stderr)
                self.assertNotIn("SimRuntime", result.stdout)

    def test_a_device_type_the_runtime_cannot_run_fails_clearly(self):
        result = self.pick("18", iphone="iPhone 17")
        self.assertEqual(result.returncode, 1)
        self.assertIn('iOS 18.6 cannot run the device type "iPhone 17" (set CASSINI_IPHONE)', result.stderr)
        result = self.pick("18", ipad="iPad Pro 13-inch (M5)")
        self.assertIn('(set CASSINI_IPAD)', result.stderr)
        result = self.pick("26", iphone="iPhone 16", ipad="iPad Pro 13-inch (M4)")
        self.assertEqual(result.stdout.splitlines()[-1], f"{R26}|26.0|iPhone 16|iPad Pro 13-inch (M4)")

    def test_a_device_type_can_be_given_by_its_identifier(self):
        iphone, ipad = type_id("iPhone 16"), type_id("iPad Pro 13-inch (M4)")
        result = self.pick("18", iphone=iphone, ipad=ipad)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], f"{R186}|18.6|{iphone}|{ipad}")
        result = self.pick("18", iphone=type_id("iPhone 17"))
        self.assertIn(f'cannot run the device type "{type_id("iPhone 17")}"', result.stderr)

    def test_an_invalid_value_is_refused_before_anything_runs(self):
        # An identifier without a version strips to an empty tag: it must not read as no CASSINI_RUNTIME, which would
        # run on the newest runtime and post a status.
        for tier, value in (("app", "eighteen"), ("ui", "com.apple.CoreSimulator.SimRuntime.iOS-"),
                            ("all", "com.apple.CoreSimulator.SimRuntime.iOS-"),
                            ("changed", "com.apple.CoreSimulator.SimRuntime.iOS-")):
            with self.subTest(tier=tier, value=value):
                h = Harness(self)
                result = h.run(tier, CASSINI_RUNTIME=value, CASSINI_POST_STATUS="1")
                self.assertEqual(result.returncode, 2)
                self.assertIn(f"error: CASSINI_RUNTIME={value} is neither a version", result.stderr)
                self.assertEqual(h.calls(), [])
                self.assertNotIn("commit status", result.stdout)
                self.assertFalse((h.root / "DerivedData.noindex").exists())


class FullRunTests(unittest.TestCase):
    def test_without_cassini_runtime_a_run_uses_the_names_and_files_it_always_did(self):
        h = Harness(self)
        (h.cache / "ui-test-durations.tsv").write_text("AlphaTests/testOne\t10.0\n")
        result = h.run("ui")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASSED (ui)", result.stdout)
        self.assertNotIn("runtime:", result.stdout)
        creates = sorted(c for c in h.calls() if c.startswith("xcrun | simctl | create"))
        self.assertEqual(creates, [f"xcrun | simctl | create | ts-wt-ipad-1 | iPad Pro 13-inch (M5) | {R27}",
                                   f"xcrun | simctl | create | ts-wt-iphone-1 | iPhone 17 | {R27}",
                                   f"xcrun | simctl | create | ts-wt-iphone-2 | iPhone 17 | {R27}"])
        logs = h.root / "DerivedData.noindex"
        self.assertEqual(sorted(p.name for p in logs.iterdir() if p.name.startswith("test-logs")), ["test-logs"])
        self.assertTrue((logs / "test-logs/ui-1.log").exists() and (logs / "test-logs/ui-ipad.log").exists())
        self.assertEqual(sorted(p.name for p in h.cache.glob("ui-test-durations*")), ["ui-test-durations.tsv"])
        self.assertIn("AlphaTests/testOne\t7.0", (h.cache / "ui-test-durations.tsv").read_text())
        leases = h.cache / "sim-leases"
        self.assertEqual(sorted(p.name for p in leases.iterdir()), sorted(u for _, u in h.names().values()))
        # The iPhones stay booted after an iterating tier, as before.
        self.assertEqual(sum(d["state"] == "Booted" for d in h.state()["devices"][R27]), 2)

    def test_without_cassini_runtime_an_existing_clone_is_reused_on_whatever_runtime(self):
        h = Harness(self, devices={R26: [dev("ts-wt-iphone-1", udid(1))]})
        result = h.run("app")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse([c for c in h.calls() if "simctl | create" in c])
        self.assertIn(f"id={udid(1)}", "\n".join(h.calls()))

    def test_the_fake_build_passes_the_embedded_minimum_check_and_a_newer_extension_still_fails_it(self):
        h = Harness(self)
        result = h.run("app", STUB_EMBEDDED_MINOS="26.0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("PlugIns/CassiniActivity.appex/Info.plist: minimum iOS 26.0 is above the app's 18.0", result.stderr)
        self.assertFalse([c for c in h.calls() if "test-without-building" in c], "no test runs after the check fails")

    def test_a_second_runtime_has_its_own_clones_leases_logs_and_timing_table(self):
        # A third iPhone of this leg, booted before, is beyond CASSINI_UI_WORKERS=2.
        h = Harness(self, devices={R27: [dev("ts-wt-iphone-1", udid(1), "Booted")],
                                   R26: [dev("ts-wt-iphone26-3", udid(3), "Booted")]})
        default_logs = h.root / "DerivedData.noindex/test-logs"
        default_logs.mkdir(parents=True)
        (default_logs / "ui-1.log").write_text("the default leg's log\n")
        (h.cache / "ui-test-durations.tsv").write_text("AlphaTests/testOne\t10.0\n")
        result = h.run("ui", CASSINI_RUNTIME="26")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"runtime: iOS 26.0 ({R26})", result.stdout)
        creates = sorted(c for c in h.calls() if c.startswith("xcrun | simctl | create"))
        self.assertEqual(creates, [f"xcrun | simctl | create | ts-wt-ipad26-1 | iPad Pro 13-inch (M5) | {R26}",
                                   f"xcrun | simctl | create | ts-wt-iphone26-1 | iPhone 17 | {R26}",
                                   f"xcrun | simctl | create | ts-wt-iphone26-2 | iPhone 17 | {R26}"])
        # The default iPhone a run before kept booted is shut down before the leg boots, and every clone after it.
        calls = h.calls()
        first_create = next(i for i, c in enumerate(calls) if "simctl | create" in c)
        self.assertLess(calls.index(f"xcrun | simctl | shutdown | {udid(1)}"), first_create)
        # The leg's own iPhone it does not use is shut down before the shards run, not only at the end.
        first_test = next(i for i, c in enumerate(calls) if "test-without-building" in c)
        self.assertLess(calls.index(f"xcrun | simctl | shutdown | {udid(3)}"), first_test)
        self.assertTrue(all(d["state"] == "Shutdown" for ds in h.state()["devices"].values() for d in ds))
        self.assertEqual((default_logs / "ui-1.log").read_text(), "the default leg's log\n")
        self.assertTrue((h.root / "DerivedData.noindex/test-logs-ios26/ui-1.log").exists())
        self.assertEqual((h.cache / "ui-test-durations.tsv").read_text(), "AlphaTests/testOne\t10.0\n")
        self.assertIn("AlphaTests/testOne\t4.0", (h.cache / "ui-test-durations-ios26.tsv").read_text())
        top = {p.name for p in (h.cache / "sim-leases").iterdir() if p.is_file()}
        runtime_leases = {p.name for p in (h.cache / "sim-leases/runtime").iterdir()}
        ours = {u for name, (_, u) in h.names().items() if "26-" in name} - {udid(3)}
        self.assertEqual(runtime_leases, ours)
        self.assertFalse(top & ours)

    def test_an_ios_18_leg_defaults_to_devices_that_run_on_18(self):
        h = Harness(self, WITH_18)
        result = h.run("app", CASSINI_RUNTIME="18")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"xcrun | simctl | create | ts-wt-iphone18-1 | iPhone 16 | {R186}", h.calls())

    def test_a_clone_of_the_same_name_on_another_runtime_is_never_reused(self):
        h = Harness(self, WITH_18, {R185: [dev("ts-wt-iphone18-1", udid(1))],
                                    R186: [dev("ts-other-iphone18-1", udid(2))]})
        lease = h.cache / "sim-leases/runtime"
        lease.mkdir(parents=True)
        (lease / udid(1)).touch()
        result = h.run("app", CASSINI_RUNTIME="18")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"xcrun | simctl | delete | {udid(1)}", h.calls())
        self.assertNotIn(udid(1), "\n".join(c for c in h.calls() if "xcodebuild" in c))
        names = h.names()
        self.assertEqual(names["ts-wt-iphone18-1"][0], R186)
        self.assertEqual(names["ts-other-iphone18-1"], (R186, udid(2)))
        self.assertFalse((lease / udid(1)).exists())

    def test_a_missing_runtime_fails_the_run_without_building_or_posting(self):
        # The default iPhone a run before kept booted (or another run of this worktree tests on) stays booted.
        h = Harness(self, devices={R27: [dev("ts-wt-iphone-1", udid(1), "Booted")]})
        result = h.run("app", CASSINI_RUNTIME="18", CASSINI_POST_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no available iOS simulator runtime matches CASSINI_RUNTIME=18 (available: 26.0, 27.0)",
                      result.stderr)
        self.assertIn("FAILED (app)", result.stdout)
        self.assertTrue((h.root / "DerivedData.noindex/test-logs-ios18/FAILED").exists())
        self.assertFalse([c for c in h.calls() if c.startswith("xcodebuild") or "simctl | create" in c])
        self.assertFalse([c for c in h.calls() if "simctl | shutdown" in c])
        self.assertEqual(h.state()["devices"][R27][0]["state"], "Booted")

    def git_fixture(self, h):
        """Makes the fixture a git checkout with one commit, with a fake swift and string catalog check."""
        for name, text in (("swift", '#!/bin/sh\necho "swift | $*" >> "$STUB/calls"\n'),):
            (h.stub / "bin" / name).write_text(text)
            (h.stub / "bin" / name).chmod(0o755)
        check = h.root / "scripts/check-strings.sh"
        check.write_text("#!/bin/sh\nexit 0\n")
        check.chmod(0o755)
        git = ["git", "-C", str(h.root), "-c", "user.name=t", "-c", "user.email=t@example.com"]
        for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]):
            subprocess.run(git + args, env=h.env(), check=True, capture_output=True)

    def test_a_changed_run_that_needs_no_simulator_leaves_the_clones_alone(self):
        for path, expected in (("Packages/CassiniAudio/Tests/CassiniAudioTests/NewTests.swift", "swift | test"),
                               ("notes.txt", "nothing to test")):
            with self.subTest(path=path):
                h = Harness(self, devices={R27: [dev("ts-wt-iphone-1", udid(1), "Booted")]})
                self.git_fixture(h)
                (h.root / path).parent.mkdir(parents=True, exist_ok=True)
                (h.root / path).write_text("// changed\n")
                result = h.run("changed", "HEAD", CASSINI_RUNTIME="26")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASSED (changed)", result.stdout)
                self.assertIn(expected, result.stdout + "\n".join(h.calls()))
                self.assertFalse([c for c in h.calls() if c.startswith("xcodebuild") or "simctl | shutdown" in c])
                self.assertEqual(h.state()["devices"][R27][0]["state"], "Booted")

    def test_a_fast_run_leaves_the_clones_alone_even_with_keep_sims_0(self):
        # fast never takes the host lock, so it never shuts down clones another run of this worktree may be using.
        h = Harness(self, devices={R27: [dev("ts-wt-iphone-1", udid(1), "Booted")]})
        self.git_fixture(h)
        result = h.run("fast", CASSINI_KEEP_SIMS="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("swift | test", "\n".join(h.calls()))
        self.assertFalse([c for c in h.calls() if "simctl | shutdown" in c])
        self.assertEqual(h.state()["devices"][R27][0]["state"], "Booted")

    # lock-ready as test.sh calls it, answering at once from a non-blocking flock instead of waiting out its deadline
    # (at least 5 s): 124, its "not within the wait" status, while another process holds the lock. Any other command
    # (the hold helper) is the real test-events.py.
    LOCK_READY_NOW = r'''#!/usr/bin/python3 -I
import errno, fcntl, os, sys
here = os.path.dirname(os.path.abspath(__file__))
if sys.argv[1:2] != ["lock-ready"]:
    os.execv(sys.executable, [sys.executable, "-I", os.path.join(here, "test-events-real.py")] + sys.argv[1:])
with open(os.path.join(os.environ["STUB"], "calls"), "a") as f:
    f.write("lock-ready | %s | %s\n" % (sys.argv[3], sys.argv[5]))
fd = os.open(sys.argv[3], os.O_RDWR | os.O_CREAT, 0o644)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as error:
    sys.exit(124 if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN) else 1)
sys.exit("the lock was free: this test must hold it")
'''

    def test_a_run_that_does_not_get_the_host_lock_leaves_the_clones_alone(self):
        import fcntl
        h = Harness(self, devices={R27: [dev("ts-wt-iphone-1", udid(1), "Booted")]})
        scripts = h.root / "scripts"
        (scripts / "test-events.py").rename(scripts / "test-events-real.py")
        (scripts / "test-events.py").write_text(self.LOCK_READY_NOW)
        lock = h.home / "heavy.lock"
        with open(lock, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            result = h.run("app", CASSINI_RUNTIME="26", CASSINI_HEAVY_LOCK_HELD="", CASSINI_HEAVY_LOCK=str(lock),
                           CASSINI_LOCK_MINUTES="2")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"host busy: could not take {lock} within 2 min", result.stderr)
        # One immediate try of the lock with the wait it was given, in seconds, then no build and no clone shutdown.
        calls = [c for c in h.calls() if c.startswith(("lock-ready", "xcodebuild")) or "simctl | shutdown" in c]
        self.assertEqual(calls, ["lock-ready | <TMP>/home/heavy.lock | 120"])
        self.assertEqual(h.state()["devices"][R27][0]["state"], "Booted")

    def test_a_cassini_runtime_run_still_shuts_its_clones_down_at_the_end(self):
        h = Harness(self)
        result = h.run("app", CASSINI_RUNTIME="26")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = h.calls()
        clone = h.names()["ts-wt-iphone26-1"][1]
        last_build = max(i for i, c in enumerate(calls) if c.startswith("xcodebuild"))
        self.assertGreater(calls.index(f"xcrun | simctl | shutdown | {clone}"), last_build)
        self.assertTrue(all(d["state"] == "Shutdown" for ds in h.state()["devices"].values() for d in ds))
        # Without CASSINI_RUNTIME the iPhone stays booted after app, as before; CASSINI_KEEP_SIMS=0 shuts it down.
        for keep, state in (("", "Booted"), ("0", "Shutdown")):
            with self.subTest(keep=keep):
                h = Harness(self)
                result = h.run("app", **({"CASSINI_KEEP_SIMS": keep} if keep else {}))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(h.state()["devices"][R27][0]["state"], state)

    def test_fast_build_and_clean_ignore_cassini_runtime(self):
        h = Harness(self, devices={R27: [dev("ts-wt-iphone-1", udid(1), "Booted")]})
        for value in ("18", "eighteen"):
            with self.subTest(value=value):
                result = h.run("build", CASSINI_RUNTIME=value)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("runtime:", result.stdout)
                logs = h.root / "DerivedData.noindex"
                self.assertEqual(list(logs.glob("test-logs-ios*")), [])
                self.assertTrue((logs / "test-logs").is_dir())
                # The iPhone a run before kept booted stays booted, as after a build without the variable.
                self.assertEqual(h.state()["devices"][R27][0]["state"], "Booted")

    def test_the_booted_iphones_counted_as_free_are_this_legs_own(self):
        h = Harness(self, devices={
            R26: [dev("ts-wt-iphone26-1", udid(1), "Booted"), dev("ts-wt-iphone26-2", udid(2), "Booted")],
            R27: [dev("ts-wt-iphone-1", udid(3), "Booted"), dev("ts-wt-iphone2600-1", udid(4), "Booted")]})
        functions = ["clones", "clone_of", "our_clones", "auto_workers", "wait_for_room"]
        stubs = 'free_mb() { echo 4096; }\ncpu_idle() { echo 100; }\n'
        for tag, expected in (("26", "2"), ("", "1"), ("26.0", "0")):
            with self.subTest(tag=tag):
                result = h.shell(functions, stubs + f'runtime_tag={tag!r}; auto_workers 0')
                self.assertEqual(result.stdout.strip(), expected, result.stderr)
        # Two booted iPhones of the leg give the room the UI clones need, with nothing else free; without them, the
        # wait would start (and here fail at once: there is no resource-event helper under this root). The clock
        # stands still, so the admission deadline never decides which.
        stubs = 'free_mb() { echo 0; }\ncpu_idle() { echo 100; }\nadmit_minutes=1; root=/nonexistent\n' \
                'date() { echo 2000000000; }\n'
        result = h.shell(functions, stubs + 'runtime_tag=26; wait_for_room')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("waiting for room", result.stdout)
        result = h.shell(functions, stubs + 'runtime_tag=26.0; wait_for_room')
        self.assertIn("waiting for room", result.stdout)

    def test_an_all_run_on_another_runtime_posts_no_status(self):
        h = Harness(self)
        code = 'tier=all; extra=(); runtime_tag=18; status_skip_reason'
        result = h.shell(["status_skip_reason"], code)
        self.assertEqual(result.stdout.strip(), "CASSINI_RUNTIME is set (not the default simulator runtime)")
        # Without it the reasons are as before: here, the fixture is not a git checkout.
        result = h.shell(["status_skip_reason"], 'tier=all; extra=(); runtime_tag=""; status_skip_reason')
        self.assertEqual(result.stdout.strip(), "not a git checkout")


class OwnershipTests(unittest.TestCase):
    def owns(self, prefix, name):
        return subprocess.run(["/bin/bash", "-c", function("clone_of") + 'clone_of "$1" "$2"', "_", prefix, name]
                              ).returncode == 0

    def test_clone_of_knows_default_and_runtime_names_and_no_one_elses(self):
        for name in ("ts-wt-iphone-1", "ts-wt-ipad-1", "ts-wt-iphone18-2", "ts-wt-ipad18.6-1", "ts-wt-bench",
                     "ts-wt-shots-iphone", "ts-wt-shots-ipad"):
            with self.subTest(name=name):
                self.assertTrue(self.owns("ts-wt", name))
        # Worktrees whose names extend this one's, or that end like a runtime name, keep their clones.
        for name in ("ts-wt-b-iphone-1", "ts-wt-b-iphone18-1", "ts-wt-iphone18-iphone-1", "ts-wt-iphone18-ipad18-1",
                     "ts-wt-iphone18", "ts-wt-iphone-", "ts-wt-iphone18.-1", "ts-wtx-iphone18-1", "ts-wt-ipados18-1"):
            with self.subTest(name=name):
                self.assertFalse(self.owns("ts-wt", name))
        self.assertTrue(self.owns("ts-wt-iphone18", "ts-wt-iphone18-iphone-1"))
        self.assertFalse(self.owns("ts-wt-iphone18", "ts-wt-iphone18-1"))

    def test_clean_deletes_this_worktrees_clones_of_every_runtime_and_their_leases(self):
        h = Harness(self, WITH_18, {
            R27: [dev("ts-wt-iphone-1", udid(1), "Booted"), dev("ts-wt-ipad-1", udid(2)), dev("ts-wt-bench", udid(3)),
                  dev("ts-wt-b-iphone-1", udid(4)), dev("ts-wtx-iphone-1", udid(5))],
            R186: [dev("ts-wt-iphone18-1", udid(6)), dev("ts-wt-ipad18-1", udid(7)), dev("ts-wt-b-iphone18-1", udid(8))]})
        leases = h.cache / "sim-leases"
        (leases / "runtime").mkdir(parents=True)
        for n in (1, 4):
            (leases / udid(n)).touch()
        for n in (6, 8):
            (leases / "runtime" / udid(n)).touch()
        result = h.run("clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(h.names()), ["ts-wt-b-iphone-1", "ts-wt-b-iphone18-1", "ts-wtx-iphone-1"])
        self.assertEqual(sorted(p.name for p in leases.rglob("*") if p.is_file()), sorted([udid(4), udid(8)]))
        # With CASSINI_RUNTIME set, clean is the same.
        h.write_state(WITH_18, {R186: [dev("ts-wt-iphone18-1", udid(9))], R27: [dev("ts-wt-iphone-1", udid(10))]})
        self.assertEqual(h.run("clean", CASSINI_RUNTIME="18").returncode, 0)
        self.assertEqual(h.names(), {})

    WORKTREES = "worktree {root}\nHEAD 0\n\nworktree {base}/wt-b\nHEAD 0\n\nworktree {base}/wt-gone\nHEAD 0\n"

    def reclaim(self, functions):
        h = Harness(self, WITH_18, {
            R27: [dev("ts-wt-b-iphone-1", udid(1)), dev("ts-wt-gone-iphone-1", udid(2))],
            R186: [dev("ts-wt-b-iphone18-1", udid(3)), dev("ts-wt-b-ipad18-1", udid(4)),
                   dev("ts-wt-gone-iphone18-1", udid(5)), dev("ts-wt-iphone18-1", udid(6))]})
        (Path(h.temp.name) / "wt-b").mkdir()
        leases = h.cache / "sim-leases"
        (leases / "runtime").mkdir(parents=True)
        for n in (1, 2):
            (leases / udid(n)).touch()
        for n in (3, 4, 5, 6):
            (leases / "runtime" / udid(n)).touch()
        (leases / "runtime" / udid(99)).touch()  # a clone that no longer exists
        listing = h.stub / "worktrees"
        listing.write_text(self.WORKTREES.format(root=h.root, base=h.temp.name))
        code = f'git() {{ cat {str(listing)!r}; }}\nreclaim_disk'
        result = h.shell(functions, code)
        self.assertEqual(result.returncode, 0, result.stderr)
        return h, result, leases

    def test_reclaim_keeps_a_live_worktrees_runtime_clones_and_deletes_a_gone_ones(self):
        h, result, leases = self.reclaim(["clones", "clone_of", "reclaim_disk"])
        self.assertEqual(sorted(h.names()), ["ts-wt-b-ipad18-1", "ts-wt-b-iphone-1", "ts-wt-b-iphone18-1",
                                             "ts-wt-iphone18-1"])
        self.assertIn("deleting ts-wt-gone-iphone18-1: its worktree is gone", result.stdout)
        self.assertEqual(sorted(p.name for p in (leases / "runtime").iterdir()), [udid(3), udid(4), udid(6)])

    def test_another_worktrees_idle_shutdown_reads_a_runtime_clones_lease(self):
        h = Harness(self, WITH_18, {R186: [dev("ts-wt-b-iphone18-1", udid(1), "Booted"),
                                           dev("ts-wt-b-iphone18-2", udid(2), "Booted")]})
        runtime_leases = h.cache / "sim-leases/runtime"
        runtime_leases.mkdir(parents=True)
        (runtime_leases / udid(1)).touch()
        # Both last had an app installed an hour ago; only the first has a lease from half a minute ago, on a clock
        # that stands still at now.
        now = 2000000000
        os.utime(runtime_leases / udid(1), (now - 30, now - 30))
        for n in (1, 2):
            apps = h.home / f"Library/Developer/CoreSimulator/Devices/{udid(n)}/data/Containers/Bundle/Application"
            apps.mkdir(parents=True)
            os.utime(apps, (now - 3600, now - 3600))
        result = h.shell(["clones", "clone_of", "idle_seconds", "reap_idle_clones"],
                         f'date() {{ echo {now}; }}\nidle_minutes=15; reap_idle_clones')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ts-wt-b-iphone18-1 was used 0 min ago; leaving it booted", result.stdout)
        self.assertIn("shutting down ts-wt-b-iphone18-2, idle for 60 min", result.stdout)
        self.assertEqual([c for c in h.calls() if "shutdown" in c], [f"xcrun | simctl | shutdown | {udid(2)}"])

    def test_idle_age_drains_a_large_process_listing_after_its_first_match(self):
        h = Harness(self, WITH_18)
        # A fresh clone has neither a lease nor an app directory: its launchd age is the fallback.
        # More than a pipe buffer follows the match, as on a host running several simulator suites.
        process = f"/sim/Devices/{udid(1)}/launchd_sim"
        (h.stub / "processes").write_text(
            f"00:42 {process}\n" + "00:01 /usr/bin/unrelated\n" * 100_000 + f"02:00 {process}\n")
        result = h.shell(["idle_seconds"],
                         f'ps() {{ cat "$STUB/processes"; }}\nidle_seconds {udid(1)}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "42\n", "the first matching launchd still supplies the age")

    # The clone-deletion part of reclaim_disk and clone_of as origin/main 712f8e4 has them (abridged: without the
    # erase of oversized clones and the package-cache cleanup): what another worktree's older copy runs.
    OLD = textwrap.dedent(r'''
        clone_of() {
            local rest="${2#"$1"-}"
            [ "$rest" != "$2" ] && [[ $rest =~ ^(iphone-[0-9]+|ipad-[0-9]+|bench|shots-iphone|shots-ipad)$ ]]
        }
        reclaim_disk() {
            local worktrees w names="" keys="" udid state name p owned
            worktrees=$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p') || return 0
            [ -n "$worktrees" ] || return 0
            while IFS= read -r w; do
                [ -d "$w" ] || continue
                names="$names ts-$(basename "$w")"
            done <<< "$worktrees"
            while read -r udid state name; do
                [ "$state" = Shutdown ] || continue
                if clone_of "$prefix" "$name"; then continue; fi
                [ -f "$leases/$udid" ] || continue
                owned=""
                for p in $names; do if clone_of "$p" "$name"; then owned=1; break; fi; done
                [ -z "$owned" ] || continue
                echo "  deleting $name: its worktree is gone"
                xcrun simctl delete "$udid" 2>/dev/null && rm -f "$leases/$udid"
            done < <(clones "ts-")
            local devices lease_file
            devices=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
        import json, sys
        for devices in json.load(sys.stdin)["devices"].values():
            for d in devices: print(d["udid"])') || return 0
            for lease_file in "$leases"/*; do
                [ -f "$lease_file" ] || continue
                printf '%s\n' "$devices" | grep -qx "$(basename "$lease_file")" || rm -f "$lease_file"
            done
        }
    ''')

    def test_an_older_copy_of_reclaim_leaves_runtime_clones_and_their_leases_alone(self):
        source = SOURCE
        try:
            globals()["SOURCE"] = self.OLD + "\n" + function("clones")
            h, result, leases = self.reclaim(["clones", "clone_of", "reclaim_disk"])
        finally:
            globals()["SOURCE"] = source
        self.assertEqual(sorted(h.names()), ["ts-wt-b-ipad18-1", "ts-wt-b-iphone-1", "ts-wt-b-iphone18-1",
                                             "ts-wt-gone-iphone18-1", "ts-wt-iphone18-1"])
        self.assertNotIn("iphone18", result.stdout)
        self.assertEqual(sorted(p.name for p in (leases / "runtime").iterdir()),
                         [udid(3), udid(4), udid(5), udid(6), udid(99)])


class Ios18LegTests(unittest.TestCase):
    DEFAULT_CLONES = ("ts-wt-iphone-1", "ts-wt-iphone-2", "ts-wt-ipad-1")

    def variant(self, h, old, new):
        """The worktree's test.sh with `old` replaced by `new`."""
        path = h.root / "scripts/test.sh"
        text = path.read_text()
        self.assertEqual(text.count(old), 1, old)
        path.write_text(text.replace(old, new))

    @staticmethod
    def by_name(h):
        """The harness's calls with each clone's UDID replaced by the clone's name."""
        names = {u: n for n, (_, u) in h.names().items()}
        pattern = re.compile(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
        return [pattern.sub(lambda m: names.get(m.group(0), m.group(0)), c) for c in h.calls()]

    def test_off_by_default_an_all_run_issues_the_commands_of_a_script_without_the_leg(self):
        runs = []
        for strip in (False, True):
            h = Harness(self, WITH_18)
            if strip:
                for name in ("ios18_preflight", "run_ios18_leg"):
                    self.variant(h, function(name), name + "() { return 0; }\n")
            result = h.run("all")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            runs.append((h, result))
        (h, result), (stripped, _) = runs
        # The boot and the shards run beside each other, so only their order may differ, and clones made at the same
        # time take their UDIDs in either order: each UDID is compared as the name of its clone.
        self.assertEqual(sorted(self.by_name(h)), sorted(self.by_name(stripped)))
        self.assertFalse([c for c in h.calls() if "iphone18" in c or "prebuilt" in c])
        self.assertNotIn("iOS 18", result.stdout + result.stderr)
        self.assertEqual(sorted(p.name for p in (h.root / "DerivedData.noindex").glob("test-logs*")), ["test-logs"])

    def leg_run(self, mode, devices=None, **extra):
        h = Harness(self, WITH_18, devices)
        result = h.run("all", CASSINI_IOS18=mode, **extra)
        return h, result

    def test_the_leg_runs_after_the_default_clones_are_shut_down_and_smoke_runs_its_list_on_one_iphone(self):
        other = udid(50)
        h, result = self.leg_run("smoke", {R27: [dev("ts-other-iphone-1", other, "Booted")]})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls, names = h.calls(), h.names()
        leg_start = calls.index(f"xcrun | simctl | create | ts-wt-iphone18-1 | iPhone 16 | {R186}")
        for name in self.DEFAULT_CLONES:
            u = names[name][1]
            booted = max(i for i, c in enumerate(calls) if c == f"xcrun | simctl | bootstatus | {u} | -b")
            down = [i for i, c in enumerate(calls) if c == f"xcrun | simctl | shutdown | {u}" and booted < i < leg_start]
            self.assertTrue(down, f"{name} is shut down before the iOS 18 clone is made")
            self.assertFalse([c for c in calls[leg_start:] if c == f"xcrun | simctl | bootstatus | {u} | -b"])
        # One build, tested on both runtimes.
        self.assertEqual(len([c for c in calls if "build-for-testing" in c]), 1)
        leg_tests = [c for c in calls[leg_start:] if "test-without-building" in c]
        self.assertEqual(len(leg_tests), 2, leg_tests)
        u18 = names["ts-wt-iphone18-1"][1]
        self.assertTrue(all(f"id={u18}" in c for c in leg_tests))
        self.assertIn("-only-testing:CassiniTests", leg_tests[0])
        self.assertEqual(re.findall(r"-only-testing:CassiniUITests/\S+", leg_tests[1]),
                         ["-only-testing:CassiniUITests/AlphaTests/testOne"])
        self.assertEqual(sorted(n for n in names if "18" in n), ["ts-wt-iphone18-1"], "no second iPhone, no iPad")
        # Only this worktree's clones are touched, and all of them are down at the end.
        self.assertFalse([c for c in calls if other in c])
        self.assertTrue(all(d["state"] == "Shutdown" for n, (rt, u) in names.items() if n.startswith("ts-wt-")
                            for d in h.state()["devices"][rt] if d["udid"] == u))
        self.assertIn("iOS 18 leg: iOS 18.6 smoke: hosted 1/1 (1 skipped), iPhone 1/1", result.stdout)
        # On the iOS 18 runtime the app reads the iOS 18 facts itself: no run is given them.
        self.assertFalse([c for c in calls if "CASSINI_IOS18_FACTS" in c])
        # Logs and timing tables of each runtime are their own.
        derived = h.root / "DerivedData.noindex"
        self.assertTrue((derived / "test-logs/ui-1.log").exists() and (derived / "test-logs/hosted.log").exists())
        self.assertTrue((derived / "test-logs-ios18/ui-1.log").exists())
        self.assertTrue((derived / "test-logs-ios18/hosted.log").exists())
        self.assertEqual((h.cache / "ui-test-durations-ios18.tsv").read_text(), "AlphaTests/testOne\t4.0\n")
        self.assertEqual(len((h.cache / "ui-test-durations.tsv").read_text().splitlines()), 3)
        runtime_leases = {p.name for p in (h.cache / "sim-leases/runtime").iterdir()}
        self.assertEqual(runtime_leases, {u18})

    def test_full_runs_every_ui_test_on_the_iphones_and_the_ipad_tests_on_the_ipad(self):
        h, result = self.leg_run("full")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        names = h.names()
        self.assertEqual(sorted(n for n in names if "18" in n), ["ts-wt-ipad18-1", "ts-wt-iphone18-1", "ts-wt-iphone18-2"])
        self.assertEqual(names["ts-wt-ipad18-1"][0], R186)
        leg = "\n".join(h.calls()[h.calls().index(
            f"xcrun | simctl | create | ts-wt-iphone18-1 | iPhone 16 | {R186}"):])
        self.assertEqual(sorted(re.findall(r"-only-testing:CassiniUITests/(\S+)", leg)),
                         ["AlphaTests/testIPadTwo", "AlphaTests/testIPadTwo", "AlphaTests/testOne", "BetaTests/testThree"])
        self.assertIn("iOS 18 leg: iOS 18.6 full: hosted 1/1 (1 skipped), iPhone 3/3, iPad 1/1", result.stdout)

    def test_a_missing_runtime_with_the_leg_on_fails_the_run_and_its_status_before_building(self):
        h = Harness(self)
        h.git()
        result = h.run("all", CASSINI_IOS18="smoke", CASSINI_POST_STATUS="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the iOS 18 leg is on (CASSINI_IOS18=smoke) but no available iOS simulator runtime matches "
                      "CASSINI_IOS18_RUNTIME=18 (available: 26.0, 27.0)", result.stderr)
        self.assertFalse([c for c in h.calls() if c.startswith("xcodebuild") or c.startswith("swift")])
        self.assertEqual(h.statuses(), [("pending", "running scripts/test.sh all on drmeyers"),
                                        ("failure", "failed (exit 1): no iOS 18 runtime for the iOS 18 leg")])

    def test_after_the_one_line_switch_an_all_run_without_the_runtime_fails(self):
        h = Harness(self)
        self.variant(h, LEG_OFF, LEG_ON)
        result = h.run("all")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the iOS 18 leg is on (CASSINI_IOS18=smoke)", result.stderr)
        # And with the runtime there, it runs.
        h.write_state(WITH_18, {})
        result = h.run("all")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("iOS 18 leg: iOS 18.6 smoke: hosted 1/1 (1 skipped), iPhone 1/1", result.stdout)

    def view_branch(self, path):
        """A switched-on worktree whose branch changes `path` since origin/main."""
        h = Harness(self, WITH_18)
        self.variant(h, LEG_OFF, LEG_ON)
        h.git()
        git = ["git", "-C", str(h.root), "-c", "user.name=t", "-c", "user.email=t@example.com"]
        subprocess.run(git + ["update-ref", "refs/remotes/origin/main", "HEAD"], check=True, env=h.env())
        (h.root / path).parent.mkdir(parents=True, exist_ok=True)
        (h.root / path).write_text("// changed\n")
        for args in (["add", "-A"], ["commit", "-q", "-m", "change"]):
            subprocess.run(git + args, check=True, capture_output=True, env=h.env())
        return h

    def test_by_default_a_branch_that_changes_views_gets_the_full_leg_and_any_other_the_smoke_run(self):
        for path, mode in (("Cassini/Features/Note/NoteView.swift", "full"), ("Cassini/Design/Theme.swift", "full"),
                           ("Cassini/Adapters/Store.swift", "smoke"), ("README.md", "smoke")):
            with self.subTest(path=path):
                h = self.view_branch(path)
                result = h.run("all")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"iOS 18 leg: iOS 18.6 {mode}: hosted", result.stdout)
                self.assertEqual("ts-wt-ipad18-1" in h.names(), mode == "full")
        # Asked for by name, smoke stays smoke on a view change.
        h = self.view_branch("Cassini/Features/Note/NoteView.swift")
        result = h.run("all", CASSINI_IOS18="smoke")
        self.assertIn("iOS 18 leg: iOS 18.6 smoke: hosted", result.stdout)

    def test_the_status_says_what_ran_and_nothing_of_ios_18_while_the_leg_is_off(self):
        h = Harness(self, WITH_18)
        h.git()
        self.assertEqual(h.run("all", CASSINI_POST_STATUS="1").returncode, 0)
        self.assertEqual(h.statuses()[-1], ("success", "passed in 1 min: iPhone 3/3, iPad 1/1"))
        result = h.run("all", CASSINI_POST_STATUS="1", CASSINI_IOS18="smoke")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(h.statuses()[-1],
                         ("success", "passed in 1 min: iPhone 3/3, iPad 1/1; iOS 18.6 smoke: hosted 1/1 (1 skipped), iPhone 1/1"))
        result = h.run("all", CASSINI_POST_STATUS="1", CASSINI_IOS18="full")
        self.assertEqual(h.statuses()[-1], ("success", "passed in 1 min: iPhone 3/3, iPad 1/1; "
                                                       "iOS 18.6 full: hosted 1/1 (1 skipped), iPhone 3/3, iPad 1/1"))

    def test_a_failing_leg_fails_the_run_and_its_status_says_where(self):
        h = Harness(self, WITH_18)
        h.git()
        result = h.run("all", CASSINI_POST_STATUS="1", CASSINI_IOS18="smoke", STUB_FAIL_RUNTIME=R186)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(h.statuses()[-1],
                         ("failure", "failed (exit 1): iPhone 3/3, iPad 1/1; iOS 18.6 smoke failed: hosted 0/1 (1 skipped)"))
        self.assertTrue((h.root / "DerivedData.noindex/test-logs-ios18/FAILED").exists())

    def test_the_opt_out_posts_no_status_and_runs_no_leg(self):
        h = Harness(self, WITH_18)
        h.git()
        result = h.run("all", CASSINI_POST_STATUS="1", CASSINI_IOS18="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no commit status: CASSINI_IOS18=0 (no iOS 18 leg)", result.stdout)
        self.assertEqual(h.statuses(), [])
        self.assertFalse([c for c in h.calls() if "iphone18" in c])

    def test_the_leg_runtime_is_one_value_that_can_run_the_leg_on_ios_26_with_the_ios_18_facts(self):
        h, result = self.leg_run("smoke", CASSINI_IOS18_RUNTIME="26")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = h.calls()
        leg_start = calls.index(f"xcrun | simctl | create | ts-wt-iphone26-1 | iPhone 17 | {R26}")
        self.assertIn("iOS 26 leg: iOS 26.0 smoke: hosted 1/1 (1 skipped), iPhone 1/1", result.stdout)
        self.assertTrue((h.root / "DerivedData.noindex/test-logs-ios26/ui-1.log").exists())
        # Every test run of the leg, and none of the default runtime's, is given the iOS 18 facts.
        tests = [(i, c) for i, c in enumerate(calls) if "test-without-building" in c]
        self.assertTrue(tests and all(c.endswith(" | TEST_RUNNER_CASSINI_IOS18_FACTS=1") == (i > leg_start) for i, c in tests))

    def test_a_leg_moved_to_another_runtime_posts_no_status(self):
        h = Harness(self, WITH_18)
        h.git()
        for env in ({"CASSINI_IOS18": "smoke"}, {}):
            with self.subTest(env=env):
                result = h.run("all", CASSINI_POST_STATUS="1", CASSINI_IOS18_RUNTIME="26", **env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("no commit status: CASSINI_IOS18_RUNTIME is set (not the iOS 18 runtime)", result.stdout)
        self.assertEqual(h.statuses(), [])

    def test_the_ios18_tier_builds_and_runs_only_the_leg(self):
        h = Harness(self, WITH_18)
        result = h.run("ios18", "-only-testing:CassiniUITests/BetaTests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse([c for c in h.calls() if "ts-wt-iphone-" in c or c.startswith("swift")])
        ui = [c for c in h.calls() if "test-without-building" in c and "CassiniUITests/" in c]
        self.assertEqual([re.findall(r"CassiniUITests/(\S+)", c) for c in ui], [["BetaTests/testThree"]])

    def test_the_legs_own_run_shuts_its_clones_down_under_the_callers_lock(self):
        # The leg's run gets CASSINI_HEAVY_LOCK_HELD=1 and never takes the lock itself; it still counts as a run that
        # got the lock, so it shuts its clones down, even when the calling run keeps its own booted.
        h = Harness(self, WITH_18)
        result = h.run("ios18", CASSINI_KEEP_SIMS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        u18 = h.names()["ts-wt-iphone18-1"][1]
        self.assertIn(f"xcrun | simctl | shutdown | {u18}", h.calls())
        self.assertTrue(all(d["state"] == "Shutdown" for d in h.state()["devices"][R186] if d["udid"] == u18))

    def test_bad_values_are_refused_before_anything_runs(self):
        h = Harness(self, WITH_18)
        for tier, env, message in (("all", {"CASSINI_IOS18": "yes"}, "none of smoke, full and 0"),
                                   ("ios18", {"CASSINI_IOS18": "0"}, "nothing to run"),
                                   ("all", {"CASSINI_IOS18": "smoke", "CASSINI_IOS18_RUNTIME": "eighteen"}, "neither"),
                                   # An identifier without a version must not fall back to the default runtime.
                                   ("ios18", {"CASSINI_IOS18_RUNTIME": "com.apple.CoreSimulator.SimRuntime.iOS-"},
                                    "CASSINI_IOS18_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS- is neither")):
            with self.subTest(tier=tier, env=env):
                result = h.run(tier, **env)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
        self.assertEqual(h.calls(), [])
        result = h.run("prebuilt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no .xctestrun", result.stderr)

    def test_hosted_counts(self):
        h = Harness(self)
        for line, expected in (("Executed 82 tests, with 6 tests skipped and 0 failures (0 unexpected) in 9.1 (9.2) seconds",
                                "76/76 (6 skipped)"),
                               ("Executed 1 test, with 1 test skipped and 0 failures (0 unexpected)", "0/0 (1 skipped)"),
                               ("Executed 82 tests, with 2 failures (0 unexpected) in 9.1 (9.2) seconds", "80/82"),
                               ("", "")):
            with self.subTest(line=line):
                (h.root / "hosted.log").write_text("Test Suite 'All tests' passed\n" + line + "\n")
                # Under set -e, as the script calls it: a log without counts gives none and goes on.
                result = h.shell(["hosted_counts"], f'x=$(hosted_counts {str(h.root / "hosted.log")!r}); echo "$x|reached"')
                self.assertEqual(result.stdout.strip(), expected + "|reached", result.stderr)

    def test_hosted_counts_after_a_crash_count_every_launch(self):
        # As on iOS 18.2: a test crashes the host, xcodebuild relaunches it, and the last "Executed" line covers only
        # the relaunch. The crashed test has no "failed (" line, only its entry in "Failing tests:".
        h = Harness(self)
        case = "Test Case '-[CassiniTests.T test{}]' {} (0.001 seconds)."
        (h.root / "hosted.log").write_text("\n".join([
            case.format("A", "passed"), case.format("B", "skipped"), case.format("C", "failed"),
            "Test Case '-[CassiniTests.T testD]' started.",
            "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.",
            case.format("E", "passed"),
            "\t Executed 1 test, with 0 failures (0 unexpected) in 0.002 (0.003) seconds",
            "Failing tests:", "\tT.testC()", "\tT.testD()", "", "** TEST EXECUTE FAILED **", ""]))
        result = h.shell(["hosted_counts"], f'hosted_counts {str(h.root / "hosted.log")!r}')
        self.assertEqual(result.stdout.strip(), "2/4 (1 skipped)", result.stderr)

    def test_a_hosted_run_whose_host_never_launches_still_says_why(self):
        h = Harness(self)
        result = h.run("app", STUB_HOST_FAILS="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("xcodebuild: error: Failed to launch the test host", result.stderr)
        self.assertIn("see ", result.stderr)

    def test_the_smoke_list_names_ui_tests_and_plans_about_five_minutes(self):
        h = Harness(self)
        listed = [line.split("#")[0].strip() for line in (ROOT / "scripts/ios18-smoke-tests.txt").read_text().splitlines()]
        listed = [line for line in listed if line]
        code = (f'ui_tests {str(ROOT)!r}/CassiniUITests/*.swift')
        known = set(h.shell(["ui_tests"], code).stdout.split())
        self.assertFalse([t for t in listed if t not in known], "every line names a UI test")
        self.assertEqual(len(listed), len(set(listed)))
        code = (f'timings_file=/nonexistent; committed_timings={str(ROOT / "scripts/ui-test-durations.tsv")!r}\n'
                'printf "%s\\n" ' + " ".join(listed) + ' | planned_seconds')
        planned = int(h.shell(["planned_seconds"], code).stdout)
        self.assertLessEqual(planned, 340, f"the smoke list plans {planned} s")
        committed = {line.split("\t")[0] for line in (ROOT / "scripts/ui-test-durations.tsv").read_text().splitlines()}
        self.assertFalse([t for t in listed if t not in committed], "every listed test has a measured time")


if __name__ == "__main__":
    unittest.main()
