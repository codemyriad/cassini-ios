#!/bin/bash
# Local W0.8 before/after renders; this command never accesses GitHub.
set -euo pipefail
exec /usr/bin/python3 "$(dirname "$0")/pr-shots-local.py" "$@"
