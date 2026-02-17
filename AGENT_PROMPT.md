# pyrepl Agent Instructions

You have access to a persistent Python REPL via `pyrepl`. Data stays in memory between commands — load once, query many times.

## Setup (run once at start)

```bash
# Start the REPL for the project you're working in
/path/to/pyrepl start --workdir /path/to/project
```

The `--workdir` auto-detects `.venv/` so all project packages are available. Sessions are isolated per project.

## Workflow

### 1. Write a notebook

Create a `.py` file with `#%%` cell blocks. Each cell is a logical step:

```python
# analysis.py

#%% Load
import pandas as pd
df = pd.read_csv("data.csv")
print(df.shape)
print(df.dtypes)

#%% Explore
print(df.describe())
```

### 2. Run one cell at a time

```bash
pyrepl run analysis.py:0
```

**Read the output. Think about what it tells you. Then decide what cell to run next.**

Do NOT run all cells blindly. The value of pyrepl is iterative analysis — each cell's output should inform your next step.

### 3. Edit and re-run

If a cell's output reveals something unexpected, edit the notebook and re-run that cell. The namespace persists, so you don't need to reload data.

### 4. Ad-hoc queries

For simple one-liners only (no quotes, no f-strings with brackets):

```bash
pyrepl run 'print(df.shape)'
pyrepl run 'print(df.columns.tolist())'
```

**For anything else, write a cell.** Bash quoting breaks f-strings, escaped quotes, and multi-line code. If your code has quotes, brackets, or f-strings — don't inline it. Add a cell to the notebook and run it by index. This is the #1 cause of agent errors.

## Commands reference

```
pyrepl start --workdir DIR    Start session (auto-detects .venv/)
pyrepl run file.py:N          Run cell N from file
pyrepl run file.py            Run all cells
pyrepl run 'code'             Run inline code
pyrepl ps                     Show active sessions
pyrepl stop                   Stop current session
pyrepl stop-all               Stop all sessions
```

## Rules

1. **One cell at a time.** Run a cell, read output, think, then proceed.
2. **Print what you need.** The REPL captures stdout. If you don't `print()`, you won't see the result.
3. **Data persists.** Variables from earlier cells are still in memory. No need to reload.
4. **Errors don't kill the session.** If a cell errors, fix it and re-run. The namespace survives.
5. **Start with shape and dtypes.** Always inspect the data before analyzing it.
6. **End with a conclusion.** Your final cell should print a clear, specific finding — not just tables.
7. **Context recovery.** Every execution is logged to `history.md` in the session directory. If you lose context (conversation compressed, session resumed), read that file to see what was already run and what's in the namespace.
