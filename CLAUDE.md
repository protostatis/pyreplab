# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pyreplab is a persistent Python REPL for LLM CLI tools. It runs a background Python process that maintains a persistent namespace, allowing code execution in discrete `# %%` cell blocks while preserving all variable state and imports between commands. Zero dependencies — stdlib only, Python 3.9+.

## Testing

```bash
bash test_pyreplab.sh    # 14 unit tests: execution, persistence, errors, display limits, cells, stdin
bash test_agent.sh     # 10-step integration test simulating iterative data analysis
```

There is no lint or type-checking configured.

## Publishing

```bash
uv build && uv publish dist/*
```

Use `uv` for building and publishing to PyPI (not `python -m build` / `twine`).

## Architecture

Two main components communicate via file-based IPC (no ports/sockets):

**`pyreplab` (bash)** — CLI frontend. Dispatches commands (`start`, `run`, `wait`, `cancel`, `cells`, `stop`, `ps`, etc.) to the daemon. Handles session discovery by hashing `--workdir` with md5 to derive a session directory under `/tmp/pyreplab/`. Parses `file.py:N` cell references via an embedded Python snippet (`_extract_cell`). Stamps `[N]` indices into `# %%` cell markers on `run` and `cells` (idempotent, disable with `PYREPLAB_STAMP=0`). Supports async execution: `run` returns early (exit 2) if a command doesn't finish within `PYREPLAB_TIMEOUT` (default 115s), and `wait` resumes polling. `cancel` sends `SIGUSR1` to interrupt the running command without killing the session.

**`pyreplab.py` (Python)** — Background daemon. Polls for `cmd.py` files, executes code in a persistent namespace via `exec()`, writes results to `output.json`. Manages environment activation (venv/conda), output truncation, and pandas/numpy display limits. Handles `SIGUSR1` to cancel the currently executing command (raises `KeyboardInterrupt` inside `exec()`).

### IPC Protocol

1. Client checks `pending_id` — if present, a previous command is still running (returns "busy")
2. Client writes `cmd.py` (atomically via `.tmp` + `rename`) with `#%% id: <unique-id>` header followed by Python code, and writes the id to `pending_id`
3. Server reads `cmd.py`, removes it, executes code, writes `output.json` atomically with `{stdout, stderr, error, id}`
4. Server writes `done` file to signal completion
5. Client polls for `done` up to `PYREPLAB_TIMEOUT` (default 115s). If done: reads `output.json`, cleans up (`done`, `output.json`, `pending_id`, `pending_start`). If not: returns exit 2 with "still running" message; `pyreplab wait` resumes polling. `pyreplab cancel` sends `SIGUSR1` to interrupt the running command

The `id` field prevents clients from reading stale output from a previous command.

### Session Isolation

Each `--workdir` gets its own session directory (`/tmp/pyreplab/<name>_<hash>/`) containing `pyreplab.pid`, `cmd.py`, `output.json`, `done`, `pending_id`, `pending_start`, and `history.md`. Sessions are resolved from `PYREPLAB_DIR` env var or derived from the current working directory. The `--cwd` flag sets the REPL's working directory independently from `--workdir` (which controls session identity and `.venv` detection). When `--cwd` is explicitly set, the working directory is **locked** — per-command cwd sync from the caller's shell is skipped, so `os.getcwd()` and `sys.path[0]` stay at the `--cwd` directory for the entire session.

### Key Design Decisions

- **File-based IPC over sockets**: No service discovery needed, works in restricted environments
- **Atomic writes**: `.tmp` then `os.rename` ensures clients never read partial files
- **Output truncation**: Alternates taking lines from head and tail to preserve both ends within the character budget
- **Auto environment activation**: Priority order is `--venv` > `.venv/` auto-detect > `--conda` > conda base auto-detect (disable with `--no-conda`)
- **Cell stamping**: `run` and `cells` write `[N]` indices into `# %%` markers so LLMs and users can reference cells by number. Idempotent — indices update on reorder, no double-stamping. Also normalizes `#%%` to `# %%` (PEP 8). `cells` peeks at the next comment line for unlabeled markers. Disable with `PYREPLAB_STAMP=0`
- **Cell marker format**: Accepts both `# %%` and `#%%` (the percent format, compatible with VS Code, Spyder, PyCharm, Jupytext). Pattern: `# ?%%`
