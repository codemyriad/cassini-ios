#!/bin/bash
# Runs Cassini's tests in tiers and prints how long each step took.
#
#   scripts/test.sh fast     the string catalog check (scripts/check-strings.sh), then the Swift package tests
#   scripts/test.sh app      build for testing, then the hosted unit tests (CassiniTests)
#   scripts/test.sh ui       build for testing, then the UI tests, sharded across simulator clones
#   scripts/test.sh all      fast, app and ui (the package tests run beside the build), then the iOS 18 leg when it is on
#                            (CASSINI_IOS18)
#   scripts/test.sh ios18    build for testing, then only the iOS 18 leg (default smoke; CASSINI_IOS18=full for the full
#                            leg). For iterating on it; an -only-testing:CassiniUITests/... selection replaces the smoke list
#   scripts/test.sh prebuilt the hosted and UI tests of the last build, without building (what the iOS 18 leg runs on its
#                            runtime: CASSINI_RUNTIME=18 scripts/test.sh prebuilt)
#   scripts/test.sh changed [base]
#                            only what the changes since base touch (default: where the branch left origin/main, plus
#                            uncommitted and untracked files): the string catalog check when a source or a catalog
#                            changed, the package test targets, the hosted tests and the UI test classes of the
#                            changed areas. For iterating; run all once before finishing.
#   scripts/test.sh build    only build for testing, then check that no embedded binary needs a newer iOS than the app
#                            (scripts/check-embedded-minos.py); scripts/screenshots.sh runs its tests from that build
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
#   CASSINI_KEEP_SIMS    0 shuts the clones down after a run that took the host lock, 1 keeps the iPhones booted for
#                        the next run (default: 0 after all, 1 after the other tiers)
#   CASSINI_CONFORMANCE_REQUIRED  1 (the default for all) fails, rather than skips, missing conformance vectors
#   CASSINI_IDLE_MINUTES booted clones of other worktrees that no xcodebuild has used for this long are shut down,
#                        never deleted (default 15)
#   CASSINI_TEST_CACHE   shared cache directory (default: .test-cache beside the main checkout's .git)
#   CASSINI_IPHONE / CASSINI_IPAD  device types to clone (default "iPhone 17", "iPad Pro 13-inch (M5)"; on a
#                        CASSINI_RUNTIME below 26, "iPhone 16", "iPad Pro 13-inch (M4)")
#   CASSINI_RUNTIME      the iOS simulator runtime of app, ui, all and changed (default: the newest): a version prefix
#                        (18, 18.2) picks the newest available runtime it matches, an identifier
#                        (com.apple.CoreSimulator.SimRuntime.iOS-18-2) that one. The run fails when none matches or a
#                        device type cannot run on it. Its clones (<prefix>-iphone18-N, <prefix>-ipad18-1), logs
#                        (DerivedData/test-logs-ios18) and timing table (ui-test-durations-ios18.tsv in the cache) are
#                        its own. It shuts down this worktree's other booted clones before it boots, and all of them
#                        afterwards (CASSINI_KEEP_SIMS default 0), and it posts no commit status.
#   CASSINI_IOS18        the iOS 18 leg of all: after the default runtime's tiers pass, this worktree's clones are shut
#                        down and the products of the same build run on the iOS 18 runtime, through `prebuilt` with
#                        CASSINI_RUNTIME=18 (its clones, logs and timing table, above). smoke: the hosted tests, then the
#                        UI tests listed in scripts/ios18-smoke-tests.txt on one iPhone; full: the hosted tests, every
#                        UI test on the iPhones and the testIPad* tests on the iPad; 0: no leg, and no commit status.
#                        Unset, all runs ios18_default below: smoke, or full when the branch changes views
#                        (Cassini/Features, Cassini/Design since it left origin/main); with ios18_default=off there
#                        is no leg and the status says nothing of iOS 18. With the leg on, a Mac
#                        without the runtime fails the run, and its status, before anything is built; it never skips it.
#   CASSINI_IOS18_RUNTIME  the runtime of that leg, as CASSINI_RUNTIME takes it (default 18; 26 runs the whole leg on an
#                        installed iOS 26 runtime, with the iOS 18 facts given to every UI test's launch). Set, the run
#                        posts no commit status
#   CASSINI_SIM_PREFIX   clone name prefix (default ts-<worktree directory name>)
#   CASSINI_HEAVY_LOCK   the host-wide lock file (default ~/.cassini-heavy.lock); CASSINI_LOCK_MINUTES how long to
#                        wait for it (default 60); CASSINI_ADMIT_MINUTES how long to wait for the host to calm down
#                        before booting the UI clones (default 10, 0 not at all)
#   CASSINI_POST_STATUS=1  post the result of `all` as the commit status drmeyers/test-all of HEAD on GitHub (gh):
#                        pending at the start, then success or failure. Only a full run of a clean, pushed HEAD
#                        posts: no extra arguments, the iPad's tests, the release runtime, the default simulator
#                        runtime (no CASSINI_RUNTIME), the iOS 18 leg not turned off (CASSINI_IOS18=0) nor moved
#                        (CASSINI_IOS18_RUNTIME), nothing uncommitted. The description gives the counts, with the
#                        leg's and its mode when it ran: "passed in 24 min: iPhone 72/72, iPad 8/8; iOS 18.2 smoke:
#                        hosted 76/76 (6 skipped), iPhone 16/16".
#
# One heavy run at a time per host: every tier but fast and clean takes the host-wide lock before it boots or builds
# anything, and waits while another run (of any worktree) holds it; the lock file names the holder. Before the UI
# clones boot, the run also waits until the CPU and free memory leave room for them, failing closed at its deadline.
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
# CASSINI_RUNTIME's tag (18, 18.2; an identifier's version) names the second leg's clones, leases, logs and timing
# table, so that leg never reuses or wipes the default one's. Without CASSINI_RUNTIME it is empty and every name is
# what it always was. Only the tiers that boot clones read it: fast, build and clean ignore it.
runtime_tag_of() {
    case "$1" in
        com.apple.CoreSimulator.SimRuntime.iOS-*) printf '%s' "${1#com.apple.CoreSimulator.SimRuntime.iOS-}" | tr - . ;;
        *) printf '%s' "$1" ;;
    esac
}
runtime_tag=""
case "$tier" in app|ui|all|changed|prebuilt)
    if [ -n "${CASSINI_RUNTIME:-}" ]; then
        runtime_tag=$(runtime_tag_of "$CASSINI_RUNTIME")
        # Checked on the value, not on the tag: an identifier without a version (…SimRuntime.iOS-) strips to an empty
        # tag, which would otherwise read as no CASSINI_RUNTIME, run on the newest runtime and post a status.
        if ! [[ $runtime_tag =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo "error: CASSINI_RUNTIME=$CASSINI_RUNTIME is neither a version (18, 18.2) nor an iOS runtime identifier" >&2
            exit 2
        fi
    fi ;;
esac

# The iOS 18 leg of `all` when CASSINI_IOS18 is not set: smoke (full when the branch changes views, ios18_preflight),
# since the app's minimum is iOS 18 and the gate's Macs have the iOS 18 simulator runtime. `off` here is the one-line
# switch back (README, "The iOS 18 leg").
ios18_default=smoke
# The one runtime value the leg runs on; the script's own tests run it on an installed iOS 26 runtime instead.
ios18_runtime="${CASSINI_IOS18_RUNTIME:-18}"
ios18_tag=$(runtime_tag_of "$ios18_runtime")
ios18_smoke_list="$root/scripts/ios18-smoke-tests.txt"
case "${CASSINI_IOS18-unset}" in unset|smoke|full|0) ;; *)
    echo "error: CASSINI_IOS18=$CASSINI_IOS18 is none of smoke, full and 0" >&2; exit 2 ;;
