#!/bin/bash
# Slot check, release mutex and any update happen together inside the controller.
set -euo pipefail
cd "$(dirname "$0")/.."
exec /usr/bin/python3 scripts/daily-testflight.py --scheduled --refresh-control --config "$HOME/.config/cassini/ios-daily-release.json"
