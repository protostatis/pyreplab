# %% [0] Cell 0
x = 1
print(f"cell 0: x={x}")

# %% [1] Cell 1 - fast
y = 2
print(f"cell 1: y={y}")

# %% [2] Cell 2 - slow (triggers wait)
import time
time.sleep(60)
z = 3
print(f"cell 2: z={z} (after 60s sleep)")

# %% [3] Cell 3
print(f"cell 3: x={x}, y={y}, z={z}, all cells ran!")
