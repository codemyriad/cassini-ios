#!/bin/bash
# Runs Cassini's tests in tiers and prints how long each step took.
#
#   scripts/test.sh fast     the string catalog check (scripts/check-strings.sh), then the Swift package tests
#   scripts/test.sh app      build for testing, then the hosted unit tests (CassiniTests)
#   scripts/test.sh ui       build for testing, then the UI tests, sharded across simulator clones
#   scripts/test.sh all      fast, app and ui (the package tests run beside the build)
#   scripts/test.sh changed [base]
#                            only what the changes since base touch (default: where the branch left main, plus
#                            uncommitted and untracked files): the string catalog check when a source or a catalog
#                            changed, the package test targets, the hosted tests and the UI test classes of the
#                            changed areas. For iterating; run all once before finishing.
#   scripts/test.sh build    only build for testing (scripts/screenshots.sh runs its tests from that build)
#   scripts/test.sh clean    shut down and delete this worktree's simulator clones
#
# Extra arguments after the tier go to every xcodebuild test run, e.g.
#   scripts/test.sh ui -only-testing:CassiniUITests/NoteScreenTests
# (-only-testing:CassiniUITests/Class or /Class/method selections are sharded like a full run).
#
# Environment:
#   CASSINI_UI_WORKERS   UI shards (default: as many as memory allows, at most 3)
#   CASSINI_UI_IPAD      what the iPad clone runs: the tests named testIPad* (default), all (every UI test, beside
#                        the iPhone shards; the longest step then) or 0 (nothing)
#   CASSINI_KEEP_SIMS=0  shut the clones down afterwards (default: keep the iPhones booted for the next run)
#   CASSINI_IDLE_MINUTES booted clones of other worktrees that no xcodebuild has used for this long are shut down,
#                        never deleted (default 15)
#   CASSINI_TEST_CACHE   shared cache directory (default: .test-cache beside the main checkout's .git)
#   CASSINI_IPHONE / CASSINI_IPAD  device types to clone (default "iPhone 17", "iPad Pro 13-inch (M5)")
#   CASSINI_SIM_PREFIX   clone name prefix (default ts-<worktree directory name>)
#
# Builds go to <worktree>/DerivedData.noindex (DerivedData links to it; Spotlight skips a .noindex directory), which
# persists between runs so later builds are incremental. Package checkouts are shared between worktrees under the
# cache, one directory per Package.resolved: Xcode's directly, SwiftPM's as a copy-on-write seed for a worktree without
# .build/. Logs and result bundles are in DerivedData/test-logs (the run before in DerivedData/test-logs.previous, and
# the five newest failed runs in DerivedData/test-logs.failed).
# The UI shards are balanced by each test's measured time averaged with the one stored before, kept in the cache
# (scripts/ui-test-durations.tsv when the cache has none).
set -euo pipefail

