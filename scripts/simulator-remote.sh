#!/bin/sh
# Builds the app on the Mac, runs it in an iOS Simulator with a Cassini document
# imported, and copies a screenshot back. Usage: simulator-remote.sh [file.opus] [out.png]
set -eu
host="${CASSINI_MAC:-ghyston}"
here="$(cd "$(dirname "$0")/.." && pwd)"
doc="${1:-$here/../cassini-format/spec/conformance/opus/016-two-transcripts.opus}"
out="${2:-$here/build/screenshot.png}"
device="${CASSINI_SIMULATOR:-iPhone 13}"
ssh "$host" 'mkdir -p ~/dev/cassini-ios-build'
rsync -az --delete --exclude .build --exclude .git --exclude build "$here/" "$host:dev/cassini-ios/"
scp -q "$doc" "$host:dev/cassini-ios-build/import.opus"
ssh "$host" "set -e; export PATH=\$HOME/.local/xcodegen/bin:\$PATH; cd ~/dev/cassini-ios && xcodegen -q
xcodebuild -quiet -project Cassini.xcodeproj -scheme Cassini -sdk iphonesimulator -destination 'platform=iOS Simulator,name=$device' -derivedDataPath ~/dev/cassini-ios-build/dd build
xcrun simctl boot '$device' 2>/dev/null || true
xcrun simctl bootstatus '$device' -b >/dev/null
xcrun simctl terminate '$device' org.cassini.ios 2>/dev/null || true
xcrun simctl uninstall '$device' org.cassini.ios
xcrun simctl install '$device' ~/dev/cassini-ios-build/dd/Build/Products/Debug-iphonesimulator/Cassini.app
SIMCTL_CHILD_CASSINI_IMPORT=\$HOME/dev/cassini-ios-build/import.opus xcrun simctl launch '$device' org.cassini.ios >/dev/null
sleep 6
xcrun simctl io '$device' screenshot ~/dev/cassini-ios-build/screenshot.png >/dev/null 2>&1"
mkdir -p "$(dirname "$out")"
scp -q "$host:dev/cassini-ios-build/screenshot.png" "$out"
echo "$out"
