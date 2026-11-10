#!/bin/bash
# The WP0 spike on a simulator: builds the app and its hosted tests with the native runtime (the release that
# Package.swift links), then runs CassiniTests/SherpaBenchTests, which loads Parakeet Ultra, decodes FLEURS-it short
# against Android's golden, 28 s and 60 s clips and optionally a long run, and records memory and speed,
# and CassiniTests/ParakeetJobTests, a real Ultra transcription job on the same clip checked against the iOS golden,
# and CassiniTests/DCVectorTests, D26.1's dc-quiet-jfk-v1 vector through the real detector with and without the
# high-pass and through Ultra (when the vector is found).
# Simulator figures are not device measurements: no jetsam limit, the Mac's cores and memory.
#
#   scripts/sherpa-bench.sh
#
# Environment:
#   CASSINI_PARAKEET_MODEL_ROOT the model root as scripts/fetch-ci-models.py writes it, read only (default .tools/models,
#                               then .tools/ci-models)
#   CASSINI_PARAKEET_MODELS     the Ultra directory, read only (default its revision directory under the model root,
#                               scripts/fetch-ci-models.py --print-path parakeet-ultra-0.6b-int8-v2)
#   CASSINI_PARAKEET_RECORD     1 records CassiniTests/Goldens/fleurs-it-short.ios.json instead of comparing with it
#   CASSINI_PARAKEET_AUDIO       optional input WAV (default FLEURS-it short)
#   CASSINI_PARAKEET_GOLDEN      optional Android text comparison; empty disables it
#   CASSINI_PARAKEET_IOS_GOLDEN  optional exact-word JSON path for recording/comparing English fixtures
#   CASSINI_BENCH_ONLY          bench, job or dc runs only that test (default all three)
#   CASSINI_DC_VECTOR           the directory with D26.1's dc-quiet-jfk-v1 WAVs (default ux-draft/dc in
#                               ~/dev/cassini-coordination; without it the dc test is left out)
#   CASSINI_ANDROID             the cassini-android checkout with the fixtures and goldens (default ~/dev/cassini-android,
#                               the plan's baseline at main, then ../cassini-android beside the main checkout)
#   CASSINI_BENCH_LONG_SECONDS  the long run in 28 s windows (default 3600; 0 skips it)
#   CASSINI_BENCH_SPEAKERS      a model root with the diarizer and CAM++ installed: with Ultra still loaded, stream 60 s
#                               through Sortformer and make a CAM++ print (default the model root when both are
#                               installed there; none skips)
#   CASSINI_IPHONE              the device type to clone (default "iPhone 17")
#   CASSINI_SHERPA_LOCAL        1 builds with the runtime of scripts/build-sherpa-xcframework.sh in .tools/sherpa
# Writes .tools/bench/<time>.json and the xcodebuild log beside it. The simulator clone is
# ts-<worktree directory>-bench, so scripts/test.sh clean removes it with this worktree's other clones.
set -euo pipefail
# One heavy run at a time per host (scripts/test.sh, "the host"): this script runs under the host lock, which the
# scripts/test.sh it calls then knows it holds.
if [ "${CASSINI_HEAVY_LOCK_HELD:-}" != 1 ]; then
    echo "taking the host lock ${CASSINI_HEAVY_LOCK:-$HOME/.cassini-heavy.lock} (waits while another run holds it)"
    exec env CASSINI_HEAVY_LOCK_HELD=1 /usr/bin/lockf -k -t $(( ${CASSINI_LOCK_MINUTES:-60} * 60 )) \
        "${CASSINI_HEAVY_LOCK:-$HOME/.cassini-heavy.lock}" "$0" "$@"
fi
cd "$(dirname "$0")/.."
root=$PWD
. scripts/native-common.sh
# The release by default; CASSINI_SHERPA_LOCAL=1 builds with the local runtime instead.
sherpa_env=${CASSINI_SHERPA_LOCAL:-0}
if [ "$sherpa_env" != 0 ]; then
    [ -d "$sherpa_xcframework" ] || { echo "error: no $sherpa_xcframework; run scripts/build-sherpa-xcframework.sh" >&2; exit 1; }
fi

fetch=(/usr/bin/python3 -I scripts/fetch-ci-models.py)
model_root=${CASSINI_PARAKEET_MODEL_ROOT:-}
for candidate in "$root/.tools/models" "$root/.tools/ci-models"; do
    [ -n "$model_root" ] && break
    "${fetch[@]}" --dest "$candidate" --ready parakeet-ultra-0.6b-int8-v2 && model_root=$candidate
