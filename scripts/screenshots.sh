#!/bin/bash
# Takes the README's screenshots (CassiniUITests/ScreenshotTests) and saves them under docs/screenshots/.
#
#   scripts/screenshots.sh                 every shot: iPhone 17 and iPad Pro 13-inch (M5), light and dark, English
#   scripts/screenshots.sh --locale it     the same in Italian, under docs/screenshots/it/
#   scripts/screenshots.sh --device iphone|ipad --appearance light|dark
#                                          only that device or appearance (stale files are then left alone)
#   scripts/screenshots.sh --no-build      use the last `scripts/test.sh build`
#   scripts/screenshots.sh -- <xcodebuild arguments>, e.g. -- -only-testing:CassiniUITests/ScreenshotTests/test03Transcribing
#
# It builds through `scripts/test.sh build` and runs the tests on simulator clones of its own (<prefix>-shots-iphone and
# <prefix>-shots-ipad, which `scripts/test.sh clean` deletes). The device gets the appearance and the region (en_US or
# it_IT), and its status bar is pinned: 9:41, a full battery that is not charging, full Wi-Fi and cellular bars. The
# tests launch the app with the UI-test clock, named seeds and the same language and region, and attach each shot under
# the name it is saved as. The attachments are exported from the result bundle with `xcrun xcresulttool export
# attachments`, mapped by name, scaled to at most 1200 px (sips) and quantised with pngquant when it is installed. A
# full run removes the PNGs of the set that it no longer makes.
#
#   docs/screenshots/{light,dark}/NN-name.png        iPhone
#   docs/screenshots/ipad/{light,dark}/NN-name.png   iPad, the split view in landscape and portrait
#   docs/screenshots/it/...                          the same layout for --locale it
#
# Environment: CASSINI_IPHONE / CASSINI_IPAD device types (default "iPhone 17", "iPad Pro 13-inch (M5)"),
# CASSINI_SIM_PREFIX as for scripts/test.sh, CASSINI_KEEP_SIMS=1 to leave the clones booted.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/DerivedData.noindex"
prefix="${CASSINI_SIM_PREFIX:-ts-$(basename "$root")}"
iphone_type="${CASSINI_IPHONE:-iPhone 17}"
ipad_type="${CASSINI_IPAD:-iPad Pro 13-inch (M5)}"
locale=en devices="iphone ipad" appearances="light dark" build=1 extra=()

while [ $# -gt 0 ]; do
    case "$1" in
        --locale) locale="$2"; shift 2 ;;
        --device) devices="$2"; shift 2 ;;
        --appearance) appearances="$2"; shift 2 ;;
        --no-build) build=0; shift ;;
        --) shift; extra=("$@"); break ;;
        *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
case "$locale" in
    en) region=en_US out="$root/docs/screenshots" ;;
    it) region=it_IT out="$root/docs/screenshots/it" ;;
    *) echo "error: --locale is en or it" >&2; exit 2 ;;
esac
full=1
[ "$devices" = "iphone ipad" ] && [ "$appearances" = "light dark" ] && [ ${#extra[@]} = 0 ] || full=0

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
        if command -v pngquant > /dev/null; then
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
        iphone) udid=$(clone_udid "$prefix-shots-iphone" "$iphone_type"); dest="$out" ;;
        ipad) udid=$(clone_udid "$prefix-shots-ipad" "$ipad_type"); dest="$out/ipad" ;;
        *) echo "error: --device is iphone or ipad" >&2; exit 2 ;;
    esac
    echo "==> $device ($udid)"
    xcrun simctl bootstatus "$udid" -b > /dev/null
    # The status bar's clock follows the device's region, not the app's: set it, and boot again for it to apply.
    if [ "$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2> /dev/null)" != "$region" ]; then
        xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$region"
        xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$locale"
        xcrun simctl shutdown "$udid"
        xcrun simctl bootstatus "$udid" -b > /dev/null
    fi
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
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
            -only-testing:CassiniUITests/ScreenshotTests ${extra[@]+"${extra[@]}"} > "$work/$device-$appearance.log" 2>&1; then
            grep -E "error:|failed \(" "$work/$device-$appearance.log" | tail -20 >&2 || true
            echo "  the screenshot tests failed; see $work/$device-$appearance.log" >&2
            failed=1
        fi
        [ -d "$bundle" ] || continue
        xcrun xcresulttool export attachments --path "$bundle" --output-path "$work/$device-$appearance" > /dev/null
        save_attachments "$work/$device-$appearance" "$dest/$appearance" | tee -a "$written" | sed "s|$root/|    |"
    done
    xcrun simctl ui "$udid" appearance light
    [ "${CASSINI_KEEP_SIMS:-0}" = 1 ] || xcrun simctl shutdown "$udid" 2> /dev/null || true
done

# A full run that succeeded leaves only the shots it took.
if [ "$full" = 1 ] && [ "$failed" = 0 ]; then
    skip=(); [ "$locale" = en ] && skip=(-not -path "$out/it/*")
    find "$out" -name '*.png' ${skip[@]+"${skip[@]}"} | while read -r file; do
        grep -qxF "$file" "$written" || { rm "$file"; echo "removed stale ${file#$root/}"; }
    done
    find "$out" -type d -empty -delete
fi
[ "$failed" = 0 ] || exit 1
echo "$(wc -l < "$written" | tr -d ' ') screenshots in ${out#$root/}"
