#!/bin/bash
# Workflow boundary: cleanup must wait for the test owner, even if its step shell was cancelled.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
owner_file="${CASSINI_GATE_OWNER_FILE:?the workflow must provide a run-specific owner file}"
case "${1:-}" in
    run)
        "$root/scripts/test.sh" clean
        if [ -x "$HOME/bin/heavy-run" ]; then
            exec "$HOME/bin/heavy-run" "$root/scripts/simulator-gate.sh" owner
        fi
        exec "$root/scripts/simulator-gate.sh" owner
        ;;
    owner)
        # exec preserves this PID through the test script; the host-slot wrapper has a different PID.
        printf '%s\n' "$$" > "$owner_file"
        exec "$root/scripts/test.sh" all
        ;;
    clean)
        if [ -s "$owner_file" ]; then
            owner=$(cat "$owner_file")
            case "$owner" in ''|*[!0-9]*) echo "invalid simulator test owner PID" >&2; exit 1 ;; esac
            if kill -0 "$owner" 2>/dev/null; then
                # A completed run can leave a stale file. Fail closed on PID reuse, rather than signal another job.
                command_line=$(ps -p "$owner" -o command= || true)
                case "$command_line" in
                    *"$root/scripts/test.sh all"*) ;;
                    '') ;; # It may have exited naturally between kill -0 and ps.
                    *) echo "simulator test owner PID no longer identifies this run: $owner" >&2; exit 1 ;;
                esac
                if [ -n "$command_line" ]; then
                    echo "Stopping simulator test owner $owner before clone cleanup"
                    kill -TERM "$owner" 2>/dev/null || true
                    # kqueue exit event, not a fixed delay. On timeout, leave clones in place and fail cleanup.
                    /usr/bin/python3 -I "$root/scripts/test-events.py" watch "$owner" /dev/null 60 60
                    echo "Simulator test owner $owner exited before clone cleanup"
                fi
            fi
            # Only this run's marker; no other runner service or attempt shares it.
            /usr/bin/python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)' "$owner_file"
        fi
        exec "$root/scripts/test.sh" clean
        ;;
    *) echo "usage: simulator-gate.sh run|owner|clean" >&2; exit 2 ;;
esac