tier="${1:-all}"; [ $# -gt 0 ] && shift
base_ref=""
if [ "$tier" = changed ] && [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then base_ref="$1"; shift; fi
extra=("$@")

root="$(cd "$(dirname "$0")/.." && pwd)"
# A copy without .git (scripts/test-remote.sh) keeps its cache beside itself.
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$root/.git")"
cache="${CASSINI_TEST_CACHE:-$(dirname "$common")/.test-cache}"
derived="$root/DerivedData.noindex"
logs="$derived/test-logs"
prefix="${CASSINI_SIM_PREFIX:-ts-$(basename "$root")}"
iphone_type="${CASSINI_IPHONE:-iPhone 17}"
ipad_type="${CASSINI_IPAD:-iPad Pro 13-inch (M5)}"
keep_sims="${CASSINI_KEEP_SIMS:-1}"
idle_minutes="${CASSINI_IDLE_MINUTES:-15}"
leases="$cache/sim-leases"

# Spotlight indexes a build folder in an indexed location; it skips a directory whose name ends in .noindex (and
# ignores .metadata_never_index there). An older DerivedData moves over once, and the old name links to the new one.
if [ -d "$root/DerivedData" ] && [ ! -L "$root/DerivedData" ] && [ ! -e "$derived" ]; then
    mv "$root/DerivedData" "$derived"
fi
mkdir -p "$cache" "$derived" "$leases"
[ -e "$root/DerivedData" ] || ln -s "$(basename "$derived")" "$root/DerivedData"
# The previous run's logs stay beside this run's. A failed run's logs (marked FAILED by summary) then move to
# test-logs.failed/<when it failed>, which keeps the five newest: a flaky failure is not lost to the next two runs.
failed_logs="$logs.failed"
if [ -e "$logs.previous/FAILED" ]; then
    mkdir -p "$failed_logs"
    mv "$logs.previous" "$failed_logs/$(date -r "$logs.previous/FAILED" +%Y%m%d-%H%M%S)"
    ls -1 "$failed_logs" | sort -r | tail -n +6 | while read -r old; do rm -rf "${failed_logs:?}/$old"; done
fi
if [ -d "$logs" ]; then rm -rf "$logs.previous"; mv "$logs" "$logs.previous"; fi
mkdir -p "$logs"

# ---------------------------------------------------------------- timing

timings=""
started_all=$(date +%s)
step_start() { step_name="$1"; step_t0=$(date +%s); printf '==> %s\n' "$1"; }
step_end() {
    local secs=$(( $(date +%s) - step_t0 ))
    timings="${timings}$(printf '%-34s %5ss' "$step_name" "$secs")"$'\n'
}
summary() {
    local rc=$?
    # A swift test beside the build that has not been waited for (a failure stopped the run) ends here.
    if [ -n "${fast_pid:-}" ]; then pkill -P "$fast_pid" 2>/dev/null || true; kill "$fast_pid" 2>/dev/null || true; fi
    printf '\n%-34s %6s\n' "step" "time"
    printf '%s' "$timings"
    printf '%-34s %5ss\n' "total" "$(( $(date +%s) - started_all ))"
    if [ $rc -eq 0 ]; then echo "PASSED ($tier)"; else
        echo "$tier exit $rc" > "$logs/FAILED"
        echo "FAILED ($tier), logs in $logs (kept in $failed_logs after the next run)"
    fi
    if [ "$keep_sims" = "0" ]; then shutdown_clones; fi
}

die() { echo "error: $*" >&2; exit 1; }

# $1 and every process it started, deepest first, so none is left behind when its parent goes.
process_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do process_tree "$child"; done
    echo "$1"
}

# Ends the processes $2... with signal $1.
signal_all() { local sig="$1"; shift; for pid in "$@"; do kill -"$sig" "$pid" 2>/dev/null || true; done; }

# Ends process $1 and everything it started: TERM, then KILL for what is still there five seconds later.
end_tree() {
    local pid="$1" pids
    pids=$(process_tree "$pid")
    # shellcheck disable=SC2086
    signal_all TERM $pids
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    # shellcheck disable=SC2086
    signal_all KILL $pids
    wait "$pid" 2>/dev/null || true
}

# Runs the command after $2 with its output in $1, ending it once it has run $2 seconds: a step that hangs fails the
# run instead of holding it (once xcodebuild -resolvePackageDependencies deadlocked and held a run for two hours).
# Returns the command's status, or 124 when it was ended.
run_limited() {
    local log="$1" limit="$2" pid waited=0; shift 2
    "$@" > "$log" 2>&1 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ $waited -ge "$limit" ]; then
            echo "test.sh: still running after ${limit}s; ended" >> "$log"
            end_tree "$pid"
            return 124
        fi
        sleep 1; waited=$(( waited + 1 ))
    done
    wait "$pid"
}

# A step's output goes to its log; on failure the tail is shown. $2 is its time limit in seconds (run_limited).
run_logged() {
    local log="$1" limit="$2"; shift 2
    if ! run_limited "$log" "$limit" "$@"; then
        grep -E "error:|failed|FAILED|\*\* |^test\.sh: " "$log" | tail -40 >&2 || tail -40 "$log" >&2
        echo "see $log" >&2
        return 1
    fi
}

# ---------------------------------------------------------------- simulators

runtime_id() {
    xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])'
}

# The UDID of the clone called $1, created from device type $2 when missing.
clone_udid() {
    local name="$1" type="$2" udid
    udid=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == name and d["isAvailable"]: print(d["udid"]); sys.exit()' "$name")
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl create "$name" "$type" "$(runtime_id)")
    fi
    echo "$udid"
}

# Marks a clone as used now; other worktrees' runs leave a clone alone while its lease is fresh.
lease() { touch "$leases/$1"; }

# Boots a clone and waits until it can install apps; a booted one returns at once.
boot() {
    local udid="$1"
    lease "$udid"
    xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 || xcrun simctl bootstatus "$udid" -b > /dev/null
}

# "udid state name" of the clones whose name starts with $1- (default: this worktree's prefix).
clones() {
    xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
prefix = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"].startswith(prefix): print(d["udid"], d["state"], d["name"])' "$1"
}
our_clones() { clones "$prefix-"; }

shutdown_clones() {
    our_clones | while read -r udid state _; do
        [ "$state" = "Booted" ] && xcrun simctl shutdown "$udid" 2>/dev/null || true
    done
}

delete_clones() {
    our_clones | while read -r udid _; do
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl delete "$udid"
        rm -f "$leases/$udid"
    done
}

# Seconds since the clone was last used: its lease; for a clone without one (booted by an older script or by hand),
# since an app was last installed or removed there, or else since it booted.
idle_seconds() {
    local udid="$1" now apps; now=$(date +%s)
    if [ -f "$leases/$udid" ]; then echo $(( now - $(stat -f %m "$leases/$udid") )); return; fi
    apps="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Bundle/Application"
    if [ -d "$apps" ]; then echo $(( now - $(stat -f %m "$apps") )); return; fi
    ps -Ao etime=,args= | awk -v u="Devices/$udid/" '$0 ~ /launchd_sim/ && index($0, u) {
        t = $1; d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
        n = split(t, b, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + b[i]; print d * 86400 + s; found = 1; exit }
        END { if (!found) print 0 }'
}

