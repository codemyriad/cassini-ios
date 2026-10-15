# shellcheck shell=bash
# Shared helpers for the native runtime scripts (the iOS counterpart of cassini-android's). Source it from the
# repository root:
#   . scripts/native-common.sh

# pin <entry name> <field>: print one field of scripts/native-dependencies.json.
pin() {
    /usr/bin/python3 -I -c 'import json, sys
entry = next(e for e in json.load(open(sys.argv[1])) if e["name"] == sys.argv[2])
print(entry[sys.argv[3]])' scripts/native-dependencies.json "$1" "$2"
}

# pins_with <field>: print the names of the entries that have that field, in lock order.
pins_with() {
    /usr/bin/python3 -I -c 'import json, sys
for e in json.load(open(sys.argv[1])):
    if sys.argv[2] in e and e["name"] not in ("sherpa-onnx-ios",): print(e["name"])' scripts/native-dependencies.json "$1"
}

# sha256_of <file>: print the file's SHA-256.
sha256_of() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

# fetch <url> <sha256> <destination>: download unless the destination already has that SHA-256, then check it.
fetch() {
    local url="$1" sha="$2" out="$3"
    if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$sha" ]; then return; fi
    mkdir -p "$(dirname "$out")"
    curl --fail --location --retry 3 --silent --show-error "$url" -o "$out.part"
    if [ "$(sha256_of "$out.part")" != "$sha" ]; then
        printf '%s has SHA-256 %s, the pin is %s.\n' "$url" "$(sha256_of "$out.part")" "$sha" >&2
        rm -f "$out.part"
        return 1
    fi
    mv "$out.part" "$out"
}

# Where the local runtime lives. Package.swift reads these paths when CASSINI_SHERPA_LOCAL is set; .tools/ is
# gitignored.
sherpa_local=.tools/sherpa
sherpa_xcframework=$sherpa_local/SherpaOnnxC.xcframework
onnxruntime_xcframework=$sherpa_local/onnxruntime.xcframework
