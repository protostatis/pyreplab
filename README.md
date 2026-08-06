# pyreplab

Persistent Python REPL for LLM CLI tools.

LLM coding CLIs (Claude Code, Copilot CLI, etc.) can't maintain a persistent Python session — each bash command runs in a fresh process. For large datasets, reloading on every query is impractical. pyreplab fixes this.

## How it works

A background Python process sits in memory with a persistent namespace. You write `.py` files with `# %%` cell blocks, then execute cells by reference. No ports, no sockets, no dependencies.

## Quick start

Write a `.py` file with `# %%` cell blocks — in your editor, or let an LLM write it:

```python
# analysis.py

# %% Load
import pandas as pd
df = pd.read_csv("data.csv")
print(df.shape)

# %% Explore
print(df.describe())

# %% Top rows
print(df.head(20))
```

Then run cells:

```bash
pyreplab start                        # start (auto-detects project root + .venv/ or pixi/conda)
pyreplab run analysis.py:0            # Load data — stamps [0], [1], [2] into file
pyreplab run analysis.py:0                  # Load data — stamps [0], [1], [2] into file
pyreplab run analysis.py:1                  # Explore (df still loaded)
pyreplab run analysis.py:2                  # Top rows (no reload)
pyreplab stop
```

After the first run, `analysis.py` is updated with cell indices:
```python
# %% [0] Load        ← index added automatically
# %% [1] Explore
# %% [2] Top rows
```

## CLI reference

```
pyreplab <command> [args]

  start [opts]        Start the REPL (see START OPTIONS in `pyreplab help`)
  run file.py         Run all cells (stamps [N] indices into file)
  run file.py:N       Run cell N from file (0-indexed)
  run 'code'          Run inline code
  run                 Read code from stdin
  cells file.py       List cells (stamps [N] indices into file)
  wait                Wait for a running command to finish
  cancel              Cancel the currently running command
  dir                 Print session directory path
  stop                Stop the current session
  stop-all            Stop all active sessions
  ps                  List all active sessions with PID, uptime, memory
  status              Check if REPL is running (shows idle/executing + resolved config)
  clean               Remove session files
```

`pyreplab help` documents the start options, environment auto-detection order, and the agent workflow (exit codes, wait/cancel pattern).

## Server options

```
python pyreplab.py [options]

  --session-dir DIR    Session directory (resolved by the CLI; override with PYREPLAB_DIR)
  --session-root DIR   Canonical project root (resolved by the CLI)
  --cwd DIR            Lock the REPL's working directory to DIR (sticky). Default:
                       each command runs in the caller's shell directory
  --venv PATH          Path to virtualenv directory itself (e.g. /project/.venv)
  --conda [ENV]        Activate conda env (default: base)
  --no-conda           Disable conda auto-detection
  --max-output CHARS   Hard cap on output size (default: 100000)
  --max-rows N         Pandas display rows (default: 50)
  --max-cols N         Pandas display columns (default: 20)
  --poll-interval SECS Poll interval (default: 0.05)
  --progress-interval SECS Seconds between progress.json snapshots (default: 1.0, 0 disables)
```

Note: the daemon has no server-side timeout — commands run to completion. The *client* gives up polling after `PYREPLAB_TIMEOUT` seconds (default 30) and returns exit code 2; `pyreplab wait` resumes polling.

## Working directory

`--cwd` is the only execution-directory flag, and it is **sticky**: the REPL runs in that directory regardless of where the caller's shell is, so relative imports and file paths always resolve there (`import config` finds `config.py` next to the working directory).

Without `--cwd`, the REPL **follows the caller**: every `run` executes in the caller's shell directory, with that directory at `sys.path[0]` (the previous directory is removed — no path accumulation).

```bash
# Sticky: REPL always runs in the data subdir
pyreplab start --cwd /project/data/experiment1
pyreplab run 'import pandas as pd; print(pd.read_csv("local_file.csv").shape)'

# Follow: state persists in the project session, code runs where you are
cd /project && pyreplab start
cd /project/data && pyreplab run 'print(os.getcwd())'   # /project/data
```

Note: `import config` caches in `sys.modules` — after moving directories, an already-imported module keeps its old identity (inherent to a persistent REPL; use a fresh name or `importlib.reload` for new locations).

When `--cwd` is explicitly set, the working directory is **sticky** — it stays locked to that path for the entire session, regardless of where the caller's shell is when issuing `run` commands. This ensures `import mymodule` keeps working even if you `cd` elsewhere. Without `--cwd`, the daemon syncs its working directory to the caller's shell on each `run`.

## Async execution

