#!/bin/bash
# Runs Cassini's tests in tiers and prints how long each step took.
#
#   scripts/test.sh fast    the string catalog check (scripts/check-strings.sh), then the Swift package tests (swift test)
#   scripts/test.sh app     build for testing, then the hosted unit tests (CassiniTests)
#   scripts/test.sh ui      build for testing, then the UI tests, sharded across simulator clones
#   scripts/test.sh all     fast, app and ui
#   scripts/test.sh clean   shut down and delete this worktree's simulator clones
#
# Extra arguments after the tier go to every xcodebuild test run, e.g.
#   scripts/test.sh ui -only-testing:CassiniUITests/NoteScreenTests
# (with -only-testing the UI tier runs exactly those tests on one clone).
#
# Environment:
#   CASSINI_UI_WORKERS   UI shards (default: as many as memory allows, at most 3)
#   CASSINI_UI_IPAD      what the iPad clone runs: the tests named testIPad* (default), all (every UI test, beside
#                        the iPhone shards; the longest step then) or 0 (nothing)
#   CASSINI_KEEP_SIMS=0  shut the clones down afterwards (default: keep them booted for the next run)
#   CASSINI_TEST_CACHE   shared cache directory (default: .test-cache beside the main checkout's .git)
#   CASSINI_IPHONE / CASSINI_IPAD  device types to clone (default "iPhone 17", "iPad Pro 13-inch (M5)")
#   CASSINI_SIM_PREFIX   clone name prefix (default ts-<worktree directory name>)
#
# Builds go to <worktree>/DerivedData, which persists between runs so later builds are incremental. Package checkouts
# are shared between worktrees under the cache, one directory per Package.resolved: Xcode's directly, SwiftPM's as a
# copy-on-write seed for a worktree without .build/. Logs and result bundles are in DerivedData/test-logs (the run
# before in DerivedData/test-logs.previous).
set -euo pipefail

tier="${1:-all}"; [ $# -gt 0 ] && shift
extra=("$@")

root="$(cd "$(dirname "$0")/.." && pwd)"
# A copy without .git (scripts/test-remote.sh) keeps its cache beside itself.
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$root/.git")"
cache="${CASSINI_TEST_CACHE:-$(dirname "$common")/.test-cache}"
derived="$root/DerivedData"
logs="$derived/test-logs"
prefix="${CASSINI_SIM_PREFIX:-ts-$(basename "$root")}"
iphone_type="${CASSINI_IPHONE:-iPhone 17}"
ipad_type="${CASSINI_IPAD:-iPad Pro 13-inch (M5)}"
keep_sims="${CASSINI_KEEP_SIMS:-1}"
mkdir -p "$cache" "$derived"
# The previous run's logs stay beside this run's.
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
    printf '\n%-34s %6s\n' "step" "time"
    printf '%s' "$timings"
    printf '%-34s %5ss\n' "total" "$(( $(date +%s) - started_all ))"
    if [ $rc -eq 0 ]; then echo "PASSED ($tier)"; else echo "FAILED ($tier), logs in $logs"; fi
    if [ "$keep_sims" = "0" ]; then shutdown_clones; fi
}

die() { echo "error: $*" >&2; exit 1; }

