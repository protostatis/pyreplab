# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pyrepl is a persistent Python REPL for LLM CLI tools. It runs a background Python process that maintains a persistent namespace, allowing code execution in discrete `#%%` cell blocks while preserving all variable state and imports between commands. Zero dependencies — stdlib only, Python 3.9+.

## Testing

```bash
bash test_pyrepl.sh    # 14 unit tests: execution, persistence, errors, display limits, cells, stdin
bash test_agent.sh     # 10-step integration test simulating iterative data analysis
```

There is no lint or type-checking configured.

## Architecture

Two main components communicate via file-based IPC (no ports/sockets):

**`pyrepl` (bash)** — CLI frontend. Dispatches commands (`start`, `run`, `stop`, `ps`, etc.) to the daemon. Handles session discovery by hashing `--workdir` with md5 to derive a session directory under `/tmp/pyrepl/`. Parses `file.py:N` cell references via an embedded Python snippet (`_extract_cell`).

**`pyrepl.py` (Python)** — Background daemon. Polls for `cmd.py` files, executes code in a persistent namespace via `exec()`, writes results to `output.json`. Manages environment activation (venv/conda), timeout via `SIGALRM`, output truncation, and pandas/numpy display limits.

### IPC Protocol

1. Client writes `cmd.py` (atomically via `.tmp` + `rename`) with `#%% id: <unique-id>` header followed by Python code
2. Server reads `cmd.py`, removes it, executes code, writes `output.json` atomically with `{stdout, stderr, error, id}`
3. Server writes `done` file to signal completion
4. Client polls for `done`, reads `output.json`, cleans up

The `id` field prevents clients from reading stale output from a previous command.

### Session Isolation

Each `--workdir` gets its own session directory (`/tmp/pyrepl/<name>_<hash>/`) containing `pyrepl.pid`, `cmd.py`, `output.json`, `done`, and `history.md`. Sessions are resolved from `PYREPL_DIR` env var or derived from the current working directory.

### Key Design Decisions

- **File-based IPC over sockets**: No service discovery needed, works in restricted environments
- **Atomic writes**: `.tmp` then `os.rename` ensures clients never read partial files
- **Output truncation**: Alternates taking lines from head and tail to preserve both ends within the character budget
- **Auto environment activation**: Priority order is `--venv` > `.venv/` auto-detect > `--conda` > conda base auto-detect (disable with `--no-conda`)
