#!/bin/bash
# The WP0 spike on a simulator: builds the app and its hosted tests with CASSINI_SHERPA_LOCAL=1 (the runtime from
# scripts/build-sherpa-xcframework.sh), then runs CassiniTests/SherpaBenchTests, which loads Parakeet Ultra, decodes
# FLEURS-it short against Android's golden, 28 s and 60 s clips and optionally a long run, and records memory and speed.
# Simulator figures are not device measurements: no jetsam limit, the Mac's cores and memory.
#
#   scripts/sherpa-bench.sh
#
# Environment:
#   CASSINI_PARAKEET_MODELS     the model directory, read only (default ~/cassini-investigation/models/parakeet-ultra-int8)
#   CASSINI_ANDROID             the cassini-android checkout with the fixtures and goldens (default ~/dev/cassini-android,
#                               the plan's baseline at main, then ../cassini-android beside the main checkout)
#   CASSINI_BENCH_LONG_SECONDS  the long run in 28 s windows (default 3600; 0 skips it)
#   CASSINI_BENCH_FLUIDAUDIO    1 runs FluidAudio's speakers afterwards in the same process (downloads its models into
#                               the simulator; default 0)
#   CASSINI_IPHONE              the device type to clone (default "iPhone 17")
# Writes .tools/bench/<time>.json and the xcodebuild log beside it. The simulator clone is
# ts-<worktree directory>-bench, so scripts/test.sh clean removes it with this worktree's other clones.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
. scripts/native-common.sh
[ -d "$sherpa_xcframework" ] || { echo "error: no $sherpa_xcframework; run scripts/build-sherpa-xcframework.sh" >&2; exit 1; }

models=${CASSINI_PARAKEET_MODELS:-$HOME/cassini-investigation/models/parakeet-ultra-int8}
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
android=${CASSINI_ANDROID:-}
for candidate in "$HOME/dev/cassini-android" "$(dirname "$(dirname "$common")")/cassini-android"; do
    [ -n "$android" ] && break
    [ -d "$candidate/fixtures/audio" ] && android=$candidate
done
[ -n "$android" ] || { echo "error: set CASSINI_ANDROID to a cassini-android checkout" >&2; exit 1; }
audio=$android/fixtures/audio/fleurs-it-short.wav
golden=$android/app/src/androidTest/assets/goldens/fleurs-it-short.txt
for f in "$models/encoder.int8.onnx" "$audio" "$golden"; do [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }; done

derived=$root/DerivedData.noindex/sherpa-bench
out=$root/.tools/bench
mkdir -p "$out"
stamp=$(date +%Y%m%d-%H%M%S)
log=$out/$stamp.log

echo "==> xcodegen"
xcodegen generate --quiet
echo "==> build for testing (CASSINI_SHERPA_LOCAL=1, arm64 simulator)"
CASSINI_SHERPA_LOCAL=1 xcodebuild build-for-testing -project Cassini.xcodeproj -scheme Cassini \
    -derivedDataPath "$derived" -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 > "$out/$stamp.build.log" 2>&1 \
    || { grep -E "error:" "$out/$stamp.build.log" | head -20 >&2; echo "see $out/$stamp.build.log" >&2; exit 1; }

name="ts-$(basename "$root")-bench"
udid=$(xcrun simctl list devices -j | /usr/bin/python3 -I -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == sys.argv[1] and d["isAvailable"]: print(d["udid"]); sys.exit()' "$name")
if [ -z "$udid" ]; then
    runtime=$(xcrun simctl list runtimes -j | /usr/bin/python3 -I -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')
    udid=$(xcrun simctl create "$name" "${CASSINI_IPHONE:-iPhone 17}" "$runtime")
fi
xcrun simctl bootstatus "$udid" -b > /dev/null

echo "==> SherpaBenchTests on $name ($udid)"
xctestrun=$(ls -t "$derived"/Build/Products/Cassini_*.xctestrun | head -1)
rc=0
TEST_RUNNER_CASSINI_PARAKEET_MODELS="$models" \
TEST_RUNNER_CASSINI_PARAKEET_AUDIO="$audio" \
TEST_RUNNER_CASSINI_PARAKEET_GOLDEN="$golden" \
TEST_RUNNER_CASSINI_BENCH_LONG_SECONDS="${CASSINI_BENCH_LONG_SECONDS:-3600}" \
TEST_RUNNER_CASSINI_BENCH_FLUIDAUDIO="${CASSINI_BENCH_FLUIDAUDIO:-0}" \
TEST_RUNNER_CASSINI_BENCH_OUT="$out/$stamp.json" \
xcodebuild test-without-building -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:CassiniTests/SherpaBenchTests -resultBundlePath "$out/$stamp.xcresult" > "$log" 2>&1 || rc=$?
sed -n '/CASSINI_BENCH_BEGIN/,/CASSINI_BENCH_END/p' "$log" | sed '1d;$d' > "$out/$stamp.stdout.json" || true
grep -E "Test Case .*(passed|failed|skipped)|error:" "$log" | head -20
[ -s "$out/$stamp.json" ] || cp "$out/$stamp.stdout.json" "$out/$stamp.json"
echo "results: $out/$stamp.json (log $log)"
exit $rc
