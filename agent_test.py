# %% [0] Cell 0: Load raw data
import pandas as pd
import numpy as np

np.random.seed(42)
n = 2000

regions = ["North", "South", "East", "West"]
products = ["Alpha", "Beta", "Gamma"]

df = pd.DataFrame({
    "order_id": range(1, n + 1),
    "region": np.random.choice(regions, n, p=[0.25, 0.25, 0.20, 0.30]),
    "product": np.random.choice(products, n, p=[0.4, 0.35, 0.25]),
    "units": np.random.randint(1, 50, n),
    "unit_price": np.random.uniform(10, 100, n).round(2),
    "discount_pct": np.random.choice([0, 5, 10, 15, 20, None], n, p=[0.4, 0.2, 0.15, 0.1, 0.05, 0.1]),
    "date": pd.date_range("2024-01-01", periods=n, freq="4h"),
})

# Plant a pattern: West region gets a 30% price premium on Alpha
mask = (df["region"] == "West") & (df["product"] == "Alpha")
df.loc[mask, "unit_price"] = df.loc[mask, "unit_price"] * 1.30

print(f"Loaded {len(df)} orders")
print(f"Columns: {list(df.columns)}")
print(f"Date range: {df['date'].min()} to {df['date'].max()}")

# %% [1] Cell 1: Inspect schema and types
print(df.dtypes)
print(f"\nShape: {df.shape}")
print(f"\nSample:")
print(df.head(10))

# %% [2] Cell 2: Check data quality
nulls = df.isnull().sum()
print("Null counts:")
print(nulls[nulls > 0])
print(f"\nTotal rows with nulls: {df.isnull().any(axis=1).sum()}")
print(f"\nUnique regions: {sorted(df['region'].unique())}")
print(f"Unique products: {sorted(df['product'].unique())}")
print(f"\nunit_price range: {df['unit_price'].min():.2f} - {df['unit_price'].max():.2f}")
print(f"units range: {df['units'].min()} - {df['units'].max()}")

# %% [3] Cell 3: Clean data — fill nulls and compute revenue
df["discount_pct"] = df["discount_pct"].fillna(0).astype(float)
df["revenue"] = df["units"] * df["unit_price"] * (1 - df["discount_pct"] / 100)
df["month"] = df["date"].dt.to_period("M")

print(f"Nulls after cleaning: {df.isnull().sum().sum()}")
print(f"Revenue stats:")
print(df["revenue"].describe())

# %% [4] Cell 4: Revenue by region
region_stats = (
    df.groupby("region")
    .agg(
        total_revenue=("revenue", "sum"),
        avg_order=("revenue", "mean"),
        order_count=("order_id", "count"),
    )
    .sort_values("total_revenue", ascending=False)
)
region_stats["revenue_share_pct"] = (region_stats["total_revenue"] / region_stats["total_revenue"].sum() * 100).round(1)
print(region_stats)
print(f"\nTop region by revenue: {region_stats.index[0]}")

# %% [5] Cell 5: Revenue by product
product_stats = (
    df.groupby("product")
    .agg(
        total_revenue=("revenue", "sum"),
        avg_price=("unit_price", "mean"),
        avg_units=("units", "mean"),
    )
    .sort_values("total_revenue", ascending=False)
)
print(product_stats)
print(f"\nTop product by revenue: {product_stats.index[0]}")

# %% [6] Cell 6: Cross-tab — region x product avg price
cross = df.pivot_table(index="region", columns="product", values="unit_price", aggfunc="mean").round(2)
print("Average unit price by region x product:")
print(cross)

# Check for the planted anomaly
west_alpha = cross.loc["West", "Alpha"]
overall_alpha = df.loc[df["product"] == "Alpha", "unit_price"].mean()
print(f"\nWest Alpha avg price: ${west_alpha:.2f}")
print(f"Overall Alpha avg price: ${overall_alpha:.2f}")
print(f"West Alpha premium: {((west_alpha / overall_alpha) - 1) * 100:.1f}%")

# %% [7] Cell 7: Monthly trend
monthly = (
    df.groupby("month")
    .agg(revenue=("revenue", "sum"), orders=("order_id", "count"))
    .reset_index()
)
monthly["month_num"] = range(len(monthly))
monthly["revenue_per_order"] = monthly["revenue"] / monthly["orders"]
print(monthly[["month", "revenue", "orders", "revenue_per_order"]])

# %% [8] Cell 8: Correlation analysis
numeric = df[["units", "unit_price", "discount_pct", "revenue"]].corr().round(3)
print("Correlation matrix:")
print(numeric)

price_rev_corr = df["unit_price"].corr(df["revenue"])
units_rev_corr = df["units"].corr(df["revenue"])
print(f"\nunit_price vs revenue correlation: {price_rev_corr:.3f}")
print(f"units vs revenue correlation: {units_rev_corr:.3f}")
print(f"\nStronger driver of revenue: {'units' if units_rev_corr > price_rev_corr else 'unit_price'}")

# %% [9] Cell 9: Final verdict
top_region = region_stats.index[0]
top_product = product_stats.index[0]
top_combo = (
    df.groupby(["region", "product"])["revenue"]
    .sum()
    .sort_values(ascending=False)
)
best_combo = top_combo.index[0]
best_revenue = top_combo.iloc[0]

stronger_driver = "units" if units_rev_corr > price_rev_corr else "unit_price"

print("=" * 50)
print("ANALYSIS COMPLETE")
print("=" * 50)
print(f"1. Top region: {top_region}")
print(f"2. Top product: {top_product}")
print(f"3. Best region-product combo: {best_combo[0]} x {best_combo[1]} (${best_revenue:,.2f})")
print(f"4. West Alpha has a price premium (planted pattern detected)")
print(f"5. Stronger revenue driver: {stronger_driver}")
print(f"CONCLUSION: {best_combo[0]}-{best_combo[1]} is the highest revenue segment at ${best_revenue:,.2f}")
