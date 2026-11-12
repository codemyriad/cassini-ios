#!/bin/bash
# Takes the README's screenshots (CassiniUITests/ScreenshotTests) and saves them under docs/screenshots/.
#
#   scripts/screenshots.sh                 every shot: iPhone 17 and iPad Pro 13-inch (M5), light and dark, English
#   scripts/screenshots.sh --locale it     the same in Italian, under docs/screenshots/it/ (also fr, es, pt-BR and pt-PT)
#   scripts/screenshots.sh --device iphone|ipad --appearance light|dark
#                                          only that device or appearance (stale files are then left alone)
#   scripts/screenshots.sh --output DIR  save the same stable layout under DIR (relative to the calling directory)
#   scripts/screenshots.sh --no-build      use the last `scripts/test.sh build`
#   scripts/screenshots.sh -- <xcodebuild arguments>, e.g. -- -only-testing:CassiniUITests/ScreenshotTests/test03Transcribing
#
# It builds through `scripts/test.sh build` and runs the tests on simulator clones of its own (<prefix>-shots-iphone and
# <prefix>-shots-ipad, which `scripts/test.sh clean` deletes). The device gets the appearance and the region (en_US, it_IT,
# fr_FR, es_ES, pt_BR or pt_PT), and its status bar is pinned: 9:41, a full battery that is not charging, full Wi-Fi and cellular bars. An
# iPad's status bar also shows the date, 8 October, but with the wrong weekday ("Sun"): the simulator's home screen
# shows the override's Thursday, an app's status bar does not, and --time takes only ISO dates. The tests launch the app with the UI-test clock, named seeds and the same language and region, and
# attach each shot under the name it is saved as. The attachments are exported from the result bundle with
# `xcrun xcresulttool export attachments`, mapped by name, scaled to at most 1200 px (sips) and quantised with pngquant
# when it is installed. A full run that took every shot removes the PNGs of the set that it no longer makes; a run that
# took fewer shots than ScreenshotTests has (say, every test skipped) fails and removes nothing.
#
#   docs/screenshots/{light,dark}/NN-name.png        iPhone
#   docs/screenshots/ipad/{light,dark}/NN-name.png   iPad, the split view in landscape and portrait
#   docs/screenshots/<locale>/...                    the same layout for --locale it, fr, es, pt-BR or pt-PT
#
# Environment: CASSINI_IPHONE / CASSINI_IPAD device types (default "iPhone 17", "iPad Pro 13-inch (M5)"),
# CASSINI_SIM_PREFIX as for scripts/test.sh, CASSINI_KEEP_SIMS=1 to leave the clones booted.
# CASSINI_SHOTS_QUANTIZE=0 disables pngquant (default for --output, which also writes shots.json).
set -euo pipefail
script_args=("$@")

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/DerivedData.noindex"
prefix="${CASSINI_SIM_PREFIX:-ts-$(basename "$root")}"
iphone_type="${CASSINI_IPHONE:-iPhone 17}"
ipad_type="${CASSINI_IPAD:-iPad Pro 13-inch (M5)}"
# The shots ScreenshotTests takes in each appearance: test01Library to test11LibraryExport, and the two split views.
iphone_shots=12 ipad_shots=2
locale=en devices="iphone ipad" appearances="light dark" build=1 extra=() output=""
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'; }
require_value() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: $1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
    case "$1" in
        --locale) require_value "$@"; locale="$2"; shift 2 ;;
        --device) require_value "$@"; devices="$2"; shift 2 ;;
        --appearance) require_value "$@"; appearances="$2"; shift 2 ;;
        --output) require_value "$@"; output="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        --no-build) build=0; shift ;;
        --) shift; extra=("$@"); break ;;
        *) usage; exit 2 ;;
    esac
done
case "$locale" in
    en) region=en_US out="$root/docs/screenshots" ;;
    it|fr|es) region="${locale}_$(echo "$locale" | tr a-z A-Z)" out="$root/docs/screenshots/$locale" ;;
    pt-BR|pt-PT) region="${locale/-/_}" out="$root/docs/screenshots/$locale" ;;
    *) echo "error: --locale is en, it, fr, es, pt-BR or pt-PT" >&2; exit 2 ;;
