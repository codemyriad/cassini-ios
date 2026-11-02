#!/bin/bash
# Build Cassini's sherpa-onnx runtime for iOS: the codemyriad fork at 0c2ee3f (tag v1.13.7-cassini-parakeet-ultra-v1, D16:
# NeMo frontend of upstream PR #4024) against ONNX Runtime 1.27.1, C API only, no TTS, for iPhone (OS64) and the
# Apple-silicon simulator (SIMULATORARM64). The iOS counterpart of cassini-android's scripts/build-native-aar.sh.
#
# Speakers: speaker diarization is on, as in Android's build (the fork's build-android-*.sh pass
# SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON), so the C API has the Sortformer diarizer and the CAM++ speaker-embedding
# extractor. Two patches go onto the source before CMake runs:
#   scripts/streaming-diarization.patch        Android's file, byte for byte: Sortformer's incremental mode
#                                             (ProcessStreamingChunk, Save/RestoreStreamingState) in csrc, plus JNI
#                                             and Kotlin entry points, which this build does not compile;
#   scripts/streaming-diarization-c-api.patch  iOS only: the same calls in the C API, as
#                                             SherpaOnnxOfflineSpeakerDiarizationProcessStreamingChunk,
#                                             ...SaveStreamingState, ...DestroyStreamingState, ...RestoreStreamingState.
#
#   scripts/build-sherpa-xcframework.sh
#
# Writes, all under the gitignored .tools/:
#   .tools/sherpa/SherpaOnnxC.xcframework            the static C API framework (module SherpaOnnxC)
#   .tools/sherpa/onnxruntime.xcframework            the pinned ONNX Runtime static xcframework, unpacked
#   .tools/sherpa/dist/<file>.xcframework.zip        the zip that a release would publish
#   .tools/sherpa/dist/checksum.txt                  its SwiftPM checksum (the zip's SHA-256)
# CASSINI_SHERPA_LOCAL=1 then makes Package.swift link the two xcframeworks; scripts/verify-native-runtime.sh compares
# the build with the lock in scripts/native-dependencies.json.
#
# The build is reproducible: a second run from a clean .tools/sherpa-build gives the same checksum, also from another
# checkout path or umask. Archives are written with ZERO_AR_DATE, libtool -D and a fixed umask, the xcframework's
# Info.plist lists its slices in sorted order, and the files in the zip get one fixed time and a sorted order.
#
# Environment:
#   SHERPA_ONNX_SRC   an existing sherpa-onnx checkout to build instead of the pinned source archive
#   CASSINI_JOBS      parallel compile jobs (default: the number of cores)
# Never replace the fork with upstream k2-fsa binaries or the fork's own Package.swift: both lack #4024.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
. scripts/native-common.sh

downloads=$root/.tools/downloads
work=$root/.tools/sherpa-build
out=$root/$sherpa_local
jobs=${CASSINI_JOBS:-$(sysctl -n hw.ncpu)}
deployment_target=15.1
artifact=$(pin sherpa-onnx-ios file)
export ZERO_AR_DATE=1 LC_ALL=C SOURCE_DATE_EPOCH=315532800
# libtool -D zeroes the members' dates and owners but keeps their modes, and zip records modes too: without a fixed
# umask, a shell with umask 002 builds a different checksum from the same sources.
umask 022
# The fork's scripts default to ORT 1.28.1; Cassini pins 1.27.1, the same as Android.
export SHERPA_ONNX_ONNXRUNTIME_VERSION=$(pin onnxruntime-ios version)

rm -rf "$work"
mkdir -p "$work" "$downloads"

# ---------------------------------------------------------------- sources

if [ -z "${SHERPA_ONNX_SRC:-}" ]; then
    fetch "$(pin sherpa-onnx url)" "$(pin sherpa-onnx sha256)" "$downloads/sherpa-onnx-$(pin sherpa-onnx sha256 | cut -c1-12).tar.gz"
    mkdir -p "$work/sherpa-onnx"
    tar xzf "$downloads/sherpa-onnx-$(pin sherpa-onnx sha256 | cut -c1-12).tar.gz" -C "$work/sherpa-onnx" --strip-components=1
    src=$work/sherpa-onnx
else
    src=$(cd "$SHERPA_ONNX_SRC" && pwd)
fi
# The source sits inside this repository's .tools/; keep git (show-info.cmake runs it) from finding Cassini's repo.
# git apply needs the same: inside Cassini's repo it would silently skip every path.
GIT_CEILING_DIRECTORIES=$(dirname "$src")
export GIT_CEILING_DIRECTORIES

