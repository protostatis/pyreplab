# pyrepl

Persistent Python REPL for LLM CLI tools.

LLM coding CLIs (Claude Code, Copilot CLI, etc.) can't maintain a persistent Python session — each bash command runs in a fresh process. For large datasets, reloading on every query is impractical. pyrepl fixes this.

## How it works

A background Python process sits in memory with a persistent namespace. It communicates via JSON files in a session directory:

1. Client writes `cmd.json` with `{"code": "...", "id": "123"}`
2. pyrepl executes the code, writes `output.json` with `{"stdout": "...", "stderr": "...", "error": null, "id": "123"}`
3. pyrepl writes a `done` flag file to signal completion

No ports, no sockets, no dependencies. Any tool that can write and read files can drive it.

## Quick start

```bash
# Start the background process
python pyrepl.py &

# Send commands via the shell helper
source pyrepl.sh
pyrun 'import pandas as pd; df = pd.read_csv("big.csv"); print(df.shape)'
pyrun 'print(df.describe())'   # df is still loaded — no reload
```

## Options

```
python pyrepl.py [options]

  --session-dir DIR    Session directory (default: /tmp/pyrepl)
  --workdir DIR        Working directory for the REPL
  --timeout SECS       Per-command timeout (default: 30)
  --max-output CHARS   Max output size (default: 100000)
  --poll-interval SECS Poll interval (default: 0.05)
```

## Shell helper

Source `pyrepl.sh` to get the `pyrun` function:

```bash
source pyrepl.sh
pyrun 'print("hello")'
```

Set `PYREPL_DIR` to use a custom session directory:

```bash
PYREPL_DIR=/tmp/myrepl source pyrepl.sh
pyrun 'print("hello")'
```

## Protocol

**cmd.json** (client writes):
```json
{"code": "print('hello')", "id": "unique-id"}
```

**output.json** (pyrepl writes):
```json
{"stdout": "hello\n", "stderr": "", "error": null, "id": "unique-id"}
```

The `id` field prevents reading stale output from a previous command. Files are written atomically (write `.tmp`, then `os.rename`).

## Requirements

Python 3.9+. Zero dependencies — stdlib only.
