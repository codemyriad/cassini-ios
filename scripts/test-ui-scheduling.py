#!/usr/bin/env python3
"""Exercise the UI scheduling phases with simulated clone/process operations (no Xcode or simulators)."""
from pathlib import Path
import os, re, subprocess, tempfile
script = Path(__file__).with_name('test.sh').read_text()
def function(name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', script, re.M | re.S).group()
for budget, workers, retry in [(3, 2, ''), (1, 2, ''), (3, 9, '1'), (3, 2, 'ipad')]:
    with tempfile.TemporaryDirectory() as tmp:
        setup = r'''
set -euo pipefail
logs="$TMPDIR_CASE"; prefix=own; iphone_type=phone; ipad_type=pad; extra=()
selected_ui_tests() { printf 'Example/testA\nExample/testB\nExample/testIPadC\n'; }
step_start() { :; }; step_end() { :; }; reap_idle_clones() { :; }
wait_first_boot() { :; }; wait_for_room() { :; }; record_durations() { :; }
auto_workers() { echo "$BUDGET"; }; die() { echo "$*" >&2; exit 1; }
our_clones() { for f in "$logs"/*.state; do [ -f "$f" ] || continue; n=${f##*/}; n=${n%.state}; echo "$n $(cat "$f") $n"; done; }
clone_udid() { echo "$1"; }
boot() { echo Booted > "$logs/$1.state"; echo "boot $1" >> "$logs/trace"; }
run_limited() { shift 2; "$@"; }
xcrun() { [ "$1 $2" = 'simctl shutdown' ]; echo Shutdown > "$logs/$3.state"; echo "shutdown $3" >> "$logs/trace"; }
plan_shards() { awk -v n="$1" '{ print (NR-1)%n+1 "\t" $0 }'; }
planned_seconds() { cat >/dev/null; echo 1; }
test_on_retrying() {
  local log="$2" udid="$4"; shift 4
  echo "run $udid" >> "$logs/trace"
  if [ "$udid" = "own-iphone-$FAIL" ] || [ "$udid" = "own-$FAIL-1" ]; then echo 0 > "$log"; return 1; fi
  echo "$#" > "$log"
}
retry_killed_tests() {
  local k="$1" udid="$2"
  boot "$udid"
  echo "retry $udid" >> "$logs/trace"
  if [ "$k" = ipad ]; then echo 1 > "$logs/ui-$k-retry.log";
  else echo $(( (3 + WORKERS - k) / WORKERS )) > "$logs/ui-$k-retry.log"; fi
}
count_ran() { local total=0 f; for f in "$@"; do [ ! -f "$f" ] || total=$((total + $(cat "$f"))); done; echo "$total"; }
'''
        source = setup + '\n' + function('shutdown_ui_clones') + '\n' + function('tier_ui') + '\ntier_ui\n'
        env = dict(os.environ, TMPDIR_CASE=tmp, BUDGET=str(budget), WORKERS=str(min(budget, workers, 2)), FAIL=retry, CASSINI_UI_WORKERS=str(workers), CASSINI_UI_IPAD_AFTER='1')
        run = subprocess.run(['bash', '-c', source], env=env, text=True, capture_output=True)
        assert run.returncode == 0, (run.stdout, run.stderr)
        active = set()
        trace = Path(tmp, 'trace').read_text().splitlines()
        for line in trace:
            event, name = line.split()
            if event == 'boot': active.add(name)
            elif event == 'shutdown': active.discard(name)
            assert len(active) <= min(budget, workers, 2), trace
            assert not (any('ipad' in n for n in active) and any('iphone' in n for n in active)), trace
        assert not active, trace
        assert '3 of 3 ran on iPhone, 1 of 1 on iPad' in run.stdout, run.stdout
        print(f'PASS budget={budget}, requested={workers}, retry={retry or "none"}: all cases, phases isolated, clones stopped')
