#!/usr/bin/env python3
"""CASSINI_RUNTIME regressions for scripts/test.sh with fake xcrun, xcodebuild and xcodegen: no simulators or builds.

Covers the runtime pick, the device types per runtime, clone names and leases per runtime, never reusing a clone of
another runtime, which clones clean and the disk reclaim (also an older copy of it) treat as whose, separate logs and
timing tables, and that without CASSINI_RUNTIME a run issues the commands it always did.
"""
import json
import os
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
            "supportedDeviceTypes": [{"name": t} for t in types]}


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
import os, plistlib, sys
stub = os.environ["STUB"]
args = sys.argv[1:]
with open(os.path.join(stub, "calls"), "a") as f:
    f.write("xcodebuild | " + " | ".join(args) + "\n")
if "build-for-testing" in args:
    products = os.path.join(args[args.index("-derivedDataPath") + 1], "Build", "Products")
    os.makedirs(products, exist_ok=True)
    with open(os.path.join(products, "Cassini_Cassini_iphonesimulator27.0-arm64.xctestrun"), "wb") as f:
        plistlib.dump({"CassiniTests": {}, "CassiniUITests": {}, "__xctestrun_metadata__": {"FormatVersion": 1}}, f)
elif "test-without-building" in args:
    for a in args:
        if a == "-only-testing:CassiniTests":
            print("Test Case '-[CassiniTests.HostedTests testHosted]' started.")
            print("Test Case '-[CassiniTests.HostedTests testHosted]' passed (0.100 seconds).")
            print("Executed 1 tests, with 0 failures")
        elif a.startswith("-only-testing:CassiniUITests/"):
            cls, method = a.split("/", 1)[1].split("/")
            print("Test Case '-[CassiniUITests.%s %s]' started." % (cls, method))
            print("Test Case '-[CassiniUITests.%s %s]' passed (4.000 seconds)." % (cls, method))
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
        for name in ("test.sh", "test-events.py", "ui-test-durations.tsv"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / "Package.swift").write_text("// fixture\n")
        (self.root / "Package.resolved").write_text("{}\n")
        (self.root / "CassiniUITests/Fixture.swift").write_text(UI_TESTS)
        tools = {"xcrun": FAKE_XCRUN, "xcodebuild": FAKE_XCODEBUILD, "xcodegen": "#!/bin/sh\nexit 0\n"}
        for name, text in tools.items():
            (self.stub / "bin" / name).write_text(text)
            (self.stub / "bin" / name).chmod(0o755)
        self.write_state(runtimes, devices or {})

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
        return h.shell(["select_runtime"], code, **env)

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

    def test_an_invalid_value_is_refused_before_anything_runs(self):
        h = Harness(self)
        result = h.run("app", CASSINI_RUNTIME="eighteen")
        self.assertEqual(result.returncode, 2)
        self.assertIn("neither a version", result.stderr)
        self.assertEqual(h.calls(), [])


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

    def test_a_second_runtime_has_its_own_clones_leases_logs_and_timing_table(self):
        h = Harness(self, devices={R27: [dev("ts-wt-iphone-1", udid(1), "Booted")]})
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
        self.assertTrue(all(d["state"] == "Shutdown" for ds in h.state()["devices"].values() for d in ds))
        self.assertEqual((default_logs / "ui-1.log").read_text(), "the default leg's log\n")
        self.assertTrue((h.root / "DerivedData.noindex/test-logs-ios26/ui-1.log").exists())
        self.assertEqual((h.cache / "ui-test-durations.tsv").read_text(), "AlphaTests/testOne\t10.0\n")
        self.assertIn("AlphaTests/testOne\t4.0", (h.cache / "ui-test-durations-ios26.tsv").read_text())
        top = {p.name for p in (h.cache / "sim-leases").iterdir() if p.is_file()}
        runtime_leases = {p.name for p in (h.cache / "sim-leases/runtime").iterdir()}
        ours = {u for name, (_, u) in h.names().items() if "26-" in name}
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
        h = Harness(self)
        result = h.run("app", CASSINI_RUNTIME="18", CASSINI_POST_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no available iOS simulator runtime matches CASSINI_RUNTIME=18 (available: 26.0, 27.0)",
                      result.stderr)
        self.assertIn("FAILED (app)", result.stdout)
        self.assertTrue((h.root / "DerivedData.noindex/test-logs-ios18/FAILED").exists())
        self.assertFalse([c for c in h.calls() if c.startswith("xcodebuild") or "simctl | create" in c])

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

    # reclaim_disk and clone_of as origin/main 712f8e4 has them: what another worktree's older copy runs.
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


if __name__ == "__main__":
    unittest.main()
