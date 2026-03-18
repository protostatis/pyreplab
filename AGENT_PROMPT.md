# pyreplab Agent Instructions

You have access to a persistent Python REPL via `pyreplab`. Data stays in memory between commands — load once, query many times.

## Setup (run once at start)

```bash
# Start the REPL for the project you're working in
/path/to/pyreplab start --workdir /path/to/project
```

The `--workdir` auto-detects `.venv/` so all project packages are available. Sessions are isolated per project.

## Context recovery (read this first!)

If you've lost context (conversation compressed, session resumed, or you're unsure what's been run), **read the session history before doing anything else**:

```bash
cat "$(pyreplab dir)/history.md"
```

Every command and its output is logged there. Read it to understand the current state before running anything new.

## Workflow

### 1. Write a notebook

Create a `.py` file with `# %%` cell blocks. Each cell is a logical step:

```python
# analysis.py

# %% Load
import pandas as pd
df = pd.read_csv("data.csv")
print(df.shape)
print(df.dtypes)

# %% Explore
print(df.describe())
```

### 2. Run one cell at a time

```bash
pyreplab run analysis.py:0
```

On first run, pyreplab stamps `[N]` indices into the cell markers in the file (`# %% Load` → `# %% [0] Load`). This is idempotent — subsequent runs don't double-stamp. Disable with `PYREPLAB_STAMP=0`.

**Read the output. Think about what it tells you. Then decide what cell to run next.**

Do NOT run all cells blindly. The value of pyreplab is iterative analysis — each cell's output should inform your next step.

### 3. Edit and re-run

If a cell's output reveals something unexpected, edit the notebook and re-run that cell. The namespace persists, so you don't need to reload data.

### 4. Ad-hoc queries

For simple one-liners only (no quotes, no f-strings with brackets):

```bash
pyreplab run 'print(df.shape)'
pyreplab run 'print(df.columns.tolist())'
```

**For anything else, write a cell.** Bash quoting breaks f-strings, escaped quotes, and multi-line code. If your code has quotes, brackets, or f-strings — don't inline it. Add a cell to the notebook and run it by index. This is the #1 cause of agent errors.

## Commands reference

```
pyreplab start --workdir DIR    Start session (auto-detects .venv/)
pyreplab start --workdir DIR --cwd DIR   Start with separate working directory (locks cwd for imports)
pyreplab run file.py:N          Run cell N (stamps [N] indices into file)
pyreplab run file.py            Run all cells (stamps [N] indices into file)
pyreplab run 'code'             Run inline code
pyreplab cells file.py          List cells (stamps [N], peeks comments for labels)
pyreplab wait                   Wait for a long-running command to finish
pyreplab cancel                 Cancel the currently running command
pyreplab dir                    Print session directory path
pyreplab status                 Check if REPL is running (idle/executing)
pyreplab ps                     Show active sessions
pyreplab stop                   Stop current session
pyreplab stop-all               Stop all sessions
```

Long-running commands return early with exit code 2 and a "still running" message. Use `pyreplab wait` to resume polling. If you get "busy running previous command", run `pyreplab wait` first before submitting new code. To abort a stuck or unwanted command, use `pyreplab cancel` — it interrupts the running code without killing the session.

## Rules

1. **One cell at a time.** Run a cell, read output, think, then proceed.
2. **Print what you need.** The REPL captures stdout. If you don't `print()`, you won't see the result.
3. **Data persists.** Variables from earlier cells are still in memory. No need to reload.
4. **Errors don't kill the session.** If a cell errors, fix it and re-run. The namespace survives.
5. **Start with shape and dtypes.** Always inspect the data before analyzing it.
6. **End with a conclusion.** Your final cell should print a clear, specific finding — not just tables.
7. **Context recovery.** If you lose context, read `history.md` from the session directory (see "Context recovery" section above).