# Booted test clones of other worktrees: shut down (never deleted) when no xcodebuild uses them and they have been
# idle for $idle_minutes; otherwise left alone, their memory counted as in use. Prints what it did.
reap_idle_clones() {
    local busy udid state name idle
    busy=$(ps -Ao args= | grep -E '(^|/)xcodebuild ' | grep -oE 'id=[0-9A-F-]{36}' | cut -c4- | sort -u || true)
    while read -r udid state name; do
        [ "$state" = Booted ] || continue
        case "$name" in "$prefix-"*) continue ;; esac
        if printf '%s\n' "$busy" | grep -qx "$udid"; then echo "  $name is in use by an xcodebuild"; continue; fi
        idle=$(idle_seconds "$udid")
        if [ "$idle" -ge $(( idle_minutes * 60 )) ]; then
            echo "  shutting down $name, idle for $(( idle / 60 )) min"
            xcrun simctl shutdown "$udid" 2>/dev/null || true
        else
            echo "  $name was used $(( idle / 60 )) min ago; leaving it booted"
        fi
    done < <(clones "ts-")
}

# Shards that fit in memory while leaving about 4 GB for everything else; each booted simulator with the app and its
# test runner takes about 1.5 GB. Clones of ours that are already booted count as available. At most 3: on 10 cores
# three shards already keep the CPU busy (simulator launches are CPU-bound), and a fourth made every test slower.
auto_workers() {
    local page free booted
    page=$(sysctl -n hw.pagesize)
    free=$(vm_stat | awk -v p="$page" '/Pages (free|inactive|speculative|purgeable)/ { gsub("\\.", "", $NF); n += $NF } END { print int(n * p / 1048576) }')
    booted=$(our_clones | grep -c "Booted $prefix-iphone-" || true)
    local n=$(( (free - 4096) / 1536 + booted ))
    [ $n -gt 3 ] && n=3
    [ $n -lt 1 ] && n=1
    echo $n
}

# ---------------------------------------------------------------- builds

conformance_env() {
    # Worktrees sit away from the cassini-format checkout the tests look for beside the repository.
    if [ -z "${CASSINI_CONFORMANCE:-}" ]; then
        local candidate
        for candidate in "$root/../cassini-format" "$(dirname "$(dirname "$common")")/cassini-format"; do
            if [ -d "$candidate/spec/conformance" ]; then
                export CASSINI_CONFORMANCE="$(cd "$candidate/spec/conformance" && pwd)"; break
            fi
        done
    fi
}

package_key() { cat "$root/Package.resolved" "$root/Package.swift" | shasum | cut -c1-12; }

