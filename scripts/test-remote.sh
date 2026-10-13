#!/bin/sh
# Runs scripts/test.sh on the Mac named by CASSINI_MAC, over SSH: scripts/test-remote.sh [tier] [xcodebuild arguments].
# The tiers are scripts/test.sh's fast, app, ui and all (default all, as there; changed needs git, which the copy
# lacks): the string catalog check and swift test, then xcodegen, the build for testing and the hosted and UI tests on
# simulator clones. Without CASSINI_MAC the same tier runs here. The remote Mac needs Xcode 26 or newer, xcodegen and
# the iOS simulators (iPhone 17, iPad Pro 13-inch (M5)); the script checks the Xcode version before it copies anything.
# The tree is synced to ~/dev/cassini-ios there, with ../cassini-format beside it so the conformance vectors cannot be
# skipped (CASSINI_CONFORMANCE_REQUIRED=1). Builds and caches stay on the remote Mac between runs (DerivedData.noindex,
# .build and .test-cache under ~/dev/cassini-ios).
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${CASSINI_MAC:-}" ]; then
    CASSINI_CONFORMANCE_REQUIRED=1 exec "$here/scripts/test.sh" "$@"
fi
host="$CASSINI_MAC"
tier="${1:-all}"; [ $# -gt 0 ] && shift

version=$(ssh "$host" 'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; xcodebuild -version' | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
if [ "${version:-0}" -lt 26 ]; then
    echo "error: $host has Xcode ${version:-?}; Cassini needs Xcode 26 or newer" >&2
    exit 1
fi

ssh "$host" 'mkdir -p ~/dev'
rsync -az --delete --exclude .build --exclude .git --exclude DerivedData --exclude DerivedData.noindex --exclude .test-cache --exclude '*.xcodeproj' \
    "$here/" "$host:dev/cassini-ios/"
format="$here/../cassini-format"
# A worktree sits deeper than the checkout that cassini-format is beside.
[ -d "$format" ] || format="$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")/../cassini-format"
rsync -az --delete --exclude .git --exclude site --exclude node_modules "$format/" "$host:dev/cassini-format/"
quoted=""
for argument in "$@"; do quoted="$quoted '$(printf '%s' "$argument" | sed "s/'/'\\\\''/g")'"; done
ssh "$host" "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; cd ~/dev/cassini-ios && CASSINI_CONFORMANCE_REQUIRED=1 scripts/test.sh $tier$quoted"