done
[ -n "$model_root" ] || { echo "error: no models; run scripts/fetch-ci-models.py --dest .tools/models" >&2; exit 1; }
models=${CASSINI_PARAKEET_MODELS:-$("${fetch[@]}" --dest "$model_root" --print-path parakeet-ultra-0.6b-int8-v2)}
speakers=${CASSINI_BENCH_SPEAKERS:-}
if [ -z "$speakers" ] && "${fetch[@]}" --dest "$model_root" --ready nemotron-3-diarization-int8 campplus-voxceleb-16k; then
    speakers=$model_root
fi
[ "$speakers" = none ] && speakers=""
dc_vector=${CASSINI_DC_VECTOR:-$HOME/dev/cassini-coordination/ux-draft/dc}
dc=(); [ -f "$dc_vector/dc-quiet-jfk-v1.wav" ] && dc=(-only-testing:CassiniTests/DCVectorTests)
case "${CASSINI_BENCH_ONLY:-}" in
    bench) only=(-only-testing:CassiniTests/SherpaBenchTests) ;;
    job) only=(-only-testing:CassiniTests/ParakeetJobTests) ;;
    dc) [ ${#dc[@]} -gt 0 ] || { echo "error: no dc-quiet-jfk-v1.wav in $dc_vector; set CASSINI_DC_VECTOR" >&2; exit 1; }
        only=("${dc[@]}") ;;
    *) only=(-only-testing:CassiniTests/SherpaBenchTests -only-testing:CassiniTests/ParakeetJobTests ${dc[@]+"${dc[@]}"}) ;;
esac
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
android=${CASSINI_ANDROID:-}
for candidate in "$HOME/dev/cassini-android" "$(dirname "$(dirname "$common")")/cassini-android"; do
    [ -n "$android" ] && break
    [ -d "$candidate/fixtures/audio" ] && android=$candidate
done
[ -n "$android" ] || { echo "error: set CASSINI_ANDROID to a cassini-android checkout" >&2; exit 1; }
audio=${CASSINI_PARAKEET_AUDIO:-$android/fixtures/audio/fleurs-it-short.wav}
golden=${CASSINI_PARAKEET_GOLDEN-$android/app/src/androidTest/assets/goldens/fleurs-it-short.txt}
for f in "$models/encoder.int8.onnx" "$audio" ${golden:+"$golden"}; do [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }; done

derived=$root/DerivedData.noindex/sherpa-bench
out=$root/.tools/bench
mkdir -p "$out"
stamp=$(date +%Y%m%d-%H%M%S)
log=$out/$stamp.log

echo "==> xcodegen"
xcodegen generate --quiet
echo "==> build for testing (CASSINI_SHERPA_LOCAL=$sherpa_env, arm64 simulator)"
CASSINI_SHERPA_LOCAL=$sherpa_env xcodebuild build-for-testing -project Cassini.xcodeproj -scheme Cassini \
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

echo "==> ${only[*]#-only-testing:} on $name ($udid)"
xctestrun=$(ls -t "$derived"/Build/Products/Cassini_*.xctestrun | head -1)
rc=0
TEST_RUNNER_CASSINI_PARAKEET_MODELS="$models" \
TEST_RUNNER_CASSINI_PARAKEET_MODEL_ROOT="$model_root" \
TEST_RUNNER_CASSINI_DC_VECTOR="$dc_vector" \
TEST_RUNNER_CASSINI_PARAKEET_RECORD="${CASSINI_PARAKEET_RECORD:-0}" \
TEST_RUNNER_CASSINI_PARAKEET_AUDIO="$audio" \
TEST_RUNNER_CASSINI_PARAKEET_IOS_GOLDEN="${CASSINI_PARAKEET_IOS_GOLDEN:-}" \
TEST_RUNNER_CASSINI_PARAKEET_GOLDEN="$golden" \
TEST_RUNNER_CASSINI_BENCH_LONG_SECONDS="${CASSINI_BENCH_LONG_SECONDS:-3600}" \
TEST_RUNNER_CASSINI_BENCH_SPEAKERS="$speakers" \
TEST_RUNNER_CASSINI_BENCH_OUT="$out/$stamp.json" \
xcodebuild test-without-building -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$udid" \
    "${only[@]}" -resultBundlePath "$out/$stamp.xcresult" > "$log" 2>&1 || rc=$?
sed -n '/CASSINI_BENCH_BEGIN/,/CASSINI_BENCH_END/p' "$log" | sed '1d;$d' > "$out/$stamp.stdout.json" || true
sed -n '/CASSINI_PARAKEET_JOB_BEGIN/,/CASSINI_PARAKEET_JOB_END/p' "$log" | sed '1d;$d' > "$out/$stamp.job.json" || true
[ -s "$out/$stamp.job.json" ] && echo "job: $out/$stamp.job.json"
grep -E "Test Case .*(passed|failed|skipped)|error:" "$log" | head -20
[ -s "$out/$stamp.json" ] || cp "$out/$stamp.stdout.json" "$out/$stamp.json"
echo "results: $out/$stamp.json (log $log)"
exit $rc