# Apply each patch the way Android's build-native-aar.sh does, or accept a source that already has it.
for patch in streaming-diarization.patch streaming-diarization-c-api.patch; do
    if (cd "$src" && git apply --check "$root/scripts/$patch" 2>/dev/null); then
        (cd "$src" && git apply "$root/scripts/$patch")
    elif ! (cd "$src" && git apply --reverse --check "$root/scripts/$patch" 2>/dev/null); then
        printf 'The source does not match scripts/%s.\n' "$patch" >&2
        exit 1
    fi
done

# The CMake dependencies, fetched once into .tools/downloads and checked against the lock. The fork's cmake files
# look for them in the source directory before downloading, and check the same SHA-256 again.
while IFS= read -r name; do
    file=$(pin "$name" file)
    sha=$(pin "$name" sha256)
    # An entry with pinnedBy is pinned inside that dependency's own cmake files, which CMake checks.
    if [ ! -f "$src/cmake/$name.cmake" ] && [ -z "$(pin "$name" pinnedBy 2>/dev/null)" ]; then
        printf 'The source has no cmake/%s.cmake; update the lock.\n' "$name" >&2; exit 1
    fi
    if [ -f "$src/cmake/$name.cmake" ] && ! grep -q "$sha" "$src/cmake/$name.cmake"; then
        printf 'cmake/%s.cmake no longer pins %s; update the lock.\n' "$name" "$sha" >&2; exit 1
    fi
    fetch "$(pin "$name" url)" "$sha" "$downloads/$file"
    cp "$downloads/$file" "$src/$file"
done < <(pins_with file)

ort_zip=$downloads/onnxruntime-ios-static-xcframework-$SHERPA_ONNX_ONNXRUNTIME_VERSION.xcframework.zip
fetch "$(pin onnxruntime-ios url)" "$(pin onnxruntime-ios sha256)" "$ort_zip"
mkdir -p "$work/onnxruntime"
unzip -q "$ort_zip" -d "$work/onnxruntime"
ort=$work/onnxruntime/onnxruntime.xcframework

# ---------------------------------------------------------------- compile

# build_slice <PLATFORM> <build dir> <ORT slice>: the flags of the fork's build-ios-no-tts.sh, with Cassini's target.
build_slice() {
    local platform="$1" dir="$2" slice="$3"
    printf '==> %s\n' "$platform"
    SHERPA_ONNXRUNTIME_LIB_DIR=$ort/$slice \
    SHERPA_ONNXRUNTIME_INCLUDE_DIR=$ort/$slice/onnxruntime.framework/Headers \
    cmake -S "$src" -B "$dir" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$src/toolchains/ios.toolchain.cmake" \
        -DPLATFORM="$platform" \
        -DDEPLOYMENT_TARGET=$deployment_target \
        -DENABLE_BITCODE=0 -DENABLE_ARC=1 -DENABLE_VISIBILITY=0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$dir/install" \
        -DBUILD_SHARED_LIBS=OFF \
        -DSHERPA_ONNX_ENABLE_TTS=OFF \
        -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON \
        -DBUILD_PIPER_PHONMIZE_EXE=OFF -DBUILD_PIPER_PHONMIZE_TESTS=OFF \
        -DBUILD_ESPEAK_NG_EXE=OFF -DBUILD_ESPEAK_NG_TESTS=OFF \
        -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
        -DSHERPA_ONNX_ENABLE_BINARY=OFF \
        -DSHERPA_ONNX_ENABLE_TESTS=OFF \
        -DSHERPA_ONNX_ENABLE_CHECK=OFF \
        -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
        -DSHERPA_ONNX_ENABLE_JNI=OFF \
        -DSHERPA_ONNX_ENABLE_C_API=ON \
        -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
        -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
        -DCMAKE_C_FLAGS="-ffile-prefix-map=$work=." \
        -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$work=." \
        > "$dir.configure.log"
    # FetchContent must not reach the network for anything the lock does not pin. The cmake files word the message
    # differently ("Downloading eigen from <url>", "Downloading simple-sentencepiece <url>", "Downloading pre-compiled
    # onnxruntime"); a dependency found locally logs its local path instead of a URL.
    local network='^-- Downloading .*(://|pre-compiled)'
    if grep -qE "$network" "$dir.configure.log"; then
        grep -E "$network" "$dir.configure.log" >&2
        printf 'CMake downloaded a dependency that is not in scripts/native-dependencies.json.\n' >&2
        exit 1
    fi
    cmake --build "$dir" -j "$jobs" > "$dir.build.log"
    cmake --install "$dir" > /dev/null
}