Long-running commands return early instead of blocking. The client polls for up to `PYREPLAB_TIMEOUT` seconds (default: 30s, configurable via env var). If the command finishes in time, output is returned normally. If not:

```bash
export PYREPLAB_TIMEOUT=5
pyreplab run 'import time; time.sleep(30); print("done")'
# → pyreplab: still running (5s elapsed). Run `pyreplab wait` to check again.
# exit code 2

pyreplab wait
# → done
# exit code 0
```

While a long command is executing, the daemon streams progress so you can see it's alive and how far it's gotten. During `run`/`wait` polling, a progress line is printed to stderr once per new snapshot (every ~1s), showing elapsed time, output volume, the active notebook cell, and the last line of output:

```bash
pyreplab run 'for i in range(10000):
    print(f"iter {i}")'
# → pyreplab: progress (3.0s) 710 chars out | last: iter 89
# → pyreplab: progress (4.0s) 970 chars out | last: iter 119
# → ... (final output on completion)
```

For commands that produce no output (long sleeps, silent computation), a heartbeat line appears every 10s so it's still clear the daemon is working. Disable progress display with `PYREPLAB_PROGRESS=0`; the daemon writes `progress.json` every `--progress-interval` seconds (default 1s, 0 disables).

If you try to run a new command while one is still executing:
```bash
pyreplab run 'print("hi")'
# → pyreplab: busy running previous command. Run `pyreplab wait` first.
# exit code 1
```

To cancel a running command without killing the session:
```bash
pyreplab cancel
# → pyreplab: cancel signal sent
# → KeyboardInterrupt
```

The cancel sends `SIGUSR1` to the daemon, which raises `KeyboardInterrupt` inside the running code. The session stays alive — only the current command is interrupted.

When running a whole file (`pyreplab run file.py`), the daemon executes all cells sequentially in one server-side command; the client waits for the single combined result (which may take longer than `PYREPLAB_TIMEOUT` — use `wait` to resume polling, progress lines show the active cell).

Short commands that finish within the timeout window work identically to before — no behavior change.

## Environment detection

pyreplab automatically detects and activates the right Python environment, so **agents don't need to know which env system a project uses**. Detection follows a priority order — the first match wins:

| Priority | Source | How it's found |
|----------|--------|----------------|
| 1 | `--venv PATH` | Explicit flag |
| 2 | `$PIXI_ENVIRONMENT_PREFIX` | Set by `pixi run` / `pixi shell` |
| 3 | `.venv` | Nearest one between the working directory and the project root (venv/uv convention) |
| 4 | `.pixi/envs/<name>` | Nearest pixi environment (default name, or `$PIXI_ENVIRONMENT_NAME`) |
| 5 | `--conda [ENV]` | Explicit flag |
| 6 | Conda base | Auto-detected fallback |

The daemon **re-executes under the environment's own python**, so the interpreter version, site-packages and compiled extensions (numpy, pandas, …) always match — no more cryptic import failures from a version mismatch. `status` shows what was resolved (`env venv:/path | python 3.13.11`). Use `--no-conda` to disable the conda fallback.

### Virtual environments (venv, uv, virtualenv)

```bash
# Auto-detect .venv/ (most common — recommended for uv projects)
pyreplab start

# Explicit path — must point to the .venv directory itself, not the project root
pyreplab start --venv /path/to/project/.venv
```

Works with `uv venv`, `python -m venv`, or any standard virtualenv.

### Pixi environments

```bash
# Project pixi env (.pixi/envs/default) — auto-detected
pyreplab start

# Inside `pixi run` / `pixi shell` — $PIXI_ENVIRONMENT_PREFIX is used
pyreplab start

# Named envs: set PIXI_ENVIRONMENT_NAME, or it picks the single .pixi/envs/* entry
pixi run --environment dev pyreplab start
```

Pixi envs are conda-style, so activation, the `bin/python` re-exec and PATH prepend all work unchanged.

### Conda environments

```bash
# Auto-detect: if no .venv/ or pixi env, conda base is used automatically
pyreplab start

# Explicit: force conda base
pyreplab start --conda

# Named conda env
pyreplab start --conda myenv

# Disable conda fallback (bare Python only)
pyreplab start --no-conda
```

Conda base is found by checking, in order:
1. `$CONDA_PREFIX` (set when a conda env is active)
2. `$CONDA_EXE` (e.g. `~/miniconda3/bin/conda` → derives `~/miniconda3`)
3. Common install paths: `~/miniconda3`, `~/anaconda3`, `~/miniforge3`, `~/mambaforge`, `/opt/conda`

