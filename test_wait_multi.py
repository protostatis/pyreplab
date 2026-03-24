# %% [0] Load and prepare data
import time
import math
import random
random.seed(42)

n = 50000
data = [{"id": i, "value": random.gauss(100, 25), "group": chr(65 + i % 5)} for i in range(n)]

print(f"Loaded {len(data)} records")
print(f"Groups: {sorted(set(r['group'] for r in data))}")
print(f"Sample rows:")
for r in data[:10]:
    print(f"  id={r['id']:>5}  group={r['group']}  value={r['value']:>8.2f}")
print(f"  ...")

# %% [1] Heavy aggregation (triggers wait)
time.sleep(90)
groups = {}
for r in data:
    groups.setdefault(r["group"], []).append(r["value"])
stats = {}
for g, vals in groups.items():
    n_g = len(vals)
    mean = sum(vals) / n_g
    std = math.sqrt(sum((v - mean)**2 for v in vals) / n_g)
    mn, mx = min(vals), max(vals)
    stats[g] = {"mean": mean, "std": std, "min": mn, "max": mx, "n": n_g}

print(f"{'group':>6} {'n':>6} {'mean':>8} {'std':>8} {'min':>8} {'max':>8}")
print(f"{'-----':>6} {'-----':>6} {'------':>8} {'------':>8} {'------':>8} {'------':>8}")
for g in sorted(stats):
    s = stats[g]
    print(f"{g:>6} {s['n']:>6} {s['mean']:>8.2f} {s['std']:>8.2f} {s['min']:>8.2f} {s['max']:>8.2f}")

# %% [2] Outlier detection (triggers wait)
time.sleep(120)
overall_mean = sum(r["value"] for r in data) / len(data)
overall_std = math.sqrt(sum((r["value"] - overall_mean)**2 for r in data) / len(data))
threshold = 3 * overall_std
outliers = [r for r in data if abs(r["value"] - overall_mean) > threshold]

print(f"Overall mean={overall_mean:.2f}  std={overall_std:.2f}  threshold=±{threshold:.2f}")
print(f"Found {len(outliers)} outliers ({len(outliers)/len(data)*100:.2f}%)")
print()
print(f"{'id':>6} {'group':>6} {'value':>8} {'deviation':>10}")
print(f"{'-----':>6} {'-----':>6} {'------':>8} {'---------':>10}")
for r in outliers[:15]:
    dev = (r["value"] - overall_mean) / overall_std
    print(f"{r['id']:>6} {r['group']:>6} {r['value']:>8.2f} {dev:>+10.2f}σ")
if len(outliers) > 15:
    print(f"  ... and {len(outliers) - 15} more")

# %% [3] Correlation matrix
pairs = [("value", "id")]
vals_by_group = {g: [r["value"] for r in data if r["group"] == g] for g in sorted(set(r["group"] for r in data))}
group_keys = sorted(vals_by_group.keys())

print("Cross-group correlation matrix:")
header = "       " + "".join(f"{g:>8}" for g in group_keys)
print(header)
for g1 in group_keys:
    row = f"  {g1}   "
    for g2 in group_keys:
        v1, v2 = vals_by_group[g1], vals_by_group[g2]
        min_len = min(len(v1), len(v2))
        m1, m2 = sum(v1[:min_len])/min_len, sum(v2[:min_len])/min_len
        cov = sum((a-m1)*(b-m2) for a, b in zip(v1[:min_len], v2[:min_len])) / min_len
        s1 = math.sqrt(sum((a-m1)**2 for a in v1[:min_len])/min_len)
        s2 = math.sqrt(sum((b-m2)**2 for b in v2[:min_len])/min_len)
        corr = cov/(s1*s2) if s1 and s2 else 0
        row += f"{corr:>8.4f}"
    print(row)

# %% [4] Model fitting (triggers wait)
time.sleep(90)
xs = [r["id"] for r in data]
ys = [r["value"] for r in data]
x_mean, y_mean = sum(xs)/len(xs), sum(ys)/len(ys)
ss_xy = sum((x - x_mean)*(y - y_mean) for x, y in zip(xs, ys))
ss_xx = sum((x - x_mean)**2 for x in xs)
slope = ss_xy / ss_xx if ss_xx else 0
intercept = y_mean - slope * x_mean
residuals = [(y - (slope*x + intercept))**2 for x, y in zip(xs, ys)]
rmse = math.sqrt(sum(residuals) / len(residuals))
ss_res = sum(residuals)
ss_tot = sum((y - y_mean)**2 for y in ys)
r_squared = 1 - ss_res/ss_tot if ss_tot else 0

print("Linear regression: value ~ id")
print(f"  slope     = {slope:.8f}")
print(f"  intercept = {intercept:.4f}")
print(f"  RMSE      = {rmse:.4f}")
print(f"  R²        = {r_squared:.6f}")
print()
print("Residual distribution:")
res_vals = [y - (slope*x + intercept) for x, y in zip(xs, ys)]
pcts = [0, 10, 25, 50, 75, 90, 100]
res_sorted = sorted(res_vals)
for p in pcts:
    idx = min(int(len(res_sorted) * p / 100), len(res_sorted) - 1)
    print(f"  P{p:<3} = {res_sorted[idx]:>+8.2f}")

# %% [5] Final summary
# All variables below (data, stats, outliers, rmse, r_squared, slope) are
# defined in cells 0-4. If any cell failed, the run would have exited with
# rc=1 before reaching here, so these are guaranteed to exist.
print("=" * 50)
print("PIPELINE COMPLETE — all cells executed")
print("=" * 50)
print(f"  Records:    {len(data)}")
print(f"  Groups:     {len(stats)} ({', '.join(sorted(stats.keys()))})")
print(f"  Outliers:   {len(outliers)} ({len(outliers)/len(data)*100:.2f}%)")
print(f"  Model RMSE: {rmse:.4f}")
print(f"  Model R²:   {r_squared:.6f}")
print(f"  Slope:      {slope:.8f}")
print()
print("Group summary:")
for g in sorted(stats):
    s = stats[g]
    print(f"    {g}: mean={s['mean']:.2f} std={s['std']:.2f} n={s['n']}")