esac
case "$devices" in iphone|ipad|"iphone ipad") ;; *) echo "error: --device is iphone or ipad" >&2; exit 2 ;; esac
case "$appearances" in light|dark|"light dark") ;; *) echo "error: --appearance is light or dark" >&2; exit 2 ;; esac
if [ -n "$output" ]; then
    case "$output" in /*) out="$output" ;; *) out="$PWD/$output" ;; esac
fi
[ -z "$output" ] || export CASSINI_SHOTS_QUANTIZE="${CASSINI_SHOTS_QUANTIZE:-0}"
# Every screenshot test, unless the extra arguments pick some (two -only-testing would run both).
only=(-only-testing:CassiniUITests/ScreenshotTests)
for argument in ${extra[@]+"${extra[@]}"}; do case "$argument" in -only-testing*) only=() ;; esac; done
full=1
[ "$devices" = "iphone ipad" ] && [ "$appearances" = "light dark" ] && [ ${#extra[@]} = 0 ] && [ -z "$output" ] || full=0

# One heavy run at a time per host (scripts/test.sh, "the host"): this script runs under the host lock, which the
# scripts/test.sh it calls then knows it holds.
if [ "${CASSINI_HEAVY_LOCK_HELD:-}" != 1 ]; then
    echo "taking the host lock ${CASSINI_HEAVY_LOCK:-$HOME/.cassini-heavy.lock} (waits while another run holds it)"
    exec env CASSINI_HEAVY_LOCK_HELD=1 /usr/bin/lockf -k -t $(( ${CASSINI_LOCK_MINUTES:-60} * 60 )) \
        "${CASSINI_HEAVY_LOCK:-$HOME/.cassini-heavy.lock}" "$0" ${script_args[@]+"${script_args[@]}"}
fi

# Record only clones touched by this invocation; failure/signal cleanup never boots or changes another worktree.
owned=()
cleanup() {
    local rc=$? udid
    trap - EXIT
    for udid in ${owned[@]+"${owned[@]}"}; do
        xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
        if [ "${CASSINI_KEEP_SIMS:-0}" != 1 ]; then xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; fi
    done
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

work="$derived/screenshots"
rm -rf "$work"; mkdir -p "$work"

if [ "$build" = 1 ]; then "$root/scripts/test.sh" build; fi
xctestrun=$(ls -t "$derived"/Build/Products/Cassini_*.only-CassiniUITests.xctestrun 2>/dev/null | head -1)
[ -n "$xctestrun" ] || { echo "error: no UI test build; run without --no-build" >&2; exit 1; }

# The UDID of the clone called $1 of device type $2, created when missing.
clone_udid() {
    local name="$1" type="$2" udid runtime
    udid=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == sys.argv[1] and d["isAvailable"]: print(d["udid"]); sys.exit()' "$name")
    if [ -z "$udid" ]; then
        runtime=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')
        udid=$(xcrun simctl create "$name" "$type" "$runtime")
    fi
    echo "$udid"
}

# Copies the exported attachments of $1 (a folder with manifest.json) into $2 by name, scaled and quantised; prints
# each file written.
save_attachments() {
    local exported="$1" target="$2" name file
    mkdir -p "$target"
    /usr/bin/python3 - "$exported/manifest.json" <<'PY' | while IFS=$'\t' read -r name file; do
import json, re, sys
for test in json.load(open(sys.argv[1])):
    for attachment in test.get("attachments", []):
        # Xcode adds "_<n>_<UUID>.png" to the attachment's name; the tests' own events have other names.
        match = re.fullmatch(r"(\d\d-[a-z0-9-]+)_\d+_[0-9A-F-]+\.png", attachment.get("suggestedHumanReadableName", ""))
        if match: print(f"{match.group(1)}\t{attachment['exportedFileName']}")
PY
        sips -Z 1200 "$exported/$file" --out "$target/$name.png" > /dev/null
        if [ "${CASSINI_SHOTS_QUANTIZE:-1}" != 0 ] && command -v pngquant > /dev/null; then
            pngquant --force --skip-if-larger --quality 75-95 --strip --output "$target/$name.png" "$target/$name.png" || true
        fi
        echo "$target/$name.png"
    done
}

written="$work/written.txt"
: > "$written"
failed=0
for device in $devices; do
    case "$device" in
        iphone) udid=$(clone_udid "$prefix-shots-iphone" "$iphone_type"); dest="$out" expected=$iphone_shots ;;
        ipad) udid=$(clone_udid "$prefix-shots-ipad" "$ipad_type"); dest="$out/ipad" expected=$ipad_shots ;;
        *) echo "error: --device is iphone or ipad" >&2; exit 2 ;;
    esac
    owned+=("$udid")
    echo "==> $device ($udid)"
    xcrun simctl bootstatus "$udid" -b > /dev/null
    # The status bar's clock follows the device's region, not the app's: set it, and boot again for it to apply.
    if [ "$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2> /dev/null)" != "$region" ]; then
        xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$region"
        xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$locale"
        xcrun simctl shutdown "$udid"
        xcrun simctl bootstatus "$udid" -b > /dev/null
    fi
    # The override takes an ISO date: the UI-test clock's 8 October 2026, 9:41 in the Mac's time zone, which the
    # simulator shares. Only the iPad shows the date, and in an app with the wrong weekday (see above).
    now=$(date -u -r "$(date -j -f "%Y-%m-%dT%H:%M:%S" "2026-10-08T09:41:00" "+%s")" "+%Y-%m-%dT%H:%M:%S.000Z")
    xcrun simctl status_bar "$udid" override --time "$now" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100
    for appearance in $appearances; do
        echo "  $appearance"
        xcrun simctl ui "$udid" appearance "$appearance"
        bundle="$work/$device-$appearance.xcresult"
        # TEST_RUNNER_ variables reach the test runner without the prefix.
        if ! TEST_RUNNER_CASSINI_SCREENSHOTS=1 TEST_RUNNER_CASSINI_SCREENSHOT_LANGUAGE="$locale" \
            TEST_RUNNER_CASSINI_SCREENSHOT_REGION="$region" \
            xcodebuild test-without-building -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$udid" \
            -resultBundlePath "$bundle" -collect-test-diagnostics never -parallel-testing-enabled NO \
            -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 600 \
            ${only[@]+"${only[@]}"} ${extra[@]+"${extra[@]}"} > "$work/$device-$appearance.log" 2>&1; then
            grep -E "error:|failed \(" "$work/$device-$appearance.log" | tail -20 >&2 || true
            echo "  the screenshot tests failed; see $work/$device-$appearance.log" >&2
            failed=1
        fi
        [ -d "$bundle" ] || continue
        xcrun xcresulttool export attachments --path "$bundle" --output-path "$work/$device-$appearance" > /dev/null
        save_attachments "$work/$device-$appearance" "$dest/$appearance" > "$work/$device-$appearance.txt"
        sed "s|$root/|    |" "$work/$device-$appearance.txt"
        cat "$work/$device-$appearance.txt" >> "$written"
        # A run can pass and take nothing (every test skipped, or no ScreenshotTests in the build): never count it whole.
        taken=$(wc -l < "$work/$device-$appearance.txt" | tr -d ' ')
        if [ ${#extra[@]} = 0 ] && [ "$taken" != "$expected" ]; then
            echo "  error: $taken of the $expected $device screenshots were taken" >&2
            failed=1
        fi
    done
    xcrun simctl ui "$udid" appearance light
    [ "${CASSINI_KEEP_SIMS:-0}" = 1 ] || xcrun simctl shutdown "$udid" 2> /dev/null || true
    owned=()
done

# A full run that succeeded, every shot taken, leaves only the shots it took.
if [ "$full" = 1 ] && [ "$failed" = 0 ]; then
    skip=(); [ "$locale" = en ] && for other in it fr es pt-BR pt-PT; do skip+=(-not -path "$out/$other/*"); done
    find "$out" -name '*.png' ${skip[@]+"${skip[@]}"} | while read -r file; do
        grep -qxF "$file" "$written" || { rm "$file"; echo "removed stale ${file#$root/}"; }
    done
    find "$out" -type d -empty -delete
fi
[ "$failed" = 0 ] || exit 1
if [ -n "$output" ]; then
    /usr/bin/python3 "$root/scripts/screenshot-manifest.py" --root "$root" --output "$out" --written "$written" \
        --prefix "$prefix" --locale "$locale" --region "$region"
fi
echo "$(wc -l < "$written" | tr -d ' ') screenshots in ${out#$root/}"
