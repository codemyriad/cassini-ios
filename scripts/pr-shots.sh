#!/bin/bash
# Local W0.8 before/after renders; this command never accesses GitHub.
set -euo pipefail
exec python3 "$(dirname "$0")/pr-shots-local.py" "$@"