# A step's output goes to its log; on failure the tail is shown.
run_logged() {
    local log="$1"; shift
    if ! "$@" > "$log" 2>&1; then
        grep -E "error:|failed|FAILED|\*\* " "$log" | tail -40 >&2 || tail -40 "$log" >&2
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

# Boots a clone and waits until it can install apps; a booted one returns at once.
boot() {
    local udid="$1"
    xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 || xcrun simctl bootstatus "$udid" -b > /dev/null
}

our_clones() {
    xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
prefix = sys.argv[1] + "-"
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"].startswith(prefix): print(d["udid"], d["state"], d["name"])' "$prefix"
}

shutdown_clones() {
    our_clones | while read -r udid state _; do
        [ "$state" = "Booted" ] && xcrun simctl shutdown "$udid" 2>/dev/null || true
    done
}

delete_clones() {
    our_clones | while read -r udid _; do
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl delete "$udid"
    done
}

# Shards that fit in memory while leaving about 4 GB for everything else; each booted simulator with the app and its
# test runner takes about 1.5 GB. Clones of ours that are already booted count as available. At most 3: on 10 cores
# three shards already keep the CPU busy (simulator launches are CPU-bound), and a fourth made every test slower.
auto_workers() {
    local page free booted
    page=$(sysctl -n hw.pagesize)
    free=$(vm_stat | awk -v p="$page" '/Pages (free|inactive|speculative|purgeable)/ { gsub("\\.", "", $NF); n += $NF } END { print int(n * p / 1048576) }')
    booted=$(our_clones | grep -c Booted || true)
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
# cloned (APFS copy-on-write) with the paths moved over: SwiftPM otherwise fetches FluidAudio again, minutes over the
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

tier_fast() {
    step_start "string catalogs"
    run_logged "$logs/check-strings.log" "$root/scripts/check-strings.sh"
    step_end
    conformance_env
    seed_swiftpm
    step_start "swift test"
    run_logged "$logs/swift-test.log" swift test
    step_end
    save_swiftpm
    grep -E "^✔ Test run with|^✘ Test run with" "$logs/swift-test.log" || true
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
    (cd "$root" && run_logged "$logs/xcodegen.log" xcodegen generate --quiet)
    step_end

    step_start "resolve packages"
    # One resolve at a time per package set: worktrees share the checkouts.
    mkdir -p "$(packages_dir)"
    run_logged "$logs/resolve.log" /usr/bin/lockf "$(packages_dir).lock" \
        xcodebuild -resolvePackageDependencies -project "$root/Cassini.xcodeproj" -scheme Cassini \
        -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$(packages_dir)" -onlyUsePackageVersionsFromResolvedFile
    step_end

    step_start "build for testing"
    run_logged "$logs/build.log" xcodebuild build-for-testing "${flags[@]}" \
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

# xcodebuild test-without-building of one test target on one simulator; $1 target, $2 log, $3 result bundle,
# $4 udid, the rest test arguments.
test_on() {
    local target="$1" log="$2" bundle="$3" udid="$4" app; shift 4
    rm -rf "$bundle"
    # xcodebuild replaces an installed app while it starts the tests, and a launch that meets the replacement fails
    # or hangs. Without an installed app (or a left-over Live Activity of it) there is nothing to replace.
    for app in app.codemyriad.cassini app.codemyriad.CassiniUITests.xctrunner; do
        xcrun simctl terminate "$udid" "$app" > /dev/null 2>&1 || true
        xcrun simctl uninstall "$udid" "$app" > /dev/null 2>&1 || true
    done
    xcodebuild test-without-building -xctestrun "${xctestrun%.xctestrun}.only-$target.xctestrun" \
        -destination "platform=iOS Simulator,id=$udid" \
        -resultBundlePath "$bundle" -collect-test-diagnostics never -parallel-testing-enabled NO \
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 \
        "$@" ${extra[@]+"${extra[@]}"} > "$log" 2>&1
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
    test_on CassiniTests "$logs/hosted.log" "$logs/hosted.xcresult" "$first_iphone" -only-testing:CassiniTests || rc=$?
    # xcodebuild installs the host app while it starts it; when that launch fails before any test ran, once more.
    if [ $rc != 0 ] && grep -q "failed to launch app.codemyriad.cassini" "$logs/hosted.log" \
        && ! grep -q "^Test Case " "$logs/hosted.log"; then
        echo "the host app did not launch; trying once more"
        mv "$logs/hosted.log" "$logs/hosted-launch-failed.log"
        rc=0
        test_on CassiniTests "$logs/hosted.log" "$logs/hosted.xcresult" "$first_iphone" -only-testing:CassiniTests || rc=$?
    fi
    if [ $rc != 0 ]; then
        grep -E "error:|failed \(|\*\* TEST" "$logs/hosted.log" | tail -20 >&2; echo "see $logs/hosted.log" >&2
        step_end; return 1
    fi
    step_end
    grep -E "Executed [0-9]+ tests" "$logs/hosted.log" | tail -1 || true
}

# The UI test methods, as Class/method, read from the sources (one class per file is not assumed).
ui_tests() {
    awk '
        /^(final )?class [A-Za-z0-9_]+: XCTestCase/ { match($0, /class [A-Za-z0-9_]+/); cls = substr($0, RSTART + 6, RLENGTH - 6) }
        cls != "" && /func test[A-Za-z0-9_]*\(/ { match($0, /func test[A-Za-z0-9_]*/); print cls "/" substr($0, RSTART + 5, RLENGTH - 5) }
    ' "$root"/CassiniUITests/*.swift
}

# Shared between worktrees, so a fresh worktree balances its first run too.
timings_file="$cache/ui-test-durations.tsv"

# Splits the tests into $1 shards, longest first onto the least loaded shard, using the durations of the last run
# (20 s for a test without one). Prints "shard<TAB>test".
plan_shards() {
    local n="$1"
    ui_tests | awk -v n="$n" -v f="$timings_file" '
        BEGIN { while ((getline line < f) > 0) { split(line, p, "\t"); d[p[1]] = p[2] } }
        { t[NR] = $0; w[NR] = ($0 in d) ? d[$0] : 20 }
        END {
            for (i = 1; i <= NR; i++) for (j = i + 1; j <= NR; j++) if (w[j] > w[i]) { x = w[i]; w[i] = w[j]; w[j] = x; y = t[i]; t[i] = t[j]; t[j] = y }
            for (k = 1; k <= n; k++) load[k] = 0
            for (i = 1; i <= NR; i++) { b = 1; for (k = 2; k <= n; k++) if (load[k] < load[b]) b = k; load[b] += w[i]; print b "\t" t[i] }
        }'
}

# Records each test's duration from the shard logs for the next plan.
record_durations() {
    local tmp="$timings_file.new"
    { [ -f "$timings_file" ] && cat "$timings_file"
      cat "$logs"/ui-[0-9]*.log 2>/dev/null | sed -nE "s/^Test Case '-\[CassiniUITests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\).*/\1\/\2	\4/p"
    } | awk -F'\t' '{ d[$1] = $2 } END { for (k in d) print k "\t" d[k] }' | sort > "$tmp"
    mv "$tmp" "$timings_file"
}

tier_ui() {
    local only=0 a
    for a in ${extra[@]+"${extra[@]}"}; do case "$a" in -only-testing*|-skip-testing*) only=1 ;; esac; done

    if [ $only = 1 ]; then
        step_start "UI tests (selected)"
        wait_first_boot
        local rc=0
        test_on CassiniUITests "$logs/ui-1.log" "$logs/ui-1.xcresult" "$first_iphone" || rc=$?
        record_durations; step_end
        [ $rc = 0 ] || { grep -E "error:|failed \(|\*\* TEST" "$logs/ui-1.log" | tail -20 >&2; return 1; }
        return 0
    fi

    local workers="${CASSINI_UI_WORKERS:-$(auto_workers)}"
    # Booted iPhone clones this run does not use give their memory back.
    our_clones | while read -r udid state name; do
        case "$name" in "$prefix-iphone-"*) ;; *) continue ;; esac
        if [ "$state" = Booted ] && [ "${name##*-}" -gt "$workers" ]; then xcrun simctl shutdown "$udid" 2>/dev/null || true; fi
    done
    local plan; plan=$(plan_shards "$workers")
    local ipad_tests
    case "${CASSINI_UI_IPAD:-1}" in
        all) ipad_tests=$(ui_tests) ;;
        *) ipad_tests=$(ui_tests | grep '/testIPad' || true) ;;
    esac

    step_start "boot $workers iPhone clone(s)$( [ "${CASSINI_UI_IPAD:-1}" != 0 ] && [ -n "$ipad_tests" ] && echo ' + iPad')"
    local udids=() pids=() k
    wait_first_boot
    udids[1]="$first_iphone"
    for k in $(seq 2 "$workers"); do
        udids[$k]=$(clone_udid "$prefix-iphone-$k" "$iphone_type")
        boot "${udids[$k]}" & pids+=($!)
    done
    local ipad=""
    if [ "${CASSINI_UI_IPAD:-1}" != 0 ] && [ -n "$ipad_tests" ]; then
        ipad=$(clone_udid "$prefix-ipad-1" "$ipad_type")
        boot "$ipad" & pids+=($!)
    fi
    for k in ${pids[@]+"${pids[@]}"}; do wait "$k" || die "a simulator clone did not boot"; done
    step_end

    step_start "UI tests ($workers shard(s))"
    rm -f "$logs"/ui-*.log
    pids=()
    local shard_args
    for k in $(seq 1 "$workers"); do
        shard_args=()
        while IFS= read -r t; do [ -n "$t" ] && shard_args+=("-only-testing:CassiniUITests/$t"); done \
            < <(printf '%s\n' "$plan" | awk -F'\t' -v k="$k" '$1 == k { print $2 }')
        [ ${#shard_args[@]} -gt 0 ] || continue
        test_on CassiniUITests "$logs/ui-$k.log" "$logs/ui-$k.xcresult" "${udids[$k]}" "${shard_args[@]}" & pids+=("$!:$k")
    done
    if [ -n "$ipad" ]; then
        shard_args=()
        while IFS= read -r t; do shard_args+=("-only-testing:CassiniUITests/$t"); done <<< "$ipad_tests"
        test_on CassiniUITests "$logs/ui-ipad.log" "$logs/ui-ipad.xcresult" "$ipad" "${shard_args[@]}" & pids+=("$!:ipad")
    fi
    local failed="" p
    for p in "${pids[@]}"; do wait "${p%%:*}" || failed="$failed ${p##*:}"; done
    record_durations
    step_end

    # Every test ran exactly once on the iPhones: a shard that lost tests fails here too.
    local expected ran
    expected=$(ui_tests | wc -l | tr -d ' ')
    ran=$(cat "$logs"/ui-[0-9]*.log | grep -cE "^Test Case '-\[CassiniUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\]' (passed|failed|skipped)" || true)
    echo "UI tests: $ran of $expected ran on iPhone$( [ -n "$ipad" ] && echo ", $(echo "$ipad_tests" | wc -l | tr -d ' ') on iPad")"
    for p in $failed; do
        echo "shard $p failed (see $logs/ui-$p.log):" >&2
        grep -E "error:|failed \(|\*\* TEST" "$logs/ui-$p.log" | tail -20 >&2
    done
    # The iPad runs only a few short tests; it is booted again next time rather than held in memory.
    [ -n "$ipad" ] && xcrun simctl shutdown "$ipad" 2>/dev/null || true
    [ -z "$failed" ] || return 1
    [ "$ran" = "$expected" ] || die "expected $expected UI tests, $ran ran"
    if [ -n "$ipad" ]; then
        ran=$(grep -cE "^Test Case '-\[CassiniUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\]' (passed|failed|skipped)" "$logs/ui-ipad.log" || true)
        expected=$(echo "$ipad_tests" | wc -l | tr -d ' ')
        [ "$ran" = "$expected" ] || die "expected $expected UI tests on the iPad, $ran ran"
    fi
}

case "$tier" in
    clean) delete_clones; echo "deleted the $prefix-* clones"; exit 0 ;;
    fast|app|ui|all) ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

trap summary EXIT
case "$tier" in
    fast) tier_fast ;;
    app)  start_first_boot; build_for_testing; tier_app ;;
    ui)   start_first_boot; build_for_testing; tier_ui ;;
    all)  start_first_boot; tier_fast; build_for_testing; tier_app; tier_ui ;;
esac
