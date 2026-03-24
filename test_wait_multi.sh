#!/usr/bin/env bash
# test_wait_multi.sh — Tests whole-file run with external wait resuming cells
#
# Runs `pyreplab run test_wait_multi.py` (whole notebook). When a cell exceeds
# PYREPLAB_TIMEOUT, `run` exits 2. The test then calls `pyreplab wait` in a
# loop, which should auto-continue to the next cell each time the current one
# finishes. This mimics how an LLM agent would interact with pyreplab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYREPLAB_DIR="/tmp/pyreplab_wait_multi_$$"
export PYREPLAB_TIMEOUT=3
PYREPLAB="$SCRIPT_DIR/pyreplab"
NOTEBOOK="$SCRIPT_DIR/test_wait_multi.py"

pass=0
fail=0

check() {
    local label="$1" pattern="$2" output="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  ok: $label"
        pass=$((pass + 1))
    else
        echo "  FAIL: $label (expected pattern: $pattern)"
        fail=$((fail + 1))
    fi
}

cleanup() {
    "$PYREPLAB" stop 2>/dev/null || true
    "$PYREPLAB" clean 2>/dev/null || true
    [ -d "$PYREPLAB_DIR" ] && rmdir "$PYREPLAB_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Wait-Resume Whole-File Test ==="
echo "Notebook: $NOTEBOOK"
echo "Session:  $PYREPLAB_DIR"
echo "Timeout:  ${PYREPLAB_TIMEOUT}s (cells 1,2,4 sleep 90-120s)"
echo ""

"$PYREPLAB" start 2>&1
echo ""

# Run the whole notebook — should return exit 2 when cell 1 times out
echo "[run] pyreplab run $NOTEBOOK"
all_out=""
rc=0
out=$("$PYREPLAB" run "$NOTEBOOK" 2>&1) || rc=$?
all_out="$out"
echo "$out"
echo "[run exit: $rc]"
echo ""

# Keep calling wait until everything is done
wait_round=0
while [ "$rc" -eq 2 ]; do
    wait_round=$((wait_round + 1))
    echo "[wait $wait_round]"
    rc=0
    out=$("$PYREPLAB" wait 2>&1) || rc=$?
    all_out="$all_out
$out"
    echo "$out"
    echo "[wait $wait_round exit: $rc]"
    echo ""
done

echo "=== Completed after $wait_round wait calls ==="
echo ""

# Validate all cell output was collected across run + wait calls
check "cell 0 — loaded records"      "Loaded 50000 records"     "$all_out"
check "cell 0 — sample rows"         "Sample rows"              "$all_out"
check "cell 1 — group stats"         "group.*mean.*std"         "$all_out"
check "cell 1 — group A"             "A.*10000"                 "$all_out"
check "cell 2 — overall stats"       "Overall mean="            "$all_out"
check "cell 2 — outliers found"      "Found.*outliers"          "$all_out"
check "cell 2 — outlier table"       "deviation"                "$all_out"
check "cell 3 — correlation matrix"  "Cross-group correlation"  "$all_out"
check "cell 4 — regression"          "Linear regression"        "$all_out"
check "cell 4 — RMSE"                "RMSE"                     "$all_out"
check "cell 4 — residuals"           "Residual distribution"    "$all_out"
check "cell 5 — pipeline complete"   "PIPELINE COMPLETE"        "$all_out"
check "cell 5 — all groups"          "A, B, C, D, E"            "$all_out"
check "cell 5 — outlier count"       "Outliers:"                "$all_out"
check "cell 5 — model stats"         "Model RMSE"               "$all_out"

echo ""
"$PYREPLAB" stop 2>&1
echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
