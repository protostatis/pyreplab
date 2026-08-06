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

Then ensure a session is running for the current project:

```bash
pyreplab status || pyreplab start
```

No flags needed: the session is auto-discovered from the nearest ancestor with
`.git` or `pyproject.toml`, and the environment (`.venv`, pixi, conda) is
auto-detected — the daemon re-executes under the env's own python so versions
always match.

## Commands

| Command | Description |
|---------|-------------|
| `pyreplab start [opts]` | Start a REPL session (no flags needed; `--cwd DIR` locks the working dir, `--venv`/`--conda` override env detection) |
| `pyreplab run file.py` | Run all cells in a notebook (auto-continues through waits) |
| `pyreplab run file.py:N` | Run cell N from a notebook (0-indexed) |
| `pyreplab run 'code'` | Run inline Python code |
| `pyreplab run` | Read and execute code from stdin |
| `pyreplab wait` | Poll a running command; auto-continues to next cell in notebook runs |
| `pyreplab cancel` | Interrupt the currently running command |
| `pyreplab cells file.py` | List all cells with indices (stamps `[N]` into file) |
| `pyreplab status` | Check if the REPL is running (shows root, mode, env, python version) |
| `pyreplab stop` | Stop the current session |
| `pyreplab stop-all` | Stop all active sessions |
| `pyreplab ps` | List all active sessions |
| `pyreplab dir` | Print the session directory path |
| `pyreplab clean` | Remove session files |

Run `pyreplab help` for the full start options, environment auto-detection
order, and the agent workflow.

## How to execute

If the user provides a file path or inline code, run it:

```bash
pyreplab run $ARGUMENTS
```

If the session is not running, `status || start` handles it. Commands in a
directory with no session fail with a clear message — run `pyreplab start`
once per project.

## Timeout and wait-resume

Commands timeout after `PYREPLAB_TIMEOUT` seconds (default 30s, configurable via env var). When a command times out:

- `run` returns **exit code 2** and prints "still running"
- Call `pyreplab wait` to poll (2s check). It returns:
  - **exit 0** — done, output printed
  - **exit 1** — error
  - **exit 2** — still running, call `wait` again
- Long-running commands stream progress lines to stderr during `run`/`wait`:
  `pyreplab: progress (3.0s) 710 chars out | last: iter 89`
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
- **Auto-environment**: Detects `.venv/` (venv/uv), `.pixi/envs/<name>` (pixi), `$PIXI_ENVIRONMENT_PREFIX`, or conda; re-executes under the env's python
- **Session per project**: Auto-discovered root (`.git`/`pyproject.toml`); override with `PYREPLAB_DIR`
- **Output truncation**: Large output is trimmed, keeping head and tail
- **Zero dependencies**: stdlib only, Python 3.9+
