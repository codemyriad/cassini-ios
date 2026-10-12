#!/bin/bash
# Runs Cassini's tests in tiers and prints how long each step took.
#
#   scripts/test.sh fast    Swift package tests (swift test)
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
#   CASSINI_UI_IPAD=0    skip the iPad shard (the tests named testIPad*)
#   CASSINI_KEEP_SIMS=0  shut the clones down afterwards (default: keep them booted for the next run)
#   CASSINI_TEST_CACHE   shared cache directory (default: .test-cache beside the main checkout's .git)
#   CASSINI_IPHONE / CASSINI_IPAD  device types to clone (default "iPhone 17", "iPad Pro 13-inch (M5)")
#   CASSINI_SIM_PREFIX   clone name prefix (default ts-<worktree directory name>)
#
# Builds go to <worktree>/DerivedData, which persists between runs so later builds are incremental. Package checkouts
# are shared between worktrees under the cache, one directory per Package.resolved.
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
mkdir -p "$cache" "$logs"

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
    # The capture test records when the Mac has an input; granted up front, no permission alert races its taps.
    xcrun simctl privacy "$udid" grant microphone app.codemyriad.cassini 2>/dev/null || true
}

our_clones() {
    xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
prefix = sys.argv[1] + "-"
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"].startswith(prefix): print(d["udid"], d["state"])' "$prefix"
}

shutdown_clones() {
    our_clones | while read -r udid state; do
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

tier_fast() {
    conformance_env
    step_start "swift test"
    run_logged "$logs/swift-test.log" swift test
    step_end
    grep -E "^✔ Test run with|^✘ Test run with" "$logs/swift-test.log" || true
}

packages_dir() {
    local key
    key=$(cat "$root/Package.resolved" "$root/Package.swift" | shasum | cut -c1-12)
    echo "$cache/SourcePackages-$key"
}

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
    xctestrun=$(ls -t "$derived"/Build/Products/Cassini_*.xctestrun 2>/dev/null | head -1)
    [ -n "$xctestrun" ] || die "no .xctestrun in $derived/Build/Products"
}

# xcodebuild test-without-building on one simulator; $1 log, $2 result bundle, $3 udid, the rest test arguments.
test_on() {
    local log="$1" bundle="$2" udid="$3"; shift 3
    rm -rf "$bundle"
    xcodebuild test-without-building -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$udid" \
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
    if ! test_on "$logs/hosted.log" "$logs/hosted.xcresult" "$first_iphone" -only-testing:CassiniTests; then
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
      cat "$logs"/ui-*.log 2>/dev/null | sed -nE "s/^Test Case '-\[CassiniUITests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\).*/\1\/\2	\4/p"
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
        test_on "$logs/ui-1.log" "$logs/ui-1.xcresult" "$first_iphone" || rc=$?
        record_durations; step_end
        [ $rc = 0 ] || { grep -E "error:|failed \(|\*\* TEST" "$logs/ui-1.log" | tail -20 >&2; return 1; }
        return 0
    fi

    local workers="${CASSINI_UI_WORKERS:-$(auto_workers)}"
    local plan; plan=$(plan_shards "$workers")
    local ipad_tests; ipad_tests=$(ui_tests | grep '/testIPad' || true)

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
        test_on "$logs/ui-$k.log" "$logs/ui-$k.xcresult" "${udids[$k]}" "${shard_args[@]}" & pids+=("$!:$k")
    done
    if [ -n "$ipad" ]; then
        shard_args=()
        while IFS= read -r t; do shard_args+=("-only-testing:CassiniUITests/$t"); done <<< "$ipad_tests"
        test_on "$logs/ui-ipad.log" "$logs/ui-ipad.xcresult" "$ipad" "${shard_args[@]}" & pids+=("$!:ipad")
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
