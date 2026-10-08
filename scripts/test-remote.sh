#!/bin/sh
# Runs the Swift tests on a Mac over SSH. The Mac needs Xcode command line tools;
# ../cassini-format is synced alongside so the conformance vectors cannot be skipped.
set -eu
host="${CASSINI_MAC:-ghyston}"
here="$(cd "$(dirname "$0")/.." && pwd)"
ssh "$host" 'mkdir -p ~/dev'
rsync -az --delete --exclude .build --exclude .git "$here/" "$host:dev/cassini-ios/"
rsync -az --delete --exclude .git --exclude site --exclude node_modules "$here/../cassini-format/" "$host:dev/cassini-format/"
ssh "$host" 'cd ~/dev/cassini-ios && CASSINI_CONFORMANCE_REQUIRED=1 swift test'
