# pyreplab Install Flow Audit

> **Status: resolved in 0.5.0.** All four issues below were fixed by the
> session/env redesign and the install-resolution fixes:
> 1. `PYREPLAB_SCRIPT` resolution now prefers the venv python adjacent to the
>    script (uv tool installs) and fails with a clear message instead of
>    silently launching an empty path.
> 2. Daemon startup output goes to `<session>/daemon.log` (nohup detach) and
>    `start` verifies the pid is alive; `status` reports resolved config from
>    `session.json`.
> 3. `start` still verifies liveness after launch; `session.json` + `daemon.log`
>    make startup failures diagnosable.
> 4. The daemon re-executes under the detected environment's own python, and
>    `--venv` paths are validated before activation.
>
> The audit below is preserved as the historical record of the original findings.

## Summary
The install process has **4 critical issues** that cause silent failures and circling during startup:

1. **PYREPLAB_SCRIPT resolution is fragile** — fails silently if package not installed
2. **No error capture from daemon startup** — daemon crashes but user sees no output
3. **Race condition: daemon.py fails before pid written** — bash thinks it started
4. **Missing pyreplab path validation** — no check that import actually worked

---

## Issue 1: PYREPLAB_SCRIPT Resolution (pyreplab:23-28)

**Current code:**
```bash
if [ -n "${PYREPLAB_SCRIPT:-}" ]; then
    :
elif [ -f "$(cd "$(dirname "$0")" && pwd)/pyreplab.py" ]; then
    PYREPLAB_SCRIPT="$(cd "$(dirname "$0")" && pwd)/pyreplab.py"
else
    PYREPLAB_SCRIPT="$(python3 -c 'import pyreplab; print(pyreplab.__file__)')"
fi
```

**Problems:**
- If `import pyreplab` fails (package not installed, or import error in pyreplab.py), the error is **silently discarded**
- `PYREPLAB_SCRIPT` becomes empty string, but bash continues
- Line 96 then runs: `python3 "" --session-dir "$dir" "$@" &` → cryptic "No such file or directory" error

**Example failure sequence:**
```bash
$ pyreplab start --workdir /path/to/project
# PYREPLAB_SCRIPT="" (silent import error is lost)
# Next: python3 "" --session-dir /tmp/... &
# → python3: no such file or directory (confusing error, not the real problem)
```

---

## Issue 2: No Error Capture from Daemon Startup (pyreplab:96-104)

**Current code:**
```bash
python3 "$PYREPLAB_SCRIPT" --session-dir "$dir" "$@" &
local pid=$!
echo "$pid" > "$pidfile"
sleep 0.3
if ! kill -0 "$pid" 2>/dev/null; then
    echo "pyreplab: failed to start" >&2
    rm -f "$pidfile"
    return 1
fi
```

**Problems:**
- Daemon is backgrounded, so stderr goes to the parent's stderr (lost in pipes, scripts, IDE output)
- The 0.3s sleep is too short to catch import errors in pyreplab.py
- If pyreplab.py crashes during `import` or `main()` startup, the process exits **before** the REPL polling loop starts
- User only sees "pyreplab: started (pid X, dir Y)" even if the daemon immediately crashed

**Example failure sequence:**
```bash
$ pyreplab start --workdir /project
pyreplab: started (pid 12345, dir /tmp/pyreplab/project_abc123)  ← lies!

# Daemon is actually dead:
$ pyreplab run 'print("hello")'
pyreplab: not running  ← NOW the user discovers it

# Or circling scenario: user retries, bash keeps backgrounding new processes
$ pyreplab start --workdir /project
pyreplab: started (pid 12346, ...)
$ pyreplab status
pyreplab: not running
$ pyreplab start --workdir /project
pyreplab: started (pid 12347, ...)  ← keeps creating dead processes
```

---

## Issue 3: Race Condition on Daemon Failure (pyreplab:96-104)

**The timing window:**
1. Line 96: `python3 "$PYREPLAB_SCRIPT" ... &` starts
2. Line 97: `pid=$!` captures the PID
3. Line 98: `echo "$pid" > "$pidfile"` writes to disk
4. Line 99: `sleep 0.3` waits
5. **Meanwhile (0-300ms):** pyreplab.py is starting, running `main()`, hitting import errors, activating venv, etc.

**Problem:** If pyreplab.py crashes during lines 274-362 of pyreplab.py (before the polling loop), the process is **already dead** but the pidfile exists. The bash wrapper's `kill -0` check at line 100 might still succeed if:
- The process hasn't exited yet (timing-dependent)
- Or fails but the wrapper doesn't capture stderr showing why