# The files of .build/ that hold the resolved dependencies and name this worktree's path: the workspace state and
# each checkout's link to its repository.
swiftpm_path_files() {
    local build="$1" checkout
    echo "$build/workspace-state.json"
    for checkout in "$build"/checkouts/*; do
        [ -f "$checkout/.git/config" ] && echo "$checkout/.git/config"
        [ -f "$checkout/.git/objects/info/alternates" ] && echo "$checkout/.git/objects/info/alternates"
    done
}

# A worktree without .build/ starts from the dependencies another worktree resolved for the same Package.resolved,
# cloned (APFS copy-on-write) with the paths moved over: SwiftPM otherwise fetches the packages again, minutes over the
# network.
seed_swiftpm() {
    local shared="$cache/swiftpm-$(package_key)" file
    [ -f "$root/.build/workspace-state.json" ] || [ ! -f "$shared/workspace-state.json" ] && return 0
    mkdir -p "$root/.build"
    cp -cR "$shared/repositories" "$shared/checkouts" "$shared/artifacts" "$shared/workspace-state.json" "$root/.build/" 2>/dev/null || {
        rm -rf "$root/.build"; return 0; }
    swiftpm_path_files "$root/.build" | while IFS= read -r file; do
        sed -i '' "s|@WORKTREE@|$root|g" "$file"
    done
}

# Keeps this worktree's resolved dependencies for the next fresh worktree, once per Package.resolved.
save_swiftpm() {
    local shared="$cache/swiftpm-$(package_key)" tmp file
    [ -f "$shared/workspace-state.json" ] || [ ! -f "$root/.build/workspace-state.json" ] && return 0
    tmp="$shared.tmp.$$"
    rm -rf "$tmp"; mkdir -p "$tmp"
    cp -cR "$root/.build/repositories" "$root/.build/checkouts" "$root/.build/artifacts" "$root/.build/workspace-state.json" "$tmp/" 2>/dev/null || {
        rm -rf "$tmp"; return 0; }
    swiftpm_path_files "$tmp" | while IFS= read -r file; do
        sed -i '' "s|$root|@WORKTREE@|g" "$file"
    done
    mv "$tmp" "$shared" 2>/dev/null || rm -rf "$tmp"
}

check_strings() {
    step_start "string catalogs"
    run_logged "$logs/check-strings.log" 300 "$root/scripts/check-strings.sh"
    step_end
}

# swift test, filtered by $1 when given (a regular expression over Target.Suite/test).
swift_test() {
    local filter="${1:-}"
    conformance_env
    seed_swiftpm
    # The checkouts are saved whatever the tests did; the tests' failure is the function's, also where it is called
    # as `swift_test || rc=$?`, which turns errexit off inside it.
    local rc=0
    run_logged "$logs/swift-test.log" 1800 swift test ${filter:+--filter "$filter"} || rc=$?
    save_swiftpm
    return "$rc"
}

tier_fast() {
    check_strings
    step_start "swift test${1:+ (filtered)}"
    swift_test "${1:-}"
    step_end
    grep -E "^✔ Test run with|^✘ Test run with" "$logs/swift-test.log" || true
}

# swift test beside the build: it and the simulator work hardly compete (SwiftPM builds only the packages, once, and
# its tests take a few seconds of CPU). Its time is added to the summary when it is waited for.
fast_pid=""
start_fast_beside() {
    ( local t0; t0=$(date +%s); rc=0; swift_test "${1:-}" 2> /dev/null || rc=$?
      echo "$(( $(date +%s) - t0 )) $rc" > "$logs/swift-test.result" ) &
    fast_pid=$!
    echo "==> swift test${1:+ (filtered)} (beside the build)"
}
wait_fast_beside() {
    [ -n "$fast_pid" ] || return 0
    wait "$fast_pid" || true; fast_pid=""
    local secs rc; read -r secs rc < "$logs/swift-test.result" || { secs=0; rc=1; }
    timings="${timings}$(printf '%-34s %5ss' "swift test (beside the build)" "$secs")"$'\n'
    grep -E "^✔ Test run with|^✘ Test run with" "$logs/swift-test.log" || true
    if [ "$rc" != 0 ]; then
        grep -E "error:|✘|failed|FAILED" "$logs/swift-test.log" | tail -40 >&2 || tail -40 "$logs/swift-test.log" >&2
        echo "swift test failed, see $logs/swift-test.log" >&2
        return 1
    fi
}

packages_dir() { echo "$cache/SourcePackages-$(package_key)"; }

xcode_flags() {
    printf '%s\n' -project "$root/Cassini.xcodeproj" -scheme Cassini -derivedDataPath "$derived" \
        -clonedSourcePackagesDirPath "$(packages_dir)" -disableAutomaticPackageResolution -skipPackageUpdates \
        -skipMacroValidation -skipPackagePluginValidation
}

build_for_testing() {
    local flags=() line
    while IFS= read -r line; do flags+=("$line"); done < <(xcode_flags)

    step_start "xcodegen"
    (cd "$root" && run_logged "$logs/xcodegen.log" 300 xcodegen generate --quiet)
    step_end

    step_start "resolve packages"
    # One resolve at a time per package set: worktrees share the checkouts. A resolve takes seconds once the
    # checkouts exist; the limit covers a first clone and waiting for another worktree's resolve. A resolve that
    # deadlocked once went through at once when run again, so an ended one gets one more try.
    mkdir -p "$(packages_dir)"
    local resolve=(/usr/bin/lockf "$(packages_dir).lock"
        xcodebuild -resolvePackageDependencies -project "$root/Cassini.xcodeproj" -scheme Cassini
        -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$(packages_dir)" -onlyUsePackageVersionsFromResolvedFile)
    local rc=0
    run_limited "$logs/resolve.log" 600 "${resolve[@]}" || rc=$?
    if [ "$rc" = 124 ]; then
        mv "$logs/resolve.log" "$logs/resolve-attempt-1.log"
        echo "  resolve packages: still running after 600s; trying once more"
        rc=0; run_limited "$logs/resolve.log" 600 "${resolve[@]}" || rc=$?
    fi
    if [ "$rc" != 0 ]; then
        tail -40 "$logs/resolve.log" >&2; echo "see $logs/resolve.log" >&2
        # Both hangs seen so far waited on a file claim of an Xcode app whose main thread had stopped responding.
        [ "$rc" = 124 ] && pgrep -x Xcode > /dev/null &&
            echo "Xcode is open: when it has stopped responding it holds the project's file claims; quit it and run again" >&2
        return 1
    fi
    step_end

    step_start "build for testing"
    # An incremental build takes seconds and a clean one minutes.
    run_logged "$logs/build.log" 2400 xcodebuild build-for-testing "${flags[@]}" \
        -destination 'generic/platform=iOS Simulator' \
        CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
    step_end
    xctestrun=$(ls -t "$derived"/Build/Products/Cassini_*.xctestrun 2>/dev/null | grep -v '\.only-' | head -1)
    [ -n "$xctestrun" ] || die "no .xctestrun in $derived/Build/Products"
    # One test target per run: with both in the .xctestrun, xcodebuild installs the app for the hosted tests too,
    # and that install can land after the UI test runner has started, ending the app under the first UI test.
    for target in CassiniTests CassiniUITests; do
        /usr/bin/python3 - "$xctestrun" "${xctestrun%.xctestrun}.only-$target.xctestrun" "$target" <<'PY'
import plistlib, sys
source, destination, target = sys.argv[1:4]
with open(source, "rb") as f:
    run = plistlib.load(f)
with open(destination, "wb") as f:
    plistlib.dump({key: value for key, value in run.items() if key == target or key.startswith("__")}, f)
PY
    done
}

# Runs "$@" with its output in $1. When no test has started $2 seconds in (the test host or runner never came up),
# ends it and returns 124. Once a test runs, xcodebuild's own per-test time limit applies, and the whole run is ended
# $3 seconds in, returning 125.
run_watched() {
    local log="$1" limit="$2" total="$3" pid waited=0 started=0; shift 3
    "$@" > "$log" 2>&1 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ $started = 0 ] && grep -q "^Test Case '" "$log" 2>/dev/null; then started=1; fi
        if [ $started = 0 ] && [ $waited -ge "$limit" ]; then
            echo "test.sh: no test started within ${limit}s; ending xcodebuild" >> "$log"
            end_tree "$pid"
            return 124
        fi
        # Each test has its own allowance; this catches xcodebuild itself hanging between or after tests.
        if [ $waited -ge "$total" ]; then
            echo "test.sh: still running after ${total}s; ending xcodebuild" >> "$log"
            end_tree "$pid"
            return 125
        fi
        sleep 1; waited=$(( waited + 1 ))
    done
    wait "$pid"
}

# xcodebuild test-without-building of one test target on one simulator; $1 target, $2 log, $3 result bundle,
# $4 udid, the rest test arguments.
test_on() {
    local target="$1" log="$2" bundle="$3" udid="$4" app rc=0; shift 4
    rm -rf "$bundle"
    lease "$udid"
    # xcodebuild replaces an installed app while it starts the tests, and a launch that meets the replacement fails
    # or hangs. Without an installed app (or a left-over Live Activity of it) there is nothing to replace.
    for app in io.codemyriad.cassini io.codemyriad.CassiniUITests.xctrunner; do
        xcrun simctl terminate "$udid" "$app" > /dev/null 2>&1 || true
        xcrun simctl uninstall "$udid" "$app" > /dev/null 2>&1 || true
    done
    # The hosted tests start within seconds and the UI runner within a minute; a run that has not started by then
    # is stuck (once, the hosted tests hung for five minutes before xcodebuild gave up).
    # A whole run: the hosted tests take about a minute, a UI shard about twenty.
    local limit=90 total=900; [ "$target" = CassiniUITests ] && limit=180 total=3600
    run_watched "$log" "$limit" "$total" xcodebuild test-without-building \
        -xctestrun "${xctestrun%.xctestrun}.only-$target.xctestrun" \
        -destination "platform=iOS Simulator,id=$udid" \
        -resultBundlePath "$bundle" -collect-test-diagnostics never -parallel-testing-enabled NO \
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 \
        "$@" ${extra_xcodebuild[@]+"${extra_xcodebuild[@]}"} || rc=$?
    lease "$udid"
    return $rc
}

# Whether a test run never got to its first test: it hung, or the app or runner failed to launch.
never_started() {
    local rc="$1" log="$2"
    [ "$rc" = 124 ] && return 0
    [ "$rc" != 0 ] && ! grep -q "^Test Case '" "$log" && grep -qiE "failed to launch|failed to install|early unexpected exit|test runner never began|unknown to FrontBoard" "$log"
}

# test_on once more when the first run never started a test: at once when the app or runner failed to launch
# (FrontBoard sometimes has not registered an app installed a moment before), on a freshly booted clone when it hung.
test_on_retrying() {
    local target="$1" log="$2" bundle="$3" udid="$4" rc=0
    test_on "$@" || rc=$?
    if never_started "$rc" "$log"; then
        mv "$log" "${log%.log}-attempt-1.log"
        if [ "$rc" = 124 ]; then
            echo "  $(basename "$log" .log): no test started; rebooting the clone and trying once more"
            xcrun simctl shutdown "$udid" > /dev/null 2>&1 || true
            boot "$udid"
        else
            echo "  $(basename "$log" .log): the test host or runner did not launch; trying once more"
        fi
        rc=0; test_on "$@" || rc=$?
    fi
    return $rc
}

# ---------------------------------------------------------------- tiers

boot_pid=""
first_iphone=""
start_first_boot() {
    first_iphone=$(clone_udid "$prefix-iphone-1" "$iphone_type")
    boot "$first_iphone" & boot_pid=$!
}
wait_first_boot() {
    if [ -n "$boot_pid" ]; then wait "$boot_pid" || die "could not boot $prefix-iphone-1"; boot_pid=""; fi
}

tier_app() {
    step_start "hosted tests (CassiniTests)"
    wait_first_boot
    local rc=0
    test_on_retrying CassiniTests "$logs/hosted.log" "$logs/hosted.xcresult" "$first_iphone" -only-testing:CassiniTests || rc=$?
    if [ $rc != 0 ]; then
        grep -E "error:|failed \(|\*\* TEST|test.sh:" "$logs/hosted.log" | tail -20 >&2; echo "see $logs/hosted.log" >&2
        step_end; return 1
    fi
    step_end
    grep -E "Executed [0-9]+ tests" "$logs/hosted.log" | tail -1 || true
}

# The UI test methods, as Class/method, read from the sources (one class per file is not assumed).
ui_tests() {
    [ $# -gt 0 ] || set -- "$root"/CassiniUITests/*.swift
    awk '
        FNR == 1 { cls = "" }
        /^[ \t]*((final|private|fileprivate|public|open|internal) )*class [A-Za-z0-9_]+/ { cls = "" }
        /^(final )?class [A-Za-z0-9_]+: XCTestCase/ { match($0, /class [A-Za-z0-9_]+/); cls = substr($0, RSTART + 6, RLENGTH - 6) }
        cls != "" && /func test[A-Za-z0-9_]*\(/ { match($0, /func test[A-Za-z0-9_]*/); print cls "/" substr($0, RSTART + 5, RLENGTH - 5) }
    ' "$@"
}