esac
ios18_mode=off ios18_by_default=0
case "$tier" in
    # A whole `all` on another runtime (CASSINI_RUNTIME) has no second leg.
    all) [ -n "$runtime_tag" ] || ios18_mode="${CASSINI_IOS18:-$ios18_default}"
        [ -n "${CASSINI_IOS18:-}" ] || ios18_by_default=1 ;;
    ios18) ios18_mode="${CASSINI_IOS18:-smoke}"
        [ "$ios18_mode" != 0 ] || { echo "error: CASSINI_IOS18=0 leaves the ios18 tier nothing to run" >&2; exit 2; } ;;
esac
[ "$ios18_mode" != 0 ] || ios18_mode=off
if [ "$ios18_mode" != off ] && ! [[ $ios18_tag =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: CASSINI_IOS18_RUNTIME=$ios18_runtime is neither a version (18, 18.2) nor an iOS runtime identifier" >&2
    exit 2
fi
logs="$derived/test-logs${runtime_tag:+-ios$runtime_tag}"
prefix="${CASSINI_SIM_PREFIX:-ts-$(basename "$root")}"
iphone_type="${CASSINI_IPHONE:-iPhone 17}"
ipad_type="${CASSINI_IPAD:-iPad Pro 13-inch (M5)}"
# After the whole gate the clones go (Mac and Android work on this host never reclaims their memory); after the
# iterating tiers the iPhones stay booted for the next run, unless they are another runtime's, which the next run
# would not use.
keep_sims="${CASSINI_KEEP_SIMS:-$( { [ "$tier" = all ] || [ "$tier" = ios18 ] || [ -n "$runtime_tag" ]; } && echo 0 || echo 1 )}"
# The whole gate fails, rather than skips, the format's conformance vectors when it cannot find them.
[ "$tier" != all ] || export CASSINI_CONFORMANCE_REQUIRED="${CASSINI_CONFORMANCE_REQUIRED:-1}"
idle_minutes="${CASSINI_IDLE_MINUTES:-15}"
leases="$cache/sim-leases"
# A CASSINI_RUNTIME clone's lease lives one level down. A copy of this script from before CASSINI_RUNTIME does not
# know its name, and deletes a shut-down clone it cannot place only when it finds that clone's lease in $leases
# itself; it skips directories when it tidies the leases. So an older copy in another worktree leaves these clones
# alone.
lease_dir="$leases${runtime_tag:+/runtime}"

# Spotlight indexes a build folder in an indexed location; it skips a directory whose name ends in .noindex (and
# ignores .metadata_never_index there). An older DerivedData moves over once, and the old name links to the new one.
if [ -d "$root/DerivedData" ] && [ ! -L "$root/DerivedData" ] && [ ! -e "$derived" ]; then
    mv "$root/DerivedData" "$derived"
fi
mkdir -p "$cache" "$derived" "$leases"
[ -z "$runtime_tag" ] || mkdir -p "$lease_dir"
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
    # A run stopped by a signal ends its own xcodebuild and shards before it lets go of the host lock.
    [ -z "$lock_pid" ] || end_own_processes
    printf '\n%-34s %6s\n' "step" "time"
    printf '%s' "$timings"
    printf '%-34s %5ss\n' "total" "$(( $(date +%s) - started_all ))"
    if [ $rc -eq 0 ]; then echo "PASSED ($tier)"; else
        echo "$tier exit $rc" > "$logs/FAILED"
        echo "FAILED ($tier), logs in $logs (kept in $failed_logs after the next run)"
    fi
    # A run on another runtime leaves what it ran for the iOS 18 leg's status: "iOS 18.2 hosted 76/76, iPhone 17/17".
    if [ -n "$runtime_tag" ]; then
        if [ -n "$runtime_version" ]; then
            echo "iOS $runtime_version${hosted_counts:+ hosted $hosted_counts}${ui_counts:+, $ui_counts}"
        else
            echo "no iOS $runtime_tag runtime"
        fi > "$logs/leg-counts"
    fi
    # Only a run that got as far as the host lock shuts the clones down. One that stopped before (a missing runtime,
    # a package-only `changed`, a lock it did not get) booted nothing, and its shutdown would hit the clones another
    # run of this worktree is testing on, or the iPhones kept booted for the next run.
    if [ "$keep_sims" = "0" ] && [ "$heavy_started" = 1 ]; then shutdown_clones; fi
    post_status "$rc"
    release_heavy_lock
}

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- the commit status

# The coordinator merges on the PR's checks, and cassini-ios has no hosted CI: the gate on drmeyers records its
# result on the commit it tested, so a merge has an objective check (D66, ios-9). A run that tested less than the
# whole gate, or something other than the commit (uncommitted files, a HEAD that moved), posts nothing and says why.
status_context="drmeyers/test-all"
status_sha="" status_why="" ui_counts="" hosted_counts="" leg_counts=""
status_skip_reason() {
    [ "$tier" = all ] || { echo "the tier is $tier, not all"; return; }
    [ ${#extra[@]} -eq 0 ] || { echo "extra arguments (${extra[*]})"; return; }
    case "${CASSINI_UI_IPAD:-1}" in 1) ;; *) echo "CASSINI_UI_IPAD=$CASSINI_UI_IPAD"; return ;; esac
    [ "${CASSINI_IOS18:-}" != 0 ] || { echo "CASSINI_IOS18=0 (no iOS 18 leg)"; return; }
    [ -z "${CASSINI_IOS18_RUNTIME:-}" ] || { echo "CASSINI_IOS18_RUNTIME is set (not the iOS 18 runtime)"; return; }
    [ -z "${CASSINI_SHERPA_LOCAL:-}" ] || { echo "CASSINI_SHERPA_LOCAL is set (not the release runtime)"; return; }
    [ -z "$runtime_tag" ] || { echo "CASSINI_RUNTIME is set (not the default simulator runtime)"; return; }
    git -C "$root" rev-parse -q --verify HEAD > /dev/null 2>&1 || { echo "not a git checkout"; return; }
    [ -z "$(git -C "$root" status --porcelain)" ] || { echo "uncommitted changes"; return; }
    command -v gh > /dev/null || { echo "gh is not installed"; return; }
}
github_repo() { git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##'; }
send_status() {
    local state="$1" description="$2"
    run_limited "$logs/commit-status.log" 60 gh api -X POST "repos/$(github_repo)/statuses/$status_sha" \
        -f state="$state" -f context="$status_context" -f description="${description:0:140}"
}
start_status() {
    [ "${CASSINI_POST_STATUS:-}" = 1 ] || return 0
    status_why=$(status_skip_reason)
    if [ -n "$status_why" ]; then echo "no commit status: $status_why"; return 0; fi
    status_sha=$(git -C "$root" rev-parse HEAD)
    if ! send_status pending "running scripts/test.sh all on drmeyers"; then
        status_why="GitHub refused it (is ${status_sha:0:7} pushed? see $logs/commit-status.log)"
        echo "no commit status: $status_why"; status_sha=""
    fi
}
post_status() {
    local rc="$1" state description counts="$ui_counts"
    [ -n "$status_sha" ] || return 0
    [ -z "$leg_counts" ] || counts="${counts:+$counts; }$leg_counts"
    if [ "$(git -C "$root" rev-parse HEAD)" != "$status_sha" ] || [ -n "$(git -C "$root" status --porcelain)" ]; then
        state=error description="the checkout changed during the run; run the gate again"
    elif [ "$rc" -eq 0 ]; then
        state=success description="passed in $(( ($(date +%s) - started_all + 59) / 60 )) min${counts:+: $counts}"
    elif [ "$rc" -ge 128 ]; then
        state=error description="stopped (exit $rc)"
    else
        state=failure description="failed (exit $rc)${counts:+: $counts}"
    fi
    if send_status "$state" "$description"; then echo "commit status $status_context: $state on ${status_sha:0:7}"
    else echo "commit status not posted, see $logs/commit-status.log"; fi
}

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
    /usr/bin/python3 -I "$root/scripts/test-events.py" watch "$pid" /dev/null 5 5 || true
    # shellcheck disable=SC2086
    signal_all KILL $pids
    wait "$pid" 2>/dev/null || true
}

# Runs the command after $2 with its output in $1, ending it once it has run $2 seconds: a step that hangs fails the
# run instead of holding it (once xcodebuild -resolvePackageDependencies deadlocked and held a run for two hours).
# Returns the command's status, or 124 when it was ended.
run_limited() {
    local log="$1" limit="$2" pid rc; shift 2
    : > "$log"
    "$@" >> "$log" 2>&1 & pid=$!
    if /usr/bin/python3 -I "$root/scripts/test-events.py" watch "$pid" "$log" "$limit" "$limit"; then
        wait "$pid"
    else
        rc=$?
        echo "test.sh: still running after ${limit}s; ended" >> "$log"
        end_tree "$pid"
        return "$rc"
    fi
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

# ---------------------------------------------------------------- the host

# Builds, simulators and UI tests of two runs at once (other worktrees, or the Mac and Android work on the same Mac)
# made every test 2-4x slower and turned tight waits into false failures. The lock is an flock on $heavy_lock, held
# by a small helper process rather than by this shell, so no daemon that xcodebuild or swift leaves running inherits
# it; the helper lets go once this script has ended its own processes (summary), or at once if the script is killed
# outright. The other heavy scripts (screenshots.sh, sherpa-bench.sh, speaker-smoke.sh) hold it through
# `/usr/bin/lockf -k`, which another tool can use too, and set CASSINI_HEAVY_LOCK_HELD=1 so that the test.sh they call
# does not wait for their own lock.
heavy_lock="${CASSINI_HEAVY_LOCK:-$HOME/.cassini-heavy.lock}"
lock_minutes="${CASSINI_LOCK_MINUTES:-60}"
lock_pid="" lock_held_file="" heavy_started=0
take_heavy_lock() {
    [ -z "$lock_pid" ] || return 0
    [ "${CASSINI_HEAVY_LOCK_HELD:-}" != 1 ] || return 0
    local note rc
    # Named for this run: two runs of one worktree must not take each other's lock for their own.
    lock_held_file="${TMPDIR:-/tmp}/cassini-heavy-lock-held.$$"
    rm -f "$lock_held_file"
    note="$(basename "$root") (test.sh $tier, pid $$, since $(date '+%Y-%m-%d %H:%M:%S'))"
    /usr/bin/python3 -I "$root/scripts/test-events.py" hold "$heavy_lock" "$$" "$lock_held_file" "$note" \
        < /dev/null & lock_pid=$!
    if /usr/bin/python3 -I "$root/scripts/test-events.py" lock-ready \
        "$lock_pid" "$heavy_lock" "$lock_held_file" "$(( lock_minutes * 60 ))" --note "$note"; then
        return 0
    else
        rc=$?
        release_heavy_lock
        [ "$rc" != 124 ] || die "host busy: could not take $heavy_lock within $lock_minutes min"
        die "could not take the host lock $heavy_lock"
    fi
}
release_heavy_lock() {
    [ -n "$lock_pid" ] || return 0
    kill "$lock_pid" 2>/dev/null || true; wait "$lock_pid" 2>/dev/null || true; lock_pid=""
    rm -f "$lock_held_file"
}

# Ends whatever this script still runs (a stopped run's xcodebuild, a shard), except the lock's helper, so the lock
# is not handed on while they go on.
end_own_processes() {
    local children child
    children=$(pgrep -P $$ || true)
    for child in $children; do [ "$child" = "${lock_pid:-}" ] || end_tree "$child"; done
}

# ---------------------------------------------------------------- simulators

runtime="" runtime_version=""
runtime_id() {
    [ -z "$runtime" ] || { echo "$runtime"; return; }
    xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])'
}