**Result:** The wrapper reports "started successfully" but the process dies silently.

---

## Issue 4: No pyreplab.py Path Validation (pyreplab:25-28)

**Missing validation:**
```bash
PYREPLAB_SCRIPT="$(python3 -c 'import pyreplab; print(pyreplab.__file__)')"
# ^ No check that this succeeded or returned a valid path
```

**Should be:**
```bash
PYREPLAB_SCRIPT="$(python3 -c 'import pyreplab; print(pyreplab.__file__)' 2>&1)" || {
    echo "pyreplab: failed to import pyreplab module" >&2
    return 1
}
[ -f "$PYREPLAB_SCRIPT" ] || {
    echo "pyreplab: pyreplab.py not found at $PYREPLAB_SCRIPT" >&2
    return 1
}
```

---

## Issue 5: Daemon Never Reaches Polling Loop (pyreplab.py:274-410)

**Root causes in pyreplab.py that cause silent crashes:**

1. **Line 302:** `activate_venv()` fails silently if .venv/ is malformed
   ```python
   if venv_path:
       activate_venv(venv_path)  # Returns False on error, not checked
   ```

2. **Line 329:** `os.chdir()` can fail if workdir was deleted
   ```python
   if final_cwd:
       os.chdir(final_cwd)  # Raises OSError, crashes daemon
   ```

3. **Line 334:** sys.path manipulation has no error handling
   ```python
   if cwd not in sys.path:
       sys.path.insert(0, cwd)  # OK, but next line can fail
   ```

4. **Line 344:** `configure_display()` can fail if exec() hits syntax errors
   ```python
   configure_display(namespace, ...)  # Calls exec(), no try/except
   ```

5. **Line 362:** Prints to stderr before polling loop starts
   ```python
   print(f"pyreplab: listening on {session_dir}...")
   # If this line is never printed, daemon crashed before reaching polling
   ```

**Missing output:** There's no "daemon is ready" signal. The bash wrapper only checks if the process is alive, not whether it's actually listening.

---

## Symptom: The Circling Problem

When `pyreplab start` keeps creating new processes that die immediately:

1. User runs: `pyreplab start --workdir /project`
2. Bash wrapper backgrounds pyreplab.py, writes pidfile, says "started"
3. User runs: `pyreplab run 'code'`
4. Bash checks pidfile → process is dead (but wrapper didn't know)
5. `_resolve_session` falls back to `.last_session` or default, which is also dead
6. User retries: `pyreplab start --workdir /project`
7. Loop repeats → **circling**

This happens when pyreplab.py crashes **after** pidfile is written but **before** polling loop starts.

---

## Detailed Failure Sequence Example

```
$ pyreplab start --workdir /Users/zhiminzou/Projects/unchainedsky_com

# Step 1: Bash resolves PYREPLAB_SCRIPT
# - Checks if /path/to/pyreplab.py exists locally ✓
# - Sets PYREPLAB_SCRIPT=/path/to/pyreplab.py

# Step 2: cmd_start launches daemon
python3 /path/to/pyreplab.py --session-dir /tmp/pyreplab/unchainedsky_com_hash "$@" &
# Returns: pid 12345

# Step 3: Writes pidfile
echo 12345 > /tmp/pyreplab/unchainedsky_com_hash/pyreplab.pid

# Step 4: Waits 0.3s
sleep 0.3

# Step 5: Checks if process alive
kill -0 12345 → true (process still running OR just exited, timing varies)

# Meanwhile, in the background process (12345):
# → pyreplab.py main() starts
# → Parses args
# → Line 302: activate_venv() called
#   → venv_path = /project/.venv (or similar)
#   → activate_venv() fails because .venv missing or corrupt
#   → Returns False (not checked!)
# → Line 329: os.chdir(final_cwd) called
#   → Directory was deleted
#   → Raises OSError
#   → Daemon crashes
#   → No "listening on..." message printed

# Meanwhile, back in bash (before sleep finishes):
# kill -0 12345 → still returns success (process hasn't been reaped yet)
# Or: kill -0 12345 → fails, but we return 1 anyway

# Result:
$ pyreplab: started (pid 12345, dir /tmp/...)  ← LIE

# Next command:
$ pyreplab run 'print("hi")'
# Bash checks pidfile
# Tries to send cmd.py to daemon
# Daemon doesn't read it (it's dead)
# After 30s timeout: "still running"
# Actually: process has been dead since startup

# Or user retries start:
$ pyreplab start --workdir /project
# Same thing, creates pid 12346
# Circling: new processes keep dying at startup
```

---

## Recommendations

### Phase 1: Immediate Fixes (bash wrapper)

1. **Capture and validate PYREPLAB_SCRIPT**
   ```bash
   PYREPLAB_SCRIPT="$(python3 -c 'import pyreplab; print(pyreplab.__file__)' 2>&1)" || {
       echo "pyreplab: import error (package not installed or syntax error in pyreplab.py):" >&2
       echo "$PYREPLAB_SCRIPT" >&2
       return 1
   }
   [ -f "$PYREPLAB_SCRIPT" ] || {
       echo "pyreplab: pyreplab.py not found at: $PYREPLAB_SCRIPT" >&2
       return 1
   }
   ```

2. **Capture daemon startup errors**
   ```bash
   # Redirect daemon stderr to a temp file
   local daemon_log="$dir/startup.log"
   python3 "$PYREPLAB_SCRIPT" --session-dir "$dir" "$@" 2>"$daemon_log" &
   local pid=$!

   # Wait longer (1-2s) to catch import errors
   sleep 1

   # Check if process alive
   if ! kill -0 "$pid" 2>/dev/null; then
       echo "pyreplab: daemon crashed during startup" >&2
       [ -f "$daemon_log" ] && cat "$daemon_log" >&2
       return 1
   fi

   # Optionally show startup output
   [ -s "$daemon_log" ] && cat "$daemon_log" >&2
   ```

3. **Validate daemon reached polling loop**
   ```bash
   # Check if daemon has written the "listening" message
   local ready_file="$dir/ready"
   local wait_count=0
   while [ $wait_count -lt 20 ]; do  # 2s with 0.1s intervals
       if [ -f "$ready_file" ]; then
           break
       fi
       sleep 0.1
       wait_count=$((wait_count + 1))
       if ! kill -0 "$pid" 2>/dev/null; then
           echo "pyreplab: daemon died before reaching polling loop" >&2
           [ -f "$daemon_log" ] && cat "$daemon_log" >&2
           return 1
       fi
   done
   if [ ! -f "$ready_file" ]; then
       echo "pyreplab: daemon startup timeout (still starting?)" >&2
       return 1
   fi
   ```

### Phase 2: Daemon robustness (pyreplab.py)

1. **Add error handling in main()**
   ```python
   try:
       venv_path = args.venv
       if venv_path is None:
           candidate = os.path.join(venv_detect_dir, ".venv")
           if os.path.isdir(candidate):
               venv_path = candidate
       if venv_path:
           if not activate_venv(venv_path):  # Now we check the return value
               print(f"pyreplab: failed to activate venv {venv_path}", file=sys.stderr)
               sys.exit(1)

       # ... rest of main()
   except Exception as e:
       print(f"pyreplab: startup error: {e}", file=sys.stderr)
       traceback.print_exc(file=sys.stderr)
       sys.exit(1)
   ```

2. **Signal daemon is ready**
   ```python
   # After polling loop starts, write ready file
   print(f"pyreplab: listening on {session_dir} (poll={args.poll_interval}s)", file=sys.stderr)
   with open(os.path.join(session_dir, "ready"), "w") as f:
       f.write(str(os.getpid()))

   while running:
       # polling loop...
   ```

3. **Validate workdir before chdir**
   ```python
   final_cwd = args.cwd or args.workdir
   if final_cwd:
       final_cwd = os.path.abspath(final_cwd)
       if not os.path.isdir(final_cwd):
           print(f"pyreplab: workdir not found: {final_cwd}", file=sys.stderr)
           sys.exit(1)
       os.chdir(final_cwd)
   ```

### Phase 3: Testing

Add integration tests:
```bash
# test_install_flow.sh

# Test 1: Start with missing .venv
pyreplab start --workdir /nonexistent --venv /nonexistent/path
# Should fail immediately with clear error

# Test 2: Start then run
pyreplab start --workdir $(pwd)
pyreplab run 'print("hello")'
pyreplab stop
# Should work

# Test 3: Concurrent starts (catch race conditions)
for i in {1..5}; do
    pyreplab start --workdir /project &
done
wait
pyreplab ps  # Should show 1 session, not 5
```

---

## Impact

These fixes will eliminate:
- Silent daemon crashes
- Mysterious "not running" errors
- Circling retry loops
- Confusing error messages from failed imports

Users will instead get **immediate, clear feedback** about what went wrong.