# Shared between worktrees, so a fresh worktree balances its first run too; the committed table covers a fresh cache.
timings_file="$cache/ui-test-durations.tsv"
committed_timings="$root/scripts/ui-test-durations.tsv"

# Splits the tests on stdin into $1 shards, longest first onto the least loaded shard, by their measured durations
# (15 s for a test without one). Prints "shard<TAB>test".
plan_shards() {
    local n="$1"
    awk -v n="$n" -v f="$timings_file" -v c="$committed_timings" '
        BEGIN {
            while ((getline line < c) > 0) { split(line, p, "\t"); d[p[1]] = p[2] }
            while ((getline line < f) > 0) { split(line, p, "\t"); d[p[1]] = p[2] }
        }
        NF { t[++m] = $0; w[m] = ($0 in d) ? d[$0] : 15 }
        END {
            for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (w[j] > w[i]) { x = w[i]; w[i] = w[j]; w[j] = x; y = t[i]; t[i] = t[j]; t[j] = y }
            for (k = 1; k <= n; k++) load[k] = 0
            for (i = 1; i <= m; i++) { b = 1; for (k = 2; k <= n; k++) if (load[k] < load[b]) b = k; load[b] += w[i]; print b "\t" t[i] }
        }'
}

# Records each test's duration from the shard logs for the next plan: the mean of the new time and the one before,
# so one slow run on a busy machine moves the plan only half way.
record_durations() {
    local tmp="$timings_file.new.$$"
    { [ -f "$timings_file" ] && sed 's/^/old	/' "$timings_file"
      cat "$logs"/ui-[0-9]*.log 2>/dev/null | sed -nE "s/^Test Case '-\[CassiniUITests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed) \(([0-9.]+) seconds\).*/new	\1\/\2	\4/p"
    } | awk -F'\t' '
        $1 == "old" { d[$2] = $3; next }
        { d[$2] = ($2 in d) ? sprintf("%.1f", (d[$2] + $3) / 2) : sprintf("%.1f", $3) }
        END { for (k in d) print k "\t" d[k] }' | sort > "$tmp"
    mv "$tmp" "$timings_file"
}

