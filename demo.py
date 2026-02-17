#%% Load
import pandas as pd
import numpy as np

np.random.seed(42)
n = 1000

orders = pd.DataFrame({
    "order_id": range(1, n + 1),
    "customer_id": np.random.randint(1, 201, n),
    "product": np.random.choice(["Widget", "Gadget", "Doohickey", "Thingamajig"], n),
    "quantity": np.random.randint(1, 20, n),
    "unit_price": np.random.uniform(5, 200, n).round(2),
    "order_date": pd.date_range("2024-01-01", periods=n, freq="6h"),
})
orders["revenue"] = orders["quantity"] * orders["unit_price"]
print(f"orders: {orders.shape}")
print(orders.head())

#%% Clean
orders["month"] = orders["order_date"].dt.to_period("M")
orders["is_bulk"] = orders["quantity"] >= 10
dupes = orders.duplicated(subset=["customer_id", "product", "order_date"]).sum()
print(f"duplicate rows: {dupes}")
print(orders.dtypes)

#%% Aggregate
monthly = (
    orders.groupby(["month", "product"])
    .agg(total_revenue=("revenue", "sum"), avg_qty=("quantity", "mean"), order_count=("order_id", "count"))
    .reset_index()
)
print(monthly)

#%% Top customers
top = (
    orders.groupby("customer_id")
    .agg(lifetime_revenue=("revenue", "sum"), total_orders=("order_id", "count"))
    .sort_values("lifetime_revenue", ascending=False)
    .head(10)
)
top["avg_order_value"] = top["lifetime_revenue"] / top["total_orders"]
print(top)

#%% Pivot
pivot = orders.pivot_table(
    index="month", columns="product", values="revenue", aggfunc="sum"
).round(2)
pivot["total"] = pivot.sum(axis=1)
print(pivot)