# The runtime $1 names ($4 is the variable that gave it): the newest available iOS runtime whose version is the value or starts with it and a dot, or
# whose identifier it is; and the device types for it, $2 and $3 or by default those it can run (iPhone 17 and the M5
# iPad Pro need 26). Prints "identifier<TAB>version<TAB>iPhone<TAB>iPad", or why there is none and fails: it never falls
# back to another runtime. select_runtime takes CASSINI_RUNTIME's; ios18_preflight checks the iOS 18 leg's.
pick_runtime() {
    xcrun simctl list runtimes -j | /usr/bin/python3 -I -c '
import json, sys
wanted, iphone, ipad, name = sys.argv[1:5]
key = lambda r: [int(x) for x in r["version"].split(".")]
rs = sorted((r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]), key=key)
if wanted.startswith("com.apple."):
    match = [r for r in rs if r["identifier"] == wanted]
else:
    match = [r for r in rs if r["version"] == wanted or r["version"].startswith(wanted + ".")]
if not match:
    print("no available iOS simulator runtime matches %s=%s (available: %s)"
          % (name, wanted, ", ".join(r["version"] for r in rs) or "none"))
    sys.exit(3)
r = match[-1]
recent = key(r)[0] >= 26
iphone = iphone or ("iPhone 17" if recent else "iPhone 16")
ipad = ipad or ("iPad Pro 13-inch (M5)" if recent else "iPad Pro 13-inch (M4)")
if "supportedDeviceTypes" in r:
    supported = {d[k] for d in r["supportedDeviceTypes"] for k in ("name", "identifier") if k in d}
    for kind, name in (("CASSINI_IPHONE", iphone), ("CASSINI_IPAD", ipad)):
        if name not in supported:
            print("iOS %s cannot run the device type \"%s\" (set %s)" % (r["version"], name, kind))
            sys.exit(3)