count_ran() { cat "$@" 2>/dev/null | grep -cE "^Test Case '-\[CassiniUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\]' (passed|failed|skipped)" || true; }

# The UI tests to run: every one, or those an -only-testing selection names (classes or methods). Other xcodebuild
# arguments (and -skip-testing) are passed through.
selected_ui_tests() {
    local all selection=() a
    all=$(ui_tests)
    for a in ${extra[@]+"${extra[@]}"}; do
        case "$a" in -only-testing:CassiniUITests/*) selection+=("${a#-only-testing:CassiniUITests/}") ;; esac
    done
    if [ ${#selection[@]} = 0 ]; then printf '%s\n' "$all"; return; fi
    for a in "${selection[@]}"; do
        case "$a" in */*) printf '%s\n' "$all" | grep -x -- "$a" || true ;; *) printf '%s\n' "$all" | grep -- "^$a/" || true ;; esac
    done | awk '!seen[$0]++'
}

tier_ui() {
    local tests; tests=$(selected_ui_tests)
    [ -n "$tests" ] || die "no UI test matches the selection"
    local count; count=$(printf '%s\n' "$tests" | wc -l | tr -d ' ')

    step_start "simulators"
    reap_idle_clones
    local workers="${CASSINI_UI_WORKERS:-$(auto_workers)}"
    [ "$workers" -gt "$count" ] && workers=$count
    # Booted iPhone clones this run does not use give their memory back.
    our_clones | while read -r udid state name; do
        case "$name" in "$prefix-iphone-"*) ;; *) continue ;; esac
        if [ "$state" = Booted ] && [ "${name##*-}" -gt "$workers" ]; then xcrun simctl shutdown "$udid" 2>/dev/null || true; fi
    done
    local plan; plan=$(printf '%s\n' "$tests" | plan_shards "$workers")
    local ipad_tests=""
    case "${CASSINI_UI_IPAD:-1}" in
        0) ;;
        all) ipad_tests=$tests ;;
        *) ipad_tests=$(printf '%s\n' "$tests" | grep '/testIPad' || true) ;;
    esac
    step_end

    # Each shard starts as soon as its clone is up; the iPad, booted for this run only, starts when it is.
    step_start "UI tests ($workers shard(s)$( [ -n "$ipad_tests" ] && echo ' + iPad'))"
    rm -f "$logs"/ui-*.log
    local pids=() k shard_args t
    wait_first_boot
    for k in $(seq 1 "$workers"); do
        shard_args=()
        while IFS= read -r t; do [ -n "$t" ] && shard_args+=("-only-testing:CassiniUITests/$t"); done \
            < <(printf '%s\n' "$plan" | awk -F'\t' -v k="$k" '$1 == k { print $2 }')
        [ ${#shard_args[@]} -gt 0 ] || continue
        ( udid=$(clone_udid "$prefix-iphone-$k" "$iphone_type")
          boot "$udid" || { echo "could not boot $prefix-iphone-$k" > "$logs/ui-$k.log"; exit 1; }
          test_on_retrying CassiniUITests "$logs/ui-$k.log" "$logs/ui-$k.xcresult" "$udid" "${shard_args[@]}" ) & pids+=("$!:$k")
    done
    local ipad=""
    if [ -n "$ipad_tests" ]; then
        ipad=$(clone_udid "$prefix-ipad-1" "$ipad_type")
        shard_args=()
        while IFS= read -r t; do shard_args+=("-only-testing:CassiniUITests/$t"); done <<< "$ipad_tests"
        ( boot "$ipad" || { echo "could not boot $prefix-ipad-1" > "$logs/ui-ipad.log"; exit 1; }
          test_on_retrying CassiniUITests "$logs/ui-ipad.log" "$logs/ui-ipad.xcresult" "$ipad" "${shard_args[@]}" ) & pids+=("$!:ipad")
    fi
    local failed="" p
    for p in "${pids[@]}"; do wait "${p%%:*}" || failed="$failed ${p##*:}"; done
    record_durations
    step_end

    # Every test ran exactly once on the iPhones: a shard that lost tests fails here too.
    local ran; ran=$(count_ran "$logs"/ui-[0-9].log)
    echo "UI tests: $ran of $count ran on iPhone$( [ -n "$ipad" ] && echo ", $(count_ran "$logs/ui-ipad.log") of $(printf '%s\n' "$ipad_tests" | wc -l | tr -d ' ') on iPad")"
    for p in $failed; do
        echo "shard $p failed (see $logs/ui-$p.log):" >&2
        grep -E "error:|failed \(|\*\* TEST|test.sh:|could not boot" "$logs/ui-$p.log" | tail -20 >&2
    done
    # The iPad runs only a few short tests; it is booted again next time rather than held in memory.
    [ -n "$ipad" ] && xcrun simctl shutdown "$ipad" 2>/dev/null || true
    [ -z "$failed" ] || return 1
    # -skip-testing leaves out tests the count includes.
    case " ${extra[*]-} " in *" -skip-testing"*) return 0 ;; esac
    [ "$ran" = "$count" ] || die "expected $count UI tests, $ran ran"
    if [ -n "$ipad" ]; then
        [ "$(count_ran "$logs/ui-ipad.log")" = "$(printf '%s\n' "$ipad_tests" | wc -l | tr -d ' ')" ] \
            || die "the iPad did not run all of its UI tests"
    fi
}

