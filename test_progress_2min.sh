#!/usr/bin/env bash
# test_progress_2min.sh — 2-minute progress-streaming soak test
#
# Runs a loop that prints "iter N" for ~2 minutes (2400 iters x 50ms), the
# worst case for the old behavior: no output at all until the command
# completes. Verifies:
#   1. Progress lines stream to stderr during `run` AND `wait` polling
#   2. iter counts never decrease across snapshots (monotonic liveness)
#   3. The command completes and delivers its full final output (exit 0)
#   4. The total run takes at least ~2 minutes (it really is a long loop)
#
# Usage: bash test_progress_2min.sh   (~2.2 minutes)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR="$SCRIPT_DIR/pyreplab"
export PYREPLAB_STAMP=0
SESSION="$(mktemp -d /tmp/pyreplab_2min_XXXX)"
export PYREPLAB_DIR="$SESSION"
export PYREPLAB_TIMEOUT=5

PIDS=()
cleanup() {
    for p in ${PIDS[@]+"${PIDS[@]}"}; do
        kill -9 "$p" 2>/dev/null || true
    done
    for p in $(pgrep -f "pyreplab.py --session-dir $SESSION" 2>/dev/null || true); do
        kill -9 "$p" 2>/dev/null || true
    done
    rm -rf "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
check() {
    local label="$1" result="$2" detail="${3:-}"
    if [ "$result" = "ok" ]; then
        echo "  PASS: $label"
        pass=$((pass + 1))
    else
        echo "  FAIL: $label — $detail"
        fail=$((fail + 1))
    fi
}

echo "=== 2-minute progress-streaming soak test ==="
echo "session: $SESSION  timeout: ${PYREPLAB_TIMEOUT}s"
"$PR" start >/dev/null 2>&1
PIDS+=("$(cat "$SESSION/pyreplab.pid")")

t0=$(date +%s)
echo "[run] submitting 2400-iteration printing loop (~2 min)..."
out=$("$PR" run 'import time
for i in range(2400):
    print("iter %d" % i)
    time.sleep(0.05)' 2>&1)
rc=$?
echo "  run rc=$rc (expected 2 after ${PYREPLAB_TIMEOUT}s timeout)"
echo "  run-phase progress lines: $(echo "$out" | grep -c 'pyreplab: progress')"

# Drain: repeatedly call wait (2s poll each) until the command completes
last=""; wrc=2; rounds=0; progress=""
while [ "$wrc" -eq 2 ] && [ "$rounds" -lt 120 ]; do
    rounds=$((rounds + 1))
    errf="$(mktemp)"
    last=$("$PR" wait 2>"$errf"); wrc=$?
    progress="$progress $(cat "$errf")"
    rm -f "$errf"
done
t1=$(date +%s)
elapsed=$((t1 - t0))
echo "  drained after $rounds wait calls, final rc=$wrc, total elapsed=${elapsed}s"

all_progress="$out $progress"
nlines=$(echo "$all_progress" | grep -c 'pyreplab: progress')
[ "$nlines" -ge 20 ] \
    && check "progress lines streamed during the whole run ($nlines lines)" ok \
    || check "progress lines streamed during the whole run" fail "only $nlines lines"

# Monotonic liveness: iter counts in progress tails must never decrease
bad=""
iters=$(echo "$all_progress" | grep -oE 'iter [0-9]+' | awk '{print $2}')
prev=""
for n in $iters; do
    if [ -n "$prev" ] && [ "$n" -lt "$prev" ]; then bad="iter went backwards: $prev -> $n"; break; fi
    prev="$n"
done
[ -z "$bad" ] && [ -n "$prev" ] \
    && check "iter counts monotonic across snapshots (up to iter $prev)" ok \
    || check "iter counts monotonic across snapshots" fail "${bad:-no iters seen}"

[ "$rc" -eq 2 ] \
    && check "run returned early (exit 2) instead of blocking" ok \
    || check "run returned early (exit 2) instead of blocking" fail "rc=$rc"

[ "$elapsed" -ge 110 ] \
    && check "loop really ran ~2 minutes (${elapsed}s)" ok \
    || check "loop really ran ~2 minutes" fail "only ${elapsed}s"

[ "$wrc" -eq 0 ] && echo "$last" | grep -q "iter 2399" \
    && check "final output delivered intact (last line: $(echo "$last" | tail -1))" ok \
    || check "final output delivered intact" fail "rc=$wrc last=[$last]"

# Session must be clean afterwards (no leftover handshake files)
leftovers=""
for f in done output.json pending_id pending_start progress.json; do
    [ -f "$SESSION/$f" ] && leftovers="$leftovers $f"
done
[ -z "$leftovers" ] \
    && check "session files cleaned after completion" ok \
    || check "session files cleaned after completion" fail "left:$leftovers"

"$PR" stop >/dev/null 2>&1
echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