build_slice OS64 "$work/os64" ios-arm64
build_slice SIMULATORARM64 "$work/simulator_arm64" ios-arm64_x86_64-simulator

# ---------------------------------------------------------------- package

# The archives the no-TTS build makes; libucd, libpiper_phonemize and libespeak-ng (GPL-3.0) are not among them.
archives=(libkaldi-native-fbank-core.a libkissfft-float.a libsherpa-onnx-c-api.a libsherpa-onnx-core.a
          libsherpa-onnx-fst.a libsherpa-onnx-fstfar.a libsherpa-onnx-kaldifst-core.a libkaldi-decoder-core.a
          libssentencepiece_core.a)

# make_framework <build dir> <supported platform>: merge the archives into SherpaOnnxC.framework in that dir.
make_framework() {
    local dir="$1" supported="$2" fw="$1/SherpaOnnxC.framework" a inputs=()
    # Every archive the build makes is merged or knowingly left out (the C++ API wraps the C API; Cassini calls C).
    for a in "$dir"/lib/*.a; do
        case " ${archives[*]} libsherpa-onnx-cxx-api.a " in
            *" $(basename "$a") "*) ;;
            *) printf 'the build made %s, which the script does not know; add it to archives or skip it\n' "$a" >&2
               exit 1 ;;
        esac
    done
    for a in "${archives[@]}"; do
        [ -f "$dir/lib/$a" ] || { printf 'missing %s/lib/%s\n' "$dir" "$a" >&2; exit 1; }
        inputs+=("$dir/lib/$a")
    done
    rm -rf "$fw"
    mkdir -p "$fw/Headers/sherpa-onnx/c-api" "$fw/Modules"
    libtool -static -D -no_warning_for_no_symbols -o "$fw/SherpaOnnxC" "${inputs[@]}"
    cp "$dir/install/include/sherpa-onnx/c-api/c-api.h" "$fw/Headers/sherpa-onnx/c-api/"
    cat > "$fw/Modules/module.modulemap" <<'MAP'
framework module SherpaOnnxC {
  header "sherpa-onnx/c-api/c-api.h"
  export *
}
MAP
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>io.codemyriad.sherpa-onnx</string>
  <key>CFBundleName</key>
  <string>SherpaOnnxC</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleExecutable</key>
  <string>SherpaOnnxC</string>
  <key>CFBundleVersion</key>
  <string>$(pin sherpa-onnx-ios version)</string>
  <key>CFBundleShortVersionString</key>
  <string>1.13.7</string>
  <key>MinimumOSVersion</key>
  <string>$deployment_target</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>$supported</string>
  </array>
</dict>
</plist>
PLIST
}

make_framework "$work/os64" iPhoneOS
make_framework "$work/simulator_arm64" iPhoneSimulator

stage=$work/stage
rm -rf "$stage"
mkdir -p "$stage"
xcodebuild -create-xcframework \
    -framework "$work/os64/SherpaOnnxC.framework" \
    -framework "$work/simulator_arm64/SherpaOnnxC.framework" \
    -output "$stage/SherpaOnnxC.xcframework" > /dev/null
# xcodebuild lists the slices in no fixed order; sort them so the Info.plist, and so the checksum, is stable.
/usr/bin/python3 -I -c 'import plistlib, sys
with open(sys.argv[1], "rb") as f: info = plistlib.load(f)
info["AvailableLibraries"].sort(key=lambda library: library["LibraryIdentifier"])
with open(sys.argv[1], "wb") as f: plistlib.dump(info, f, sort_keys=True)' "$stage/SherpaOnnxC.xcframework/Info.plist"

# One time and one order for every entry, so the zip depends only on the bytes inside.
find "$stage" -exec touch -h -t 198001010000 {} +
(cd "$stage" && find SherpaOnnxC.xcframework | sort | zip -q -X -y -@ "$work/$artifact")

rm -rf "$out"
mkdir -p "$out/dist"
cp -R "$stage/SherpaOnnxC.xcframework" "$out/"
cp -R "$ort" "$out/"
cp "$work/$artifact" "$out/dist/"
checksum=$(swift package compute-checksum "$out/dist/$artifact")
printf '%s\n' "$checksum" > "$out/dist/checksum.txt"
printf 'SherpaOnnxC.xcframework: %s\nzip: %s\nchecksum: %s\n' "$out/SherpaOnnxC.xcframework" "$out/dist/$artifact" "$checksum"