print("\t".join((r["identifier"], r["version"], iphone, ipad)))' "$@"
}
select_runtime() {
    [ -n "$runtime_tag" ] || return 0
    local picked
    picked=$(pick_runtime "$CASSINI_RUNTIME" "${CASSINI_IPHONE:-}" "${CASSINI_IPAD:-}" CASSINI_RUNTIME) \
        || die "${picked:-could not list the simulator runtimes}"
    IFS=$'\t' read -r runtime runtime_version iphone_type ipad_type <<< "$picked"
    echo "runtime: iOS $runtime_version ($runtime); clones $prefix-iphone$runtime_tag-N ($iphone_type)," \
        "$prefix-ipad$runtime_tag-1 ($ipad_type)"
}

# The UDID of the clone called $1, created from device type $2 when missing. On a CASSINI_RUNTIME only a clone of that
# runtime counts: one of the same name on another (CASSINI_RUNTIME=18 picked 18.0 before, 18.2 now) is this
# worktree's own and is deleted rather than reused.
clone_udid() {
    local name="$1" type="$2" udid stale
    udid=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
for key, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and d["isAvailable"] and runtime in ("", key): print(d["udid"]); sys.exit()' "$name" "$runtime")
    if [ -z "$udid" ] && [ -n "$runtime" ] && clone_of "$prefix" "$name"; then
        for stale in $(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
for key, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and key != runtime: print(d["udid"])' "$name" "$runtime"); do
            echo "  deleting $name ($stale): it was made on another runtime" >&2
            xcrun simctl shutdown "$stale" 2>/dev/null || true
            xcrun simctl delete "$stale" && rm -f "$leases/$stale" "$leases/runtime/$stale"
        done
    fi
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl create "$name" "$type" "$(runtime_id)")
    fi
    echo "$udid"
}

# Marks a clone as used now; other worktrees' runs leave a clone alone while its lease is fresh.
lease() { touch "$lease_dir/$1"; }

# Boots a clone and waits until it can install apps; a booted one returns at once. A boot that fails, or has not
# finished after 5 minutes (a wedged CoreSimulatorService would otherwise hold the run and its memory for good), is
# shut down and tried once more.
boot() {
    local udid="$1" rc=0
    lease "$udid"
    run_limited "$logs/boot-$udid.log" 300 xcrun simctl bootstatus "$udid" -b || rc=$?
    [ $rc != 0 ] || return 0
    echo "  the boot of $udid $( [ $rc = 124 ] && echo 'took over 300 s' || echo "failed ($rc)" ); trying once more"
    # The shutdown talks to the same service, so it is bounded too; one that does not finish ends the boot.
    run_limited "$logs/boot-$udid.log" 60 xcrun simctl shutdown "$udid" || [ $? != 124 ] || return 124
    run_limited "$logs/boot-$udid.log" 300 xcrun simctl bootstatus "$udid" -b
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
# Whether clone $2 is one of worktree prefix $1's: <prefix>-iphone-N, -ipad-N, a CASSINI_RUNTIME's -iphone18-N or
# -ipad18.2-N, -bench, -shots-iphone or -shots-ipad. A prefix match alone would take in the clones of a worktree whose
# name extends this one's (capture-start-failure and capture-start-failure-test), and shut down, erase or delete them
# in the middle of that worktree's run. No other worktree's clone has one of these names after this prefix: theirs
# end in -iphone-N or -ipad18-N after a longer prefix.
clone_of() {
    local rest="${2#"$1"-}"
    [ "$rest" != "$2" ] && [[ $rest =~ ^((iphone|ipad)([0-9]+(\.[0-9]+)*)?-[0-9]+|bench|shots-iphone|shots-ipad)$ ]]
}
our_clones() {
    local udid state name
    clones "$prefix-" | while read -r udid state name; do
        if clone_of "$prefix" "$name"; then echo "$udid $state $name"; fi
    done
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
        rm -f "$leases/$udid" "$leases/runtime/$udid"
    done
}

# On a CASSINI_RUNTIME: shuts down this worktree's booted clones that are not that runtime's (the default iPhones a
# run before kept booted), so the second leg does not boot beside them.
shutdown_other_runtimes() {
    [ -n "$runtime_tag" ] || return 0
    our_clones | while read -r udid state name; do
        case "$name" in "$prefix-iphone$runtime_tag-"*|"$prefix-ipad$runtime_tag-"*) continue ;; esac
        [ "$state" = Booted ] && xcrun simctl shutdown "$udid" 2>/dev/null || true
    done
}

# Seconds since the clone was last used: its lease; for a clone without one (booted by an older script or by hand),
# since an app was last installed or removed there, or else since it booted.
idle_seconds() {
    local udid="$1" now apps; now=$(date +%s)
    if [ -f "$leases/$udid" ]; then echo $(( now - $(stat -f %m "$leases/$udid") )); return; fi
    if [ -f "$leases/runtime/$udid" ]; then echo $(( now - $(stat -f %m "$leases/runtime/$udid") )); return; fi
    apps="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Bundle/Application"
    if [ -d "$apps" ]; then echo $(( now - $(stat -f %m "$apps") )); return; fi
    # Keep draining after the first match: an early awk exit can give ps SIGPIPE on a large listing under pipefail.
    ps -Ao etime=,args= | awk -v u="Devices/$udid/" '!found && $0 ~ /launchd_sim/ && index($0, u) {
        t = $1; d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
        n = split(t, b, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + b[i]; print d * 86400 + s; found = 1 }
        END { if (!found) print 0 }'
}

# Booted test clones of other worktrees: shut down (never deleted) when no xcodebuild uses them and they have been
# idle for $idle_minutes; otherwise left alone, their memory counted as in use. Prints what it did.
reap_idle_clones() {
    local busy udid state name idle
    busy=$(ps -Ao args= | grep -E '(^|/)xcodebuild ' | grep -oE 'id=[0-9A-F-]{36}' | cut -c4- | sort -u || true)
    while read -r udid state name; do
        [ "$state" = Booted ] || continue
        if clone_of "$prefix" "$name"; then continue; fi
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

# Waits, up to CASSINI_ADMIT_MINUTES, until a quarter of the CPU is idle and there is memory for one more simulator
# (the iPad, or a second shard), so the UI clones do not boot into a host that another run already keeps busy or
# swapping. It fails closed at the bounded deadline if resources are still low. The CPU is sampled over
# two seconds rather than read from the load average, which lags by minutes and would still count this run's own
# hosted tests; while this run's own swift test (beside the build) is still going, only the memory counts. The first
# clone's boot is waited for before, so its own boot is not counted either.
admit_minutes="${CASSINI_ADMIT_MINUTES:-10}"
free_mb() {
    local page; page=$(sysctl -n hw.pagesize)
    vm_stat | awk -v p="$page" '/Pages (free|inactive|speculative|purgeable)/ { gsub("\\.", "", $NF); n += $NF } END { print int(n * p / 1048576) }'
}
# Percent of the CPU idle over two seconds; 100 when it cannot be sampled, so a missing tool never holds a run.
cpu_idle() {
    # Rechecks sample CPU even beside swift test: its short-lived children must not spin admission.
    if [ "${1:-0}" != 1 ] && [ -n "${fast_pid:-}" ] && kill -0 "$fast_pid" 2>/dev/null; then echo 100; return; fi
    local idle; idle=$(iostat -n 0 -c 2 -w 2 2>/dev/null | tail -1 | awk '{ print int($3) }')
    case "$idle" in ''|*[!0-9]*) echo 100 ;; *) echo "$idle" ;; esac
}
wait_for_room() {
    [ "$admit_minutes" -gt 0 ] || return 0
    local t0 waited=0 idle free booted deadline announced=0
    t0=$(date +%s); deadline=$(( t0 + admit_minutes * 60 ))
    # This run's own booted iPhones count as free, as in auto_workers: tier_ui shuts down the ones it does not use.
    booted=$(our_clones | grep -cF "Booted $prefix-iphone$runtime_tag-" || true)
    while :; do
        # After the first wait, measure CPU even if this run's Swift suite is still alive.
        idle=$(cpu_idle "$announced"); free=$(( $(free_mb) + booted * 1536 )); waited=$(( $(date +%s) - t0 ))
        if [ "$idle" -ge 25 ] && [ "$free" -ge 2048 ]; then
            [ $waited -eq 0 ] || echo "  the host has room after $(( waited / 60 )) min $(( waited % 60 )) s (CPU $idle% idle, $free MB free)"
            return 0
        fi
        if [ $waited -ge $(( admit_minutes * 60 )) ]; then
            die "host still busy after $admit_minutes min (CPU $idle% idle, $free MB free); retry when resources are available"
        fi
        if [ "$announced" = 0 ]; then
            echo "  waiting for room: CPU $idle% idle, $free MB free"; announced=1
        fi
        # Exact CPU/free-memory thresholds have no recovery notification. Recheck on a same-user
        # process exit, or once at the deadline; never admit an unhealthy host after that bound.
        /usr/bin/python3 -I "$root/scripts/test-events.py" resource-event "$deadline"
        waited=$(( $(date +%s) - t0 ))
    done
}

