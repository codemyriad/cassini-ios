#!/bin/bash
# Check the sherpa-onnx runtime against the lock in scripts/native-dependencies.json. Exits non-zero on any mismatch.
#
#   scripts/verify-native-runtime.sh [--quiet]
#
# Checks:
#   - Package.swift: the local binary targets point at the paths scripts/native-common.sh names, and every released
#     binary target (url:) carries the checksum the lock pins for it;
#   - the lock: the sherpa-onnx source is the codemyriad fork at a full commit, ONNX Runtime is 1.27.1;
#   - when a build is present in .tools/sherpa (scripts/build-sherpa-xcframework.sh): the zip's SwiftPM checksum is the
#     lock's (unless the lock still says PENDING), both slices (ios-arm64, ios-arm64-simulator) export the C API Cassini
#     calls, the header has tokens_arr, no espeak-ng, piper or TTS model code is linked in (TTS is off; the C API keeps
#     its SherpaOnnx*OfflineTts* entry points as stubs), and the deployment target is 15.1; the unpacked ONNX Runtime
#     has the pinned slices and its zip the pinned checksum.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/native-common.sh
quiet=false
[ "${1:-}" = --quiet ] && quiet=true
say() { $quiet || printf '%s\n' "$*"; }
status=0
fail() { say "FAIL: $*"; status=1; }
ok() { say "ok: $*"; }

# ---------------------------------------------------------------- lock

source_url=$(pin sherpa-onnx url)
if [[ "$source_url" =~ ^https://github.com/codemyriad/sherpa-onnx/archive/[0-9a-f]{40}\.tar\.gz$ ]]; then
    ok "sherpa-onnx source is the codemyriad fork at ${source_url:50:12}"
else
    fail "sherpa-onnx source $source_url is not a codemyriad/sherpa-onnx commit archive"
fi
[ "$(pin onnxruntime-ios version)" = 1.27.1 ] && ok "ONNX Runtime 1.27.1" || fail "ONNX Runtime is $(pin onnxruntime-ios version), not 1.27.1"
sherpa_sha=$(pin sherpa-onnx-ios sha256)
ort_sha=$(pin onnxruntime-ios sha256)

# ---------------------------------------------------------------- Package.swift

grep -q "path: \"$sherpa_xcframework\"" Package.swift && ok "Package.swift links $sherpa_xcframework locally" \
    || fail "Package.swift has no binaryTarget at $sherpa_xcframework"
grep -q "path: \"$onnxruntime_xcframework\"" Package.swift && ok "Package.swift links $onnxruntime_xcframework locally" \
    || fail "Package.swift has no binaryTarget at $onnxruntime_xcframework"
# A released target: .binaryTarget(name: "...", url: "...", checksum: "...") on one line.
while IFS= read -r line; do
    name=$(sed -n 's/.*name: *"\([^"]*\)".*/\1/p' <<<"$line")
    checksum=$(sed -n 's/.*checksum: *"\([^"]*\)".*/\1/p' <<<"$line")
    case "$name" in
        SherpaOnnxC) want=$sherpa_sha ;;
        onnxruntime) want=$ort_sha ;;
        *) continue ;;
    esac
    [ "$checksum" = "$want" ] && ok "Package.swift's $name checksum is the lock's" \
        || fail "Package.swift's $name checksum is $checksum, the lock pins $want"
done < <(grep -E '\.binaryTarget\(.*url:' Package.swift || true)

# ---------------------------------------------------------------- a local build

zip=$sherpa_local/dist/$(pin sherpa-onnx-ios file)
if [ -f "$zip" ]; then
    actual=$(swift package compute-checksum "$zip")
    if [ "$sherpa_sha" = PENDING ]; then
        say "note: the lock's sherpa-onnx-ios checksum is PENDING; this build's is $actual"
    elif [ "$actual" = "$sherpa_sha" ]; then
        ok "$zip matches the lock: $actual"
    else
        fail "$zip has checksum $actual, the lock pins $sherpa_sha"
    fi
else
    say "note: no local build in $sherpa_local (scripts/build-sherpa-xcframework.sh)"
fi

if [ -d "$sherpa_xcframework" ]; then
    for slice in ios-arm64 ios-arm64-simulator; do
        lib=$sherpa_xcframework/$slice/SherpaOnnxC.framework/SherpaOnnxC
        if [ ! -f "$lib" ]; then fail "missing slice $slice"; continue; fi
        exported=$(nm -gU "$lib" 2>/dev/null | awk '{print $NF}' | sort -u)
        for symbol in SherpaOnnxCreateOfflineRecognizer SherpaOnnxCreateOfflineStream SherpaOnnxAcceptWaveformOffline \
                      SherpaOnnxDecodeOfflineStream SherpaOnnxGetOfflineStreamResult \
                      SherpaOnnxDestroyOfflineRecognizerResult SherpaOnnxCreateVoiceActivityDetector; do
            grep -qx "_$symbol" <<<"$exported" || fail "$slice does not export $symbol"
        done
        tts=$(nm "$lib" 2>/dev/null | grep -cE 'espeak_|[Pp]iper|OfflineTtsImpl|OfflineTtsVits|OfflineTtsKokoro' || true)
        [ "$tts" = 0 ] && ok "$slice: C API exported, no espeak-ng, piper or TTS symbols" || fail "$slice has $tts espeak-ng, piper or TTS symbols"
        platforms=$(otool -l "$lib" | awk '/LC_BUILD_VERSION/{b=1} b&&/platform/{p=$2} b&&/minos/{print p, $2; b=0}' | sort -u)
        want_platform=2; [ "$slice" = ios-arm64-simulator ] && want_platform=7
        [ "$platforms" = "$want_platform 15.1" ] && ok "$slice: platform $want_platform, minimum iOS 15.1" \
            || fail "$slice build versions: $(tr '\n' ';' <<<"$platforms") (want $want_platform 15.1)"
        archs=$(lipo -archs "$lib")
        [ "$archs" = arm64 ] || fail "$slice architectures: $archs (want arm64)"
    done
    header=$sherpa_xcframework/ios-arm64/SherpaOnnxC.framework/Headers/sherpa-onnx/c-api/c-api.h
    grep -q 'const char \*const \*tokens_arr;' "$header" && ok "c-api.h has tokens_arr" || fail "c-api.h has no tokens_arr"
fi
if [ -d "$onnxruntime_xcframework" ]; then
    for slice in ios-arm64 ios-arm64_x86_64-simulator; do
        [ -f "$onnxruntime_xcframework/$slice/onnxruntime.framework/onnxruntime" ] || fail "onnxruntime has no $slice slice"
    done
    ort_zip=.tools/downloads/onnxruntime-ios-static-xcframework-$(pin onnxruntime-ios version).xcframework.zip
    if [ -f "$ort_zip" ]; then
        [ "$(swift package compute-checksum "$ort_zip")" = "$ort_sha" ] && ok "ONNX Runtime zip matches the lock" \
            || fail "$ort_zip does not match the lock"
    fi
fi
exit $status