Named envs resolve to `<conda_base>/envs/<name>`.

## Session isolation

Each project root gets its own isolated session — separate process, namespace, and files. The root is auto-discovered from the nearest ancestor containing `.git` or `pyproject.toml` (falling back to the current directory), so sessions are keyed to projects, not shell locations.

```bash
# Two projects, two sessions — no flags needed
cd ~/projects/project-a && pyreplab start
cd ~/projects/project-b && pyreplab start

# See what's running
pyreplab ps
# SESSION                      PID     UPTIME   MEM    DIR
# project-a_a1b2c3d4           12345   5m30s    57MB   /tmp/pyreplab/project-a_a1b2c3d4
# project-b_e5f6g7h8           12346   2m15s    43MB   /tmp/pyreplab/project-b_e5f6g7h8

# Commands auto-resolve to the right session based on the discovered root
cd ~/projects/project-a && pyreplab run analysis.py:0
cd ~/projects/project-b && pyreplab run analysis.py:0

# Override the session directory explicitly
PYREPLAB_DIR=/custom/session pyreplab start
pyreplab status   # shows root, mode (follow/sticky), env and python version
```

## Display limits

Output is automatically truncated for LLM-friendly sizes:

| Library | Setting | Default |
|---------|---------|---------|
| pandas | max_rows | 50 |
| pandas | max_columns | 20 |
| pandas | max_colwidth | 80 chars |
| numpy | threshold | 100 elements |

Override with `--max-rows` and `--max-cols`. The `--max-output` flag is a hard character cap that truncates at line boundaries, keeping both head and tail.

## Cell markers and stamping

Cells are delimited by `# %%` comments (the [percent format](https://jupytext.readthedocs.io/en/latest/formats-scripts.html), compatible with VS Code, Spyder, PyCharm, and Jupytext). Both `# %%` and `#%%` are accepted.

When you run or list cells, pyreplab **stamps `[N]` indices** into the cell markers in your file:

```python
# Before:                       # After first run/cells:
# %% Load                       # %% [0] Load
import pandas as pd              import pandas as pd
# %%                             # %% [1]
# Clean the data                 # Clean the data
df = df.dropna()                 df = df.dropna()
```

- **Idempotent** — running again doesn't double-stamp; indices update if cells are reordered
- **`#%%` normalizes to `# %%`** — the PEP 8 / linter-friendly form (avoids flake8 E265)
- **`PYREPLAB_STAMP=0`** — disables file modification entirely
- **Inline code and stdin** — no stamping (no file to modify)

The `cells` command also reads the first comment line below an unlabeled `# %%` marker as its description:

```
$ pyreplab cells analysis.py
  0: # %% Load
  1: # %% Clean the data       ← peeked from comment below "# %% [1]"
```

## Session history

Every execution is logged to `history.md` in the session directory. This is useful for context recovery — if an LLM conversation gets compressed or a session is resumed, the agent can read the history to see what was already run and what's in the namespace.

```bash
cat "$(pyreplab dir)/history.md"
```

The history resets on each new session start.

## Protocol

**cmd.py** (client writes):
```python
# %% id: unique-id
import pandas as pd
df = pd.read_csv("big.csv")
print(df.shape)
```

The first line is a `# %%` cell header with a command ID. The rest is plain Python — no escaping, no JSON encoding.

**output.json** (pyreplab writes):
```json
{"stdout": "(1000, 5)\n", "stderr": "", "error": null, "id": "unique-id"}
```

Files are written atomically (write `.tmp`, then `os.rename`). The `id` field prevents reading stale output.

## Install

```bash
git clone https://github.com/anthropics/pyreplab.git
cd pyreplab
```

Make `pyreplab` available on your PATH (pick one):

```bash
# Option 1: symlink (recommended)
ln -s "$(pwd)/pyreplab" /usr/local/bin/pyreplab

# Option 2: add directory to PATH
echo 'export PATH="'$(pwd)':$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify:

```bash
pyreplab start
pyreplab run 'print("hello")'
pyreplab stop
```

### Using with Claude Code

Append the agent instructions to Claude Code's system prompt:

```bash
claude --append-system-prompt-file /path/to/pyreplab/AGENT_PROMPT.md
```

Or add them to your project's `CLAUDE.md` so they're loaded automatically in every session.

## Tests

```bash
bash test_pyreplab.sh    # 14 tests: basic execution, persistence, errors, display limits, cells, stdin
bash test_agent.sh     # 10-step agent walkthrough: loads data, analyzes, reaches a conclusion
```

## Requirements

Python 3.9+. Zero dependencies — stdlib only.
