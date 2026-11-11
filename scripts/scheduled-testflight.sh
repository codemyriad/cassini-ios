#!/bin/bash
# Dedicated, clean control clone only; install from main after coordinator review.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! git fetch origin main:refs/remotes/origin/main || ! git merge --ff-only origin/main; then
  echo '[iOS] daily test release failed: cannot update dedicated control clone to main' >&2
  echo '[iOS] daily test release failed: cannot update dedicated control clone to main' >> "$HOME/dev/cassini-coordination/DAILY-TEST-RELEASES-IOS.log"
  exit 1
fi
exec /usr/bin/python3 scripts/daily-testflight.py --scheduled --config "$HOME/.config/cassini/ios-daily-release.json"