# ---------------------------------------------------------------- changed

# The files changed since the base: committed on this branch, staged, unstaged and untracked.
changed_files() {
    local base="$1"
    { git -C "$root" diff --name-only "$base" --
      git -C "$root" ls-files --others --exclude-standard; } | sort -u
}

# The UI test classes that cover each area of the app. A path not listed under Cassini/ runs every class.
ui_classes_for() {
    case "$1" in
        Cassini/Features/Library/*|Cassini/Features/Import/*) echo "LibraryUITests CassiniUITests NoteScreenTests TextLimitTests" ;;
        Cassini/Features/Note/*) echo "NoteScreenTests CassiniUITests ModelDownloadFlowTests SpeakerNamingFlowTests" ;;
        Cassini/Features/Recording/*) echo "CassiniUITests LibraryUITests TextLimitTests" ;;
        Cassini/Features/Settings/*) echo "SettingsFlowTests CassiniUITests ModelDownloadFlowTests SpeakerNamingFlowTests TextLimitTests" ;;
        Cassini/Features/Speakers/*) echo "SpeakerNamingFlowTests TextLimitTests CassiniUITests NoteScreenTests" ;;
        Cassini/Features/Trash/*) echo "CassiniUITests" ;;
        CassiniUITests/Waiting.swift) echo "ALL" ;;
        CassiniUITests/*.swift) ui_tests "$root/$1" 2>/dev/null | cut -d/ -f1 | sort -u | tr '\n' ' ' ;;
        Cassini/*|CassiniShared/*|CassiniActivity/*|project.yml) echo "ALL" ;;
    esac
}

# The swift test targets a change reaches, through the package's dependencies.
swift_targets_for() {
    case "$1" in
        Sources/CassiniCore/*|Sources/CZlib/*|Package.swift|Package.resolved) echo "ALL" ;;
        Tests/CassiniCoreTests/*) echo "CassiniCoreTests" ;;
        Packages/CassiniNotebook/Sources/*) echo "CassiniNotebookTests CassiniEngineTests CassiniInferenceTests" ;;
        Packages/CassiniEngine/Sources/*) echo "CassiniEngineTests CassiniInferenceTests" ;;
        Packages/CassiniInference/Sources/*) echo "CassiniInferenceTests" ;;
        Packages/CassiniAudio/Sources/*|Sources/COpusBridge/*) echo "CassiniAudioTests" ;;
        Packages/CassiniSherpa/Sources/*) echo "CassiniSherpaTests" ;;
        Packages/*/Tests/*) echo "$1" | cut -d/ -f4 ;;
    esac
}

tier_changed() {
    local base="${base_ref:-$(git -C "$root" merge-base HEAD main 2>/dev/null || echo HEAD)}"
    local files f swift="" ui="" hosted=0 strings=0
    files=$(changed_files "$base")
    echo "changes since $(git -C "$root" rev-parse --short "$base"): $(printf '%s\n' "$files" | grep -c . || true) file(s)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        swift="$swift $(swift_targets_for "$f")"
        ui="$ui $(ui_classes_for "$f")"
        case "$f" in Cassini/*|CassiniShared/*|CassiniTests/*|Packages/*/Sources/*|Sources/*|Package.*|project.yml) hosted=1 ;; esac
        case "$f" in Cassini/*.swift|CassiniShared/*.swift|CassiniActivity/*.swift|Cassini/Resources/Strings/*.xcstrings) strings=1 ;; esac
    done <<< "$files"
    swift=$(printf '%s\n' $swift | sort -u | xargs)
    ui=$(printf '%s\n' $ui | sort -u | xargs)
    echo "  swift test: ${swift:-nothing}"
    echo "  hosted tests: $( [ $hosted = 1 ] && echo yes || echo no)"
    echo "  UI test classes: ${ui:-none}"
    echo "  string catalogs: $( [ $strings = 1 ] && echo yes || echo no)"

    local filter=""
    case " $swift " in *" ALL "*) filter="" ;; *) filter=$(echo $swift | sed 's/ /|/g') ;; esac
    if [ -z "$swift" ] && [ $hosted = 0 ] && [ -z "$ui" ]; then echo "nothing to test"; return 0; fi
    if [ $hosted = 0 ] && [ -z "$ui" ]; then tier_fast "$filter"; return; fi
    start_first_boot
    [ $strings = 1 ] && check_strings
    [ -n "$swift" ] && start_fast_beside "$filter"
    build_for_testing
    [ $hosted = 1 ] && tier_app
    if [ -n "$ui" ]; then
        case " $ui " in *" ALL "*) ;; *)
            local c; for c in $ui; do extra+=("-only-testing:CassiniUITests/$c"); done ;;
        esac
        extra_xcodebuild_from_extra
        tier_ui
    fi
    wait_fast_beside
}

# xcodebuild gets the extra arguments without the UI selections, which the shards make themselves.
extra_xcodebuild_from_extra() {
    extra_xcodebuild=()
    local a
    for a in ${extra[@]+"${extra[@]}"}; do
        case "$a" in -only-testing:CassiniUITests/*) ;; *) extra_xcodebuild+=("$a") ;; esac
    done
}

case "$tier" in
    clean) delete_clones; echo "deleted the $prefix-* clones"; exit 0 ;;
    fast|app|ui|all|changed|build) ;;
    *) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

extra_xcodebuild_from_extra
trap summary EXIT
case "$tier" in
    fast) tier_fast ;;
    app)  start_first_boot; build_for_testing; tier_app ;;
    ui)   start_first_boot; build_for_testing; tier_ui ;;
    all)  start_first_boot; check_strings; start_fast_beside; build_for_testing; tier_app; tier_ui; wait_fast_beside ;;
    changed) tier_changed ;;
    build) build_for_testing ;;
esac
