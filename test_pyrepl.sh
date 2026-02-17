#!/usr/bin/env bash
# test_pyrepl — End-to-end tests for pyrepl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYREPL_DIR="/tmp/pyrepl_test_$$"
PYREPL="$SCRIPT_DIR/pyrepl"

pass=0
fail=0

assert_output() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $label"
        pass=$((pass + 1))
    else
        echo "  FAIL: $label"
        echo "    expected: $(printf '%q' "$expected")"
        echo "    actual:   $(printf '%q' "$actual")"
        fail=$((fail + 1))
    fi
}

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" -eq "$expected" ]; then
        echo "  PASS: $label"
        pass=$((pass + 1))
    else
        echo "  FAIL: $label (expected exit $expected, got $actual)"
        fail=$((fail + 1))
    fi
}

cleanup() {
    "$PYREPL" stop 2>/dev/null || true
    "$PYREPL" clean 2>/dev/null || true
    [ -d "$PYREPL_DIR" ] && rmdir "$PYREPL_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== pyrepl test suite ==="
echo "session dir: $PYREPL_DIR"
echo ""

# Start server
echo "[1] Start server"
"$PYREPL" start 2>&1
echo ""

# Basic execution
echo "[2] Basic execution"
out=$("$PYREPL" run 'print("hello")')
assert_output "print output" "hello" "$out"
echo ""

# Persistence across commands
echo "[3] Persistence"
"$PYREPL" run 'x = 42' >/dev/null
out=$("$PYREPL" run 'print(x)')
assert_output "variable persists" "42" "$out"
echo ""

# Multi-line code
echo "[4] Multi-line code"
out=$("$PYREPL" run 'for i in range(3):
    print(i)')
assert_output "for loop output" "$(printf '0\n1\n2')" "$out"
echo ""

# Error handling
echo "[5] Error handling"
err_out=$("$PYREPL" run '1/0' 2>&1) && rc=0 || rc=$?
assert_exit "non-zero exit on error" 1 "$rc"
echo "$err_out" | grep -q "ZeroDivisionError" && {
    echo "  PASS: traceback contains ZeroDivisionError"
    pass=$((pass + 1))
} || {
    echo "  FAIL: traceback missing ZeroDivisionError"
    echo "    got: $err_out"
    fail=$((fail + 1))
}
echo ""

# Namespace survives errors
echo "[6] Namespace survives errors"
out=$("$PYREPL" run 'print(x)')
assert_output "x still 42 after error" "42" "$out"
echo ""

# Session files cleaned up between commands
echo "[7] Session file cleanup"
"$PYREPL" run 'print("cleanup test")' >/dev/null
[ ! -f "$PYREPL_DIR/done" ] && [ ! -f "$PYREPL_DIR/output.json" ] && {
    echo "  PASS: session files cleaned after read"
    pass=$((pass + 1))
} || {
    echo "  FAIL: stale session files remain"
    fail=$((fail + 1))
}
echo ""

# Display limits — pandas rows
echo "[8] Pandas row truncation (max_rows=50)"
out=$("$PYREPL" run 'import pandas as pd; df = pd.DataFrame({"x": range(200)}); print(df)')
line_count=$(echo "$out" | wc -l | tr -d ' ')
echo "$out" | grep -q '\.\.\.' && {
    echo "  PASS: large DataFrame is truncated with ... ($line_count lines)"
    pass=$((pass + 1))
} || {
    echo "  FAIL: expected ... in truncated output ($line_count lines)"
    fail=$((fail + 1))
}
echo ""

# Display limits — pandas columns
echo "[9] Pandas column truncation (max_cols=20)"
out=$("$PYREPL" run 'import pandas as pd; df = pd.DataFrame({f"col_{i}": [i] for i in range(40)}); print(df)')
echo "$out" | grep -q '\.\.\.' && {
    echo "  PASS: wide DataFrame is truncated with ..."
    pass=$((pass + 1))
} || {
    echo "  FAIL: expected ... in truncated output"
    fail=$((fail + 1))
}
echo ""

# Display limits — numpy
echo "[10] Numpy array truncation"
out=$("$PYREPL" run 'import numpy as np; print(np.arange(500))')
echo "$out" | grep -q '\.\.\.' && {
    echo "  PASS: large array is truncated with ..."
    pass=$((pass + 1))
} || {
    echo "  FAIL: expected ... in truncated output"
    fail=$((fail + 1))
}
echo ""

# Run cells from a .py file
echo "[11] Run .py file with #%% cells"
NOTEBOOK="$PYREPL_DIR/test_notebook.py"
cat > "$NOTEBOOK" <<'PYEOF'
#%% Setup
msg = "from cell 0"
#%% Compute
result = 2 + 2
#%% Report
print(f"{msg}, result={result}")
PYEOF

# Run all cells
out=$("$PYREPL" run "$NOTEBOOK")
assert_output "run all cells" "from cell 0, result=4" "$out"

# Run single cell by index
"$PYREPL" run 'msg = "reset"' >/dev/null
out=$("$PYREPL" run "${NOTEBOOK}:0")
"$PYREPL" run "${NOTEBOOK}:1" >/dev/null
out=$("$PYREPL" run "${NOTEBOOK}:2")
assert_output "run cell by index" "from cell 0, result=4" "$out"
rm -f "$NOTEBOOK"
echo ""

# Stdin
echo "[12] Read from stdin"
out=$(echo 'print("from stdin")' | "$PYREPL" run)
assert_output "stdin input" "from stdin" "$out"
echo ""

# Status check
echo "[13] Status check"
"$PYREPL" status >/dev/null && {
    echo "  PASS: status reports running"
    pass=$((pass + 1))
} || {
    echo "  FAIL: status reports not running"
    fail=$((fail + 1))
}
echo ""

# Stop server
echo "[14] Stop server"
"$PYREPL" stop 2>&1
echo ""

# Summary
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
