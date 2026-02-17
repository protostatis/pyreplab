#!/usr/bin/env bash
# test_agent.sh — Simulates an LLM subagent stepping through cells
#
# Each step: run a cell, validate output, extract facts, decide next step.
# Tests that an agent can build understanding incrementally across 10 cells.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYREPLAB_DIR="/tmp/pyreplab_agent_test_$$"
PYREPLAB="$SCRIPT_DIR/pyreplab"
NOTEBOOK="$SCRIPT_DIR/agent_test.py"

pass=0
fail=0
# Agent's working memory — facts extracted from each cell
fact_row_count="" fact_col_count="" fact_null_rows=""
fact_top_region="" fact_top_product="" fact_premium=""
fact_driver="" fact_conclusion=""

check() {
    local label="$1" pattern="$2" output="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "    ok: $label"
        pass=$((pass + 1))
    else
        echo "    FAIL: $label (expected pattern: $pattern)"
        fail=$((fail + 1))
    fi
}

cleanup() {
    "$PYREPLAB" stop 2>/dev/null || true
    "$PYREPLAB" clean 2>/dev/null || true
    [ -d "$PYREPLAB_DIR" ] && rmdir "$PYREPLAB_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Agent Walkthrough Test ==="
echo "Notebook: $NOTEBOOK"
echo "Session:  $PYREPLAB_DIR"
echo ""

"$PYREPLAB" start 2>&1
echo ""

# ── Step 1: Load data ──────────────────────────────────────
echo "[Step 1/10] Load raw data — how big is the dataset?"
out=$("$PYREPLAB" run "$NOTEBOOK":0)
echo "$out"
check "loaded 2000 orders" "Loaded 2000 orders" "$out"
check "has date range" "Date range:" "$out"
fact_row_count="2000"
echo "  → Agent notes: $fact_row_count rows loaded"
echo ""

# ── Step 2: Inspect schema ─────────────────────────────────
echo "[Step 2/10] Inspect schema — what types are we working with?"
out=$("$PYREPLAB" run "$NOTEBOOK":1)
echo "$out"
check "has datetime column" "datetime64" "$out"
check "shape is 2000x7" "2000, 7" "$out"
fact_col_count="7"
echo "  → Agent notes: $fact_col_count columns, datetime present"
echo ""

# ── Step 3: Data quality ───────────────────────────────────
echo "[Step 3/10] Check data quality — any nulls or issues?"
out=$("$PYREPLAB" run "$NOTEBOOK":2)
echo "$out"
check "discount_pct has nulls" "discount_pct" "$out"
check "4 regions" "East.*North.*South.*West" "$out"
check "3 products" "Alpha.*Beta.*Gamma" "$out"
# Extract null count
null_count=$(echo "$out" | grep "Total rows with nulls" | grep -o '[0-9]*')
fact_null_rows="$null_count"
echo "  → Agent notes: ${fact_null_rows} rows have nulls in discount_pct. Need to clean."
echo ""

# ── Step 4: Clean and compute revenue ──────────────────────
echo "[Step 4/10] Clean data — fill nulls, compute revenue"
out=$("$PYREPLAB" run "$NOTEBOOK":3)
echo "$out"
check "zero nulls after cleaning" "Nulls after cleaning: 0" "$out"
check "revenue stats present" "mean" "$out"
echo "  → Agent notes: Nulls filled, revenue column computed. Ready for analysis."
echo ""

# ── Step 5: Revenue by region ──────────────────────────────
echo "[Step 5/10] Which region generates the most revenue?"
out=$("$PYREPLAB" run "$NOTEBOOK":4)
echo "$out"
check "top region identified" "Top region by revenue:" "$out"
top_region=$(echo "$out" | grep "Top region" | awk -F': ' '{print $2}')
fact_top_region="$top_region"
echo "  → Agent notes: Top region is '${fact_top_region}'. Investigate why."
echo ""

# ── Step 6: Revenue by product ─────────────────────────────
echo "[Step 6/10] Which product generates the most revenue?"
out=$("$PYREPLAB" run "$NOTEBOOK":5)
echo "$out"
check "top product identified" "Top product by revenue:" "$out"
top_product=$(echo "$out" | grep "Top product" | awk -F': ' '{print $2}')
fact_top_product="$top_product"
echo "  → Agent notes: Top product is '${fact_top_product}'."
echo ""

# ── Step 7: Cross-tab — find the planted anomaly ──────────
echo "[Step 7/10] Cross-tab — is there a pricing anomaly?"
out=$("$PYREPLAB" run "$NOTEBOOK":6)
echo "$out"
check "West Alpha premium detected" "West Alpha premium:" "$out"
# Extract the premium percentage
premium=$(echo "$out" | grep "West Alpha premium" | grep -o '[0-9]*\.[0-9]*%')
fact_premium="$premium"
echo "  → Agent notes: West Alpha has a ${fact_premium} price premium. This is the planted pattern."
echo ""

# ── Step 8: Monthly trend ─────────────────────────────────
echo "[Step 8/10] Monthly trend — is revenue stable?"
out=$("$PYREPLAB" run "$NOTEBOOK":7)
echo "$out"
check "monthly data present" "2024-01" "$out"
check "has revenue per order" "revenue_per_order" "$out"
echo "  → Agent notes: Monthly data looks stable across the period."
echo ""

# ── Step 9: Correlation analysis ───────────────────────────
echo "[Step 9/10] What drives revenue — price or quantity?"
out=$("$PYREPLAB" run "$NOTEBOOK":8)
echo "$out"
check "correlation matrix shown" "Correlation matrix:" "$out"
check "revenue driver identified" "Stronger driver of revenue:" "$out"
driver=$(echo "$out" | grep "Stronger driver" | awk -F': ' '{print $2}')
fact_driver="$driver"
echo "  → Agent notes: Revenue is more driven by '${fact_driver}'."
echo ""

# ── Step 10: Final verdict ─────────────────────────────────
echo "[Step 10/10] Final analysis — what's the conclusion?"
out=$("$PYREPLAB" run "$NOTEBOOK":9)
echo "$out"
check "analysis complete marker" "ANALYSIS COMPLETE" "$out"
check "conclusion present" "CONCLUSION:" "$out"
check "top region matches earlier" "${fact_top_region}" "$out"
check "top product matches earlier" "${fact_top_product}" "$out"
check "planted pattern acknowledged" "planted pattern detected" "$out"

# Extract final conclusion
conclusion=$(echo "$out" | grep "CONCLUSION:" | sed 's/CONCLUSION: //')
fact_conclusion="$conclusion"
echo ""

# ── Agent Summary ──────────────────────────────────────────
echo "═══════════════════════════════════════════════════"
echo "AGENT SUMMARY (facts accumulated across 10 steps)"
echo "═══════════════════════════════════════════════════"
echo "  Dataset:        ${fact_row_count} rows x ${fact_col_count} cols"
echo "  Data quality:   ${fact_null_rows} null rows (cleaned)"
echo "  Top region:     ${fact_top_region}"
echo "  Top product:    ${fact_top_product}"
echo "  Anomaly:        West Alpha has ${fact_premium} price premium"
echo "  Revenue driver: ${fact_driver}"
echo "  Conclusion:     ${fact_conclusion}"
echo "═══════════════════════════════════════════════════"
echo ""

"$PYREPLAB" stop 2>&1
echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