# Gives disk back on a host that was 91% full, before a heavy run (the host lock held):
# - deletes clones made by this repository's runs (they have a lease in this cache) whose worktree is gone, once they
#   are shut down: a merged PR's worktree, removed without `clean`, left 7 GB of them;
# - erases a shut-down clone of this worktree that grew past 8 GB (an iPad booted once per run grew to 8.1 GB, most of
#   it a poster store and downloaded assets): its next boot starts from a fresh device;
# - removes the leases of clones that no longer exist, and the package caches no live worktree resolves to, keeping
#   the two newest.
# A copy without git (scripts/test-remote.sh) cannot tell which worktrees are live, and leaves all of it alone.
reclaim_disk() {
    local worktrees w names="" keys="" udid state name p owned
    worktrees=$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p') || return 0
    [ -n "$worktrees" ] || return 0
    while IFS= read -r w; do
        [ -d "$w" ] || continue
        names="$names ts-$(basename "$w")"
        [ -f "$w/Package.resolved" ] && [ -f "$w/Package.swift" ] \
            && keys="$keys $(cat "$w/Package.resolved" "$w/Package.swift" | shasum | cut -c1-12)"
    done <<< "$worktrees"
    while read -r udid state name; do
        [ "$state" = Shutdown ] || continue
        if clone_of "$prefix" "$name"; then
            local kb; kb=$(du -sk "$HOME/Library/Developer/CoreSimulator/Devices/$udid" 2>/dev/null | cut -f1 || true)
            if [ "${kb:-0}" -gt $(( 8 * 1024 * 1024 )) ]; then
                echo "  erasing $name: it grew to $(( kb / 1024 / 1024 )) GB"
                xcrun simctl erase "$udid" 2>/dev/null || true
            fi
            continue
        fi
        [ -f "$leases/$udid" ] || [ -f "$leases/runtime/$udid" ] || continue
        owned=""
        for p in $names; do if clone_of "$p" "$name"; then owned=1; break; fi; done
        [ -z "$owned" ] || continue
        echo "  deleting $name: its worktree is gone"
        xcrun simctl delete "$udid" 2>/dev/null && rm -f "$leases/$udid" "$leases/runtime/$udid"
    done < <(clones "ts-")
    local devices lease_file
    devices=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices: print(d["udid"])') || return 0
    for lease_file in "$leases"/* "$leases"/runtime/*; do
        [ -f "$lease_file" ] || continue
        printf '%s\n' "$devices" | grep -qx "$(basename "$lease_file")" || rm -f "$lease_file"
    done
    local newest key dir
    newest=$(ls -1td "$cache"/SourcePackages-* 2>/dev/null | head -2 | sed 's|.*/SourcePackages-||' | xargs || true)
    for dir in "$cache"/SourcePackages-* "$cache"/swiftpm-*; do
        [ -d "$dir" ] || continue
        key=${dir##*-}
        [[ $key =~ ^[0-9a-f]{12}$ ]] || continue
        case " $keys $newest " in *" $key "*) continue ;; esac
        echo "  removing ${dir##*/}: no worktree resolves to it"
        rm -rf "${cache:?}/${dir##*/}"
    done
}

# The start of every run that builds or boots: the host lock, then the disk. From here on the run may boot clones,
# so summary shuts them down unless they are kept (also under CASSINI_HEAVY_LOCK_HELD=1, where the caller holds the
# lock); take_heavy_lock exits the run when it does not get the lock, before heavy_started is set.
start_heavy() {
    take_heavy_lock
    heavy_started=1
    reclaim_disk
}

# Shards that fit in memory while leaving about 4 GB for everything else; each booted simulator with the app and its
# test runner takes about 1.5 GB. Clones of ours that are already booted count as available. At most 3: on 10 cores
# three shards already keep the CPU busy (simulator launches are CPU-bound), and a fourth made every test slower.
# $1 is the memory (MB) the iPad clone takes beside them, 0 when it does not run. Prints 0 when even one iPhone shard
# does not fit beside the iPad: the iPad then runs after the shard.
auto_workers() {
    local ipad_mb="${1:-0}" free booted
    free=$(free_mb)
    booted=$(our_clones | grep -cF "Booted $prefix-iphone$runtime_tag-" || true)
    local n=$(( (free - 4096 - ipad_mb) / 1536 + booted ))
    [ $n -gt 3 ] && n=3
    [ $n -lt 0 ] && n=0
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

# `changed` already selects exact test-target names (swift_targets_for). Swift Build exposes one test product per
# target; the older native backend exposes one package-wide product instead. Probe help only for one known name,
# and retain the existing all-products build for arbitrary filters, multiple targets and other toolchains.
swift_test_product() {
    case "${1:-}" in
        CassiniCoreTests|CassiniNotebookTests|CassiniEngineTests|CassiniInferenceTests|CassiniAudioTests|CassiniSherpaTests|CassiniWhistleTests) ;;
        *) return 0 ;;
    esac
    local help
    help=$(swift test --help-hidden 2>&1) || return 0
    case "$help" in *"--test-product <test-product>"*) ;; *) return 0 ;; esac
    case "$help" in
        *"Specify the build system to use. (default: swiftbuild)"*) printf '%s' "$1" ;;
    esac
    return 0
}

