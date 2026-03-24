---
name: pyreplab
description: "Run Python code in a persistent REPL that preserves state across cells. Use when: executing Python, running notebook cells, iterative data analysis, or long-running compute."
allowed-tools: Bash(pyreplab *), Bash(pip install pyreplab), Bash(uv pip install pyreplab), Bash(which pyreplab), Bash(command -v pyreplab), Read, Glob, Grep
argument-hint: "<file.py | file.py:N | 'inline code'>"
---

# pyreplab — Persistent Python REPL

## Setup (auto-install)

Before running any pyreplab command, ensure it is installed:

```bash
command -v pyreplab || pip install pyreplab
```

Then ensure a session is running for the current working directory:

```bash
pyreplab status || pyreplab start
```

## Commands

| Command | Description |
|---------|-------------|
| `pyreplab start` | Start a REPL session for the current directory |
| `pyreplab run file.py` | Run all cells in a notebook (auto-continues through waits) |
| `pyreplab run file.py:N` | Run cell N from a notebook |
| `pyreplab run 'code'` | Run inline Python code |
| `pyreplab wait` | Poll a running command; auto-continues to next cell in notebook runs |
| `pyreplab cancel` | Interrupt the currently running command |
| `pyreplab cells file.py` | List all cells with indices |
| `pyreplab status` | Check if the REPL is running |
| `pyreplab stop` | Stop the current session |

## How to execute

If the user provides a file path or inline code, run it:

```bash
pyreplab run $ARGUMENTS
```

## Timeout and wait-resume

Commands timeout after `PYREPLAB_TIMEOUT` seconds (default 30s). When a command times out:

- `run` returns **exit code 2** and prints "still running"
- Call `pyreplab wait` to poll (2s check). It returns:
  - **exit 0** — done, output printed
  - **exit 1** — error
  - **exit 2** — still running, call `wait` again
- For notebook runs (`run file.py`), `wait` **auto-continues** to the next cell when the current one finishes

**Pattern for long-running cells:**

```bash
pyreplab run file.py
# If exit 2:
pyreplab wait    # repeat until exit 0
```

## Cell format

Cells are delimited by `# %%` markers in .py files:

```python
# %% [0] Load data
import pandas as pd
df = pd.read_csv("data.csv")
print(df.shape)

# %% [1] Analyze
print(df.describe())
```

- Indices `[N]` are stamped automatically
- Reference cells by index: `pyreplab run file.py:1`
- Variables persist across all cells and inline commands

## Key behaviors

- **State persists**: All variables, imports, and definitions survive between commands
- **One command at a time**: If busy, run `pyreplab wait` first
- **Auto-environment**: Detects and activates `.venv/` or conda automatically
- **Output truncation**: Large output is trimmed, keeping head and tail
- **Zero dependencies**: stdlib only, Python 3.9+
