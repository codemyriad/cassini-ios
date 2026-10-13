#!/bin/sh
# Runs scripts/test.sh on another Mac over SSH: scripts/test-remote.sh [fast|app|ui|all] [xcodebuild test arguments].
# The default tier is fast (the Swift package tests); app, ui and all need Xcode, xcodegen and the iOS simulators there.
# ../cassini-format is synced alongside so the conformance vectors cannot be skipped. Builds and caches stay on the
# remote Mac between runs (~/dev/cassini-ios/DerivedData.noindex, .build and .test-cache).
set -eu
host="${CASSINI_MAC:-ghyston}"
here="$(cd "$(dirname "$0")/.." && pwd)"
tier="${1:-fast}"; [ $# -gt 0 ] && shift
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