# swift test, filtered by $1 when given (a regular expression over Target.Suite/test).
swift_test() {
    local filter="${1:-}" product
    local args=(test)
    conformance_env
    seed_swiftpm
    product=$(swift_test_product "$filter")
    [ -z "$product" ] || args+=(--test-product "$product")
    [ -z "$filter" ] || args+=(--filter "$filter")
    # The checkouts are saved whatever the tests did; the tests' failure is the function's, also where it is called
    # as `swift_test || rc=$?`, which turns errexit off inside it.
    local rc=0
    run_logged "$logs/swift-test.log" 1800 swift "${args[@]}" || rc=$?
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

# swift test beside the build, which saves its minute or two of wall time. They do compete for the CPU: beside a busy
# build the package tests ran up to 100x slower (PR #24), so a wait in a package test allows 30 s, never a few. Its
# time is added to the summary when it is waited for.
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
    step_start "embedded minimum iOS"
    run_logged "$logs/embedded-minos.log" 60 /usr/bin/python3 -I "$root/scripts/check-embedded-minos.py" \
        "$derived/Build/Products/Debug-iphonesimulator/Cassini.app"
    step_end
    find_xctestrun
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

# The .xctestrun of the newest build.
find_xctestrun() {
    xctestrun=$(ls -t "$derived"/Build/Products/Cassini_*.xctestrun 2>/dev/null | grep -v '\.only-' | head -1 || true)
    [ -n "$xctestrun" ] || die "no .xctestrun in $derived/Build/Products: run scripts/test.sh build first"
}

# `prebuilt`: the products of the last build_for_testing, which the iOS 18 leg tests on its runtime without building.
use_built_products() {
    find_xctestrun
    local target
    for target in CassiniTests CassiniUITests; do
        [ -f "${xctestrun%.xctestrun}.only-$target.xctestrun" ] || die "no build to test: run scripts/test.sh build first"
    done
}

# Runs "$@" with its output in $1. When no test has started $2 seconds in (the test host or runner never came up),
# ends it and returns 124. Once a test runs, xcodebuild's own per-test time limit applies, and the whole run is ended
# $3 seconds in, returning 125.
run_watched() {
    local log="$1" limit="$2" total="$3" pid rc; shift 3
    : > "$log"
    "$@" >> "$log" 2>&1 & pid=$!
    if /usr/bin/python3 -I "$root/scripts/test-events.py" watch "$pid" "$log" "$limit" "$total" \
        --start "Test Case '" --total-status 125; then
        wait "$pid"
    else
        rc=$?
        if [ "$rc" = 124 ]; then
            echo "test.sh: no test started within ${limit}s; ending xcodebuild" >> "$log"
        else
            echo "test.sh: still running after ${total}s; ending xcodebuild" >> "$log"
        fi
        end_tree "$pid"
        return "$rc"
    fi
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
    # A whole run: the hosted tests take about a minute; a UI shard four times what its tests took before plus ten
    # minutes (shard_seconds, from the timing table), and at least an hour. One shard with all 90 tests planned about
    # 26 min, so a fixed hour failed it on a host running 2-4x slower.
    local limit=90 total=900
    if [ "$target" = CassiniUITests ]; then
        limit=180 total=$(( 4 * ${shard_seconds:-0} + 600 )); [ $total -ge 3600 ] || total=3600
    fi
    run_watched "$log" "$limit" "$total" xcodebuild test-without-building \
        -xctestrun "${xctestrun%.xctestrun}.only-$target.xctestrun" \
        -destination "platform=iOS Simulator,id=$udid" \
        -resultBundlePath "$bundle" -collect-test-diagnostics never -parallel-testing-enabled NO \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 600 \
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
    shutdown_other_runtimes
    first_iphone=$(clone_udid "$prefix-iphone$runtime_tag-1" "$iphone_type")
    boot "$first_iphone" & boot_pid=$!
}
wait_first_boot() {
    if [ -n "$boot_pid" ]; then wait "$boot_pid" || die "could not boot $prefix-iphone$runtime_tag-1"; boot_pid=""; fi
}

tier_app() {
    step_start "hosted tests (CassiniTests)"
    wait_first_boot
    local rc=0
    test_on_retrying CassiniTests "$logs/hosted.log" "$logs/hosted.xcresult" "$first_iphone" -only-testing:CassiniTests || rc=$?
    hosted_counts=$(hosted_counts "$logs/hosted.log")
    if [ $rc != 0 ]; then
        grep -E "error:|failed \(|Restarting after|\*\* TEST|test.sh:" "$logs/hosted.log" | tail -20 >&2
        # A test that crashes the host prints no "failed (" line; xcodebuild's own list names it.
        sed -n '/^Failing tests:/,/^$/p' "$logs/hosted.log" >&2; echo "see $logs/hosted.log" >&2
        step_end; return 1
    fi
    step_end
    grep -E "Executed [0-9]+ tests" "$logs/hosted.log" | tail -1 || true
}

# "passed/ran" of a hosted run's log, with the skipped ones after: "76/76 (6 skipped)".
hosted_counts() {
    # After a crash xcodebuild relaunches the host, and its last "Executed" line covers only the relaunch: count the
    # test cases instead, with every test in xcodebuild's "Failing tests:" list (a crashed one has no "failed (" line).
    if grep -q "^Restarting after unexpected exit" "$1" 2>/dev/null; then
        awk '/^Test Case .* passed \(/ { p++ } /^Test Case .* skipped \(/ { s++ }
             /^Failing tests:/ { list = 1; next } list && /^\t/ { f++; next } { list = 0 }
             END { printf "%d/%d%s\n", p, p + f, s ? " (" s " skipped)" : "" }' "$1"
        return 0
    fi
    grep -E "Executed [0-9]+ tests?, with" "$1" 2>/dev/null | tail -1 | sed -nE \
        's/.*Executed ([0-9]+) tests?, with (([0-9]+) tests? skipped and )?([0-9]+) failures?.*/\1 \3 \4/p' |
        awk '{ if (NF == 2) { n = $1; s = 0; f = $2 } else { n = $1; s = $2; f = $3 }
               printf "%d/%d%s\n", n - s - f, n - s, s ? " (" s " skipped)" : "" }' || true
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
# A CASSINI_RUNTIME records into a table of its own and plans from the committed one until it has one.
timings_file="$cache/ui-test-durations${runtime_tag:+-ios$runtime_tag}.tsv"
committed_timings="$root/scripts/ui-test-durations.tsv"
# The seconds the tests on stdin took before, by the same table as plan_shards (15 for a test it has not seen).
planned_seconds() {
    awk -v f="$timings_file" -v c="$committed_timings" '
        BEGIN {
            while ((getline line < c) > 0) { split(line, p, "\t"); d[p[1]] = p[2] }
            while ((getline line < f) > 0) { split(line, p, "\t"); d[p[1]] = p[2] }
        }
        NF { s += ($0 in d) ? d[$0] : 15 }
        END { print int(s) }'
}

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

# The tests (Class/method) a log shows started but never ending: their runner was killed under them.
killed_tests() {
    local log="$1"
    sed -nE "s/^Test Case '-\[CassiniUITests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (started|passed|failed|skipped).*/\1\/\2 \3/p" "$log" 2>/dev/null \
        | awk '{ if ($2 == "started") open[$1] = 1; else delete open[$1] } END { for (t in open) print t }' | sort
}

# The simulator's backboardd (its display server) sometimes aborts in Metal's texture validation while Core Animation
# flattens a layer (iOS 27 simulator; a report lands in ~/Library/Logs/DiagnosticReports). Its respawn ends every
# process in the clone, the UI test runner too, so the test it was running fails with "Test crashed with signal kill"
# and no assertion. When that shard's only failures are such tests and a backboardd report appeared during the run,
# they run once more on the same clone, into ui-<shard>-retry.log. Returns 0 when the shard is green after it.
retry_killed_tests() {
    local shard="$1" udid="$2" log="$logs/ui-$1.log" killed t args=()
    killed=$(killed_tests "$log")
    [ -n "$killed" ] || return 1
    grep -qE "^Test Case '.*' failed \(" "$log" && return 1
    # A crash of this clone's backboardd: the report names its device (coalition SimDevice.<udid>), so a crash in
    # another worktree's clone at the same time does not count.
    find "$HOME/Library/Logs/DiagnosticReports" -name 'backboardd-*.ips' -newer "$logs/.ui-started" \
        -exec grep -l "SimDevice\.$udid" {} + 2>/dev/null | grep -q . || return 1
    echo "  ui-$shard: the simulator's backboardd crashed (Metal texture validation) and took the runner with it;" \
        "running again: $(echo $killed)"
    while IFS= read -r t; do args+=("-only-testing:CassiniUITests/$t"); done <<< "$killed"
    test_on CassiniUITests "$logs/ui-$shard-retry.log" "$logs/ui-$shard-retry.xcresult" "$udid" "${args[@]}" || return 1
    [ "$(count_ran "$logs/ui-$shard-retry.log")" = "$(printf '%s\n' "$killed" | wc -l | tr -d ' ')" ]
}

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
    wait_first_boot
    wait_for_room
    local ipad_tests=""
    case "${CASSINI_UI_IPAD:-1}" in
        0) ;;
        all) ipad_tests=$tests ;;
        *) ipad_tests=$(printf '%s\n' "$tests" | grep '/testIPad' || true) ;;
    esac
    # The iPad clone (an iPad Pro, about 2 GB) is budgeted before the iPhone shards; when not even one shard fits
    # beside it, it runs after the shards instead of beside them.
    local workers="${CASSINI_UI_WORKERS:-$(auto_workers "$( [ -n "$ipad_tests" ] && echo 2048 || echo 0)")}" ipad_after=0
    if [ "$workers" -lt 1 ]; then
        workers=1
        if [ -n "$ipad_tests" ]; then ipad_after=1; echo "  memory is short: the iPad runs after the iPhone shard"; fi
    fi
    [ "$workers" -gt "$count" ] && workers=$count
    # Booted iPhone clones this run does not use give their memory back.
    our_clones | while read -r udid state name; do
        case "$name" in "$prefix-iphone$runtime_tag-"*) ;; *) continue ;; esac
        if [ "$state" = Booted ] && [ "${name##*-}" -gt "$workers" ]; then xcrun simctl shutdown "$udid" 2>/dev/null || true; fi
    done
    local plan; plan=$(printf '%s\n' "$tests" | plan_shards "$workers")
    step_end

    # Each shard starts as soon as its clone is up; the iPad, booted for this run only, starts when it is (or once
    # the shards are done, when memory is short).
    step_start "UI tests ($workers shard(s)$( [ -n "$ipad_tests" ] && { [ $ipad_after = 1 ] && echo ', then iPad' || echo ' + iPad'; }))"
    rm -rf "$logs"/ui-*.log "$logs"/ui-*-retry.xcresult
    touch "$logs/.ui-started"
    local pids=() k shard_args t
    wait_first_boot
    for k in $(seq 1 "$workers"); do
        shard_args=()
        while IFS= read -r t; do [ -n "$t" ] && shard_args+=("-only-testing:CassiniUITests/$t"); done \
            < <(printf '%s\n' "$plan" | awk -F'\t' -v k="$k" '$1 == k { print $2 }')
        [ ${#shard_args[@]} -gt 0 ] || continue
        ( udid=$(clone_udid "$prefix-iphone$runtime_tag-$k" "$iphone_type")
          shard_seconds=$(printf '%s\n' "$plan" | awk -F'\t' -v k="$k" '$1 == k { print $2 }' | planned_seconds)
          boot "$udid" || { echo "could not boot $prefix-iphone$runtime_tag-$k" > "$logs/ui-$k.log"; exit 1; }
          test_on_retrying CassiniUITests "$logs/ui-$k.log" "$logs/ui-$k.xcresult" "$udid" "${shard_args[@]}" ) & pids+=("$!:$k")
    done
    local failed="" p
    if [ $ipad_after = 1 ]; then
        for p in ${pids[@]+"${pids[@]}"}; do wait "${p%%:*}" || failed="$failed ${p##*:}"; done
        pids=()
    fi
    local ipad=""
    if [ -n "$ipad_tests" ]; then
        ipad=$(clone_udid "$prefix-ipad$runtime_tag-1" "$ipad_type")
        shard_args=()
        while IFS= read -r t; do shard_args+=("-only-testing:CassiniUITests/$t"); done <<< "$ipad_tests"
        ( shard_seconds=$(printf '%s\n' "$ipad_tests" | planned_seconds)
          boot "$ipad" || { echo "could not boot $prefix-ipad$runtime_tag-1" > "$logs/ui-ipad.log"; exit 1; }
          test_on_retrying CassiniUITests "$logs/ui-ipad.log" "$logs/ui-ipad.xcresult" "$ipad" "${shard_args[@]}" ) & pids+=("$!:ipad")
    fi
    for p in ${pids[@]+"${pids[@]}"}; do wait "${p%%:*}" || failed="$failed ${p##*:}"; done
    local still=""
    for p in $failed; do
        if [ "$p" = ipad ]; then retry_killed_tests ipad "$ipad" && continue
        else retry_killed_tests "$p" "$(clone_udid "$prefix-iphone$runtime_tag-$p" "$iphone_type")" && continue
        fi
        still="$still $p"
    done
    failed=$still
    record_durations
    step_end

    # Every test ran exactly once on the iPhones: a shard that lost tests fails here too.
    local ran; ran=$(count_ran "$logs"/ui-[0-9].log "$logs"/ui-[0-9]-retry.log)
    # `|| echo`, not `&& echo`: the assignment takes the substitution's status, and a run without the iPad ended here.
    ui_counts="iPhone $ran/$count$( [ -z "$ipad" ] || echo ", iPad $(count_ran "$logs/ui-ipad.log" "$logs/ui-ipad-retry.log")/$(printf '%s\n' "$ipad_tests" | wc -l | tr -d ' ')")"
    echo "UI tests: $ran of $count ran on iPhone$( [ -n "$ipad" ] && echo ", $(count_ran "$logs/ui-ipad.log" "$logs/ui-ipad-retry.log") of $(printf '%s\n' "$ipad_tests" | wc -l | tr -d ' ') on iPad")"
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
        [ "$(count_ran "$logs/ui-ipad.log" "$logs/ui-ipad-retry.log")" = "$(printf '%s\n' "$ipad_tests" | wc -l | tr -d ' ')" ] \
            || die "the iPad did not run all of its UI tests"
    fi
}

# ---------------------------------------------------------------- the iOS 18 leg

# With the leg on, the runtime it needs is checked before anything is built: a Mac without it fails the run (and the
# status of a run that posts one) at once, rather than after the default tiers, and never skips the leg.
ios18_preflight() {
    [ "$ios18_mode" != off ] || return 0
    local picked
    if ! picked=$(pick_runtime "$ios18_runtime" "" "" CASSINI_IOS18_RUNTIME); then
        leg_counts="no iOS $ios18_tag runtime for the iOS $ios18_tag leg"
        die "the iOS $ios18_tag leg is on (CASSINI_IOS18=$ios18_mode) but ${picked:-the simulator runtimes could not be listed}." \
            "Install the runtime (README, Verify), or set CASSINI_IOS18=0, which posts no commit status"
    fi
    # Decision 6: by default a branch that changes views gets the full leg, every other one the smoke run.
    local views
    if [ "$ios18_mode" = smoke ] && [ "$ios18_by_default" = 1 ] && views=$(ios18_view_changes) && [ -n "$views" ]; then
        ios18_mode=full
        echo "iOS $ios18_tag leg: full, since the branch changes views ($views)"
    fi
    echo "iOS $ios18_tag leg: $ios18_mode, on iOS $(printf '%s' "$picked" | cut -f2) once the default runtime's tiers pass"
}

# The view sources changed since the branch left origin/main (the first three), for the leg's default mode.
ios18_view_changes() {
    local base
    base=$(git -C "$root" merge-base HEAD "$(main_ref)" 2>/dev/null) || return 0
    changed_files "$base" | grep -E '^Cassini/(Features|Design)/' | head -3 | xargs
}

# The leg's part of the status, with its mode and $2 (" failed") after it: "iOS 18.2 smoke: hosted 76/76, iPhone 17/17"
# from the leg-counts "iOS 18.2 hosted 76/76, iPhone 17/17"; "iOS 18 full failed" when the leg left none.
ios18_leg_text() {
    case "$1" in
        "iOS "[0-9]*" "*) printf 'iOS %s %s%s: %s' "$(echo "$1" | cut -d' ' -f2)" "$ios18_mode" "${2:-}" "$(echo "$1" | cut -d' ' -f3-)" ;;
        *) printf 'iOS %s %s%s%s' "$ios18_tag" "$ios18_mode" "${2:-}" "${1:+: $1}" ;;
    esac
}

