#!/bin/bash
# The speaker package's smoke test on a simulator: builds the app and its hosted tests with the native runtime (the
# release that Package.swift links), then runs CassiniTests/SpeakerSmokeTests: streaming
# Sortformer over a two-speaker FLEURS mix in the job's 28 s windows, a save and restore of its state between windows,
# the whole-recording call, and CAM++ prints of each speaker; then CassiniTests/SpeakerJobTests, a real job with
# Parakeet Ultra, streaming Sortformer and CAM++ on the same mix, and Transcribe again naming the speaker saved from
# it (when Ultra and the speech detector are beside the speaker models). Simulator figures are not device measurements.
#
#   scripts/speaker-smoke.sh
#
# Environment:
#   CASSINI_SPEAKER_MODELS  the model root with the diarizer and CAM++ installed (default .tools/models, which
#                           scripts/fetch-ci-models.py --dest .tools/models fills); it is also the job's model root
#   CASSINI_SPEAKER_JOB     0 skips the end-to-end job
#   CASSINI_ANDROID         the cassini-android checkout with fixtures/audio/fleurs-it-short.wav (default
#                           ~/dev/cassini-android, then ../cassini-android beside the main checkout)
#   CASSINI_IPHONE          the device type to clone (default "iPhone 17")
#   CASSINI_SHERPA_LOCAL    1 builds with the runtime of scripts/build-sherpa-xcframework.sh in .tools/sherpa
# Makes .tools/fixtures/fleurs-two-speakers.wav with scripts/fetch-speaker-fixture.py when it is missing, and writes
# .tools/speakers/<time>.json and the xcodebuild logs beside it. The simulator clone is ts-<worktree directory>-bench,
# shared with scripts/sherpa-bench.sh, so scripts/test.sh clean removes it with this worktree's other clones.
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
models=${CASSINI_SPEAKER_MODELS:-$root/.tools/models}
"${fetch[@]}" --dest "$models" --ready nemotron-3-diarization-int8 campplus-voxceleb-16k \
    || { echo "error: no speaker models in $models; run scripts/fetch-ci-models.py --dest .tools/models" >&2; exit 1; }
audio=$root/.tools/fixtures/fleurs-two-speakers.wav
if [ ! -f "$audio" ]; then
    common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
    android=${CASSINI_ANDROID:-}
    for candidate in "$HOME/dev/cassini-android" "$(dirname "$(dirname "$common")")/cassini-android"; do
        [ -n "$android" ] && break
        [ -f "$candidate/fixtures/audio/fleurs-it-short.wav" ] && android=$candidate
    done
    [ -n "$android" ] || { echo "error: set CASSINI_ANDROID to a cassini-android checkout" >&2; exit 1; }
    python=$(command -v python3.14 || command -v python3)
    "$python" -I scripts/fetch-speaker-fixture.py --android "$android" --dest "$root/.tools/fixtures"
fi

derived=$root/DerivedData.noindex/sherpa-bench
out=$root/.tools/speakers
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

# The end-to-end job needs Parakeet Ultra and its detector beside the speaker models (CASSINI_SPEAKER_JOB=0 skips it).
model_root=$models
only=(-only-testing:CassiniTests/SpeakerSmokeTests)
if [ "${CASSINI_SPEAKER_JOB:-1}" != 0 ] && "${fetch[@]}" --dest "$model_root" --ready parakeet-ultra-0.6b-int8 silero-vad; then
    only+=(-only-testing:CassiniTests/SpeakerJobTests)
fi
echo "==> ${only[*]#-only-testing:} on $name ($udid)"
xctestrun=$(ls -t "$derived"/Build/Products/Cassini_*.xctestrun | head -1)
rc=0
TEST_RUNNER_CASSINI_SPEAKER_MODELS="$models" \
TEST_RUNNER_CASSINI_SPEAKER_AUDIO="$audio" \
TEST_RUNNER_CASSINI_SPEAKER_OUT="$out/$stamp.json" \
TEST_RUNNER_CASSINI_PARAKEET_MODEL_ROOT="$model_root" \
TEST_RUNNER_CASSINI_SPEAKER_JOB_OUT="$out/$stamp.job.json" \
xcodebuild test-without-building -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$udid" \
    "${only[@]}" -resultBundlePath "$out/$stamp.xcresult" > "$log" 2>&1 || rc=$?
grep -E "Test Case .*(passed|failed|skipped)|error:" "$log" | head -20
[ -s "$out/$stamp.json" ] || sed -n '/CASSINI_SPEAKERS_BEGIN/,/CASSINI_SPEAKERS_END/p' "$log" | sed '1d;$d' > "$out/$stamp.json" || true
[ -s "$out/$stamp.job.json" ] || sed -n '/CASSINI_SPEAKER_JOB_BEGIN/,/CASSINI_SPEAKER_JOB_END/p' "$log" | sed '1d;$d' > "$out/$stamp.job.json" || true
[ -s "$out/$stamp.job.json" ] && echo "job: $out/$stamp.job.json"
echo "results: $out/$stamp.json (log $log)"
exit $rc