# The leg: this worktree's clones of the default runtime are shut down first (one runtime's simulators at a time on
# this Mac), then `prebuilt` runs the same build's hosted and UI tests on the leg's runtime, with CASSINI_RUNTIME's
# clones, logs and timing table. smoke runs the UI tests of the smoke list on one iPhone and no iPad; full every UI
# test, sharded as usual, and the iPad's. An -only-testing:CassiniUITests selection replaces the list, and the other
# extra arguments go to its xcodebuild runs as they do here. What it ran (its leg-counts) goes into the status.
run_ios18_leg() {
    [ "$ios18_mode" != off ] || return 0
    local args=() a line selected=0 rc=0 leg_logs envs
    leg_logs="$derived/test-logs-ios$ios18_tag"
    for a in ${extra[@]+"${extra[@]}"}; do
        case "$a" in -only-testing:CassiniUITests/*) selected=1 ;; esac
        args+=("$a")
    done
    envs=(CASSINI_RUNTIME="$ios18_runtime" CASSINI_HEAVY_LOCK_HELD=1 CASSINI_KEEP_SIMS=0)
    # On a runtime with Apple speech (the leg run on iOS 26 today), every launch gets the iOS 18 facts and the UI
    # tests expect what iOS 18 shows (CassiniUITests/DeviceUnderTest.swift), so the iOS 18 side of each test runs.
    [ "${ios18_tag%%.*}" -lt 26 ] || envs+=(TEST_RUNNER_CASSINI_IOS18_FACTS=1)
    if [ "$ios18_mode" = smoke ]; then
        envs+=(CASSINI_UI_IPAD=0 CASSINI_UI_WORKERS=1)
        if [ $selected = 0 ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%%#*}"; line="${line//[[:space:]]/}"
                [ -z "$line" ] || args+=("-only-testing:CassiniUITests/$line")
            done < "$ios18_smoke_list"
        fi
    fi
    shutdown_clones
    step_start "iOS $ios18_tag leg ($ios18_mode)"
    rm -f "$leg_logs/leg-counts"
    # The device types follow the leg's runtime, whatever the default leg was given.
    env -u CASSINI_POST_STATUS -u CASSINI_IPHONE -u CASSINI_IPAD "${envs[@]}" \
        /bin/bash "$root/scripts/test.sh" prebuilt ${args[@]+"${args[@]}"} || rc=$?
    step_end
    line=$(cat "$leg_logs/leg-counts" 2>/dev/null || true)
    if [ $rc != 0 ]; then
        leg_counts=$(ios18_leg_text "$line" " failed")
        echo "the iOS $ios18_tag leg failed; logs in $leg_logs" >&2
        return 1
    fi
    leg_counts=$(ios18_leg_text "$line")
    echo "iOS $ios18_tag leg: $leg_counts"
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
        Packages/CassiniWhistle/Sources/*) echo "CassiniWhistleTests" ;;
        Packages/*/Tests/*) echo "$1" | cut -d/ -f4 ;;
    esac
}

# The ref the branch is compared with: origin/main when there is one, since a local main nobody updates falls behind
# and then the diff takes in every merged PR since (a stale base adds tests, never drops them). main otherwise, for a
# copy without the remote (test-remote.sh). Says so when the local main differs from origin/main.
main_ref() {
    local origin local_main
    origin=$(git -C "$root" rev-parse -q --verify origin/main) || { echo main; return; }
    local_main=$(git -C "$root" rev-parse -q --verify refs/heads/main || true)
    if [ -n "$local_main" ] && [ "$local_main" != "$origin" ]; then
        echo "note: the local main ($(git -C "$root" rev-parse --short "$local_main")) is not origin/main ($(git -C "$root" rev-parse --short "$origin")); comparing with origin/main" >&2
    fi
    echo origin/main
}

tier_changed() {
    local base="${base_ref:-$(git -C "$root" merge-base HEAD "$(main_ref)" 2>/dev/null || echo HEAD)}"
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
    start_heavy
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
    fast|app|ui|all|changed|build|ios18|prebuilt) ;;
    *) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 2 ;;
esac

extra_xcodebuild_from_extra
trap summary EXIT
# A run ended by a signal must not pass: under bash 3.2 the EXIT trap of a shell killed by a signal sees $? = 0, so
# summary printed PASSED and posted a green commit status for a run that never finished. Exiting from the signal's
# own trap hands summary the real status.
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
start_status
# Inside the trap: a missing runtime fails the run (and the status of a run that posts one), never skips it.
case "$tier" in fast|build|ios18) ;; *) select_runtime ;; esac
ios18_preflight
case "$tier" in
    fast) tier_fast ;;
    app)  start_heavy; start_first_boot; build_for_testing; tier_app ;;
    ui)   start_heavy; start_first_boot; build_for_testing; tier_ui ;;
    all)  start_heavy; start_first_boot; check_strings; start_fast_beside; build_for_testing; tier_app; tier_ui
          wait_fast_beside; run_ios18_leg ;;
    ios18) start_heavy; build_for_testing; run_ios18_leg ;;
    prebuilt) start_heavy; start_first_boot; use_built_products; tier_app; tier_ui ;;
    changed) tier_changed ;;
    build) start_heavy; build_for_testing ;;
esac
