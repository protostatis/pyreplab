#!/usr/bin/env python3
"""pyreplab — Persistent Python REPL for LLM CLI tools.

A background process that keeps a Python namespace in memory.
Commands are sent as .py files with #%% cell headers.
Zero dependencies — stdlib only.
"""

import argparse
import collections
import contextlib
import glob
import io
import json
import os
import re
import signal
import site
import sys
import threading
import time
import traceback

_executing = False  # True while exec() is running; used by SIGUSR1 cancel handler

_COMPOUND_KW = re.compile(
    r';\s*(?=(for|while|if|elif|else|with|try|except|finally|def|class|async|match)\b)'
)


def atomic_write(path, data):
    """Write JSON atomically: write to .tmp, then rename."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.rename(tmp, path)


class _Capture(io.StringIO):
    """Thread-safe StringIO with a bounded tail + char count for progress.

    The monitor thread calls snapshot() while the main thread writes; a lock
    keeps both consistent. Maintaining the tail incrementally avoids copying
    the whole output buffer on every progress tick (quadratic for long runs).
    """

    def __init__(self, tail_chars):
        super().__init__()
        self._tail = collections.deque(maxlen=tail_chars)
        self._count = 0
        self._lock = threading.Lock()

    def write(self, s):
        with self._lock:
            n = super().write(s)
            self._tail.extend(s[:n])
            self._count += n
        return n

    def getvalue(self):
        with self._lock:
            return super().getvalue()

    def snapshot(self):
        """Return (tail_text, total_chars) — O(tail) per call, not O(total)."""
        with self._lock:
            return "".join(self._tail), self._count


def _write_progress(progress_state, session_dir):
    """Snapshot partial output into progress.json (called from monitor thread)."""
    stdout_cap = progress_state.get("stdout")
    stderr_cap = progress_state.get("stderr")
    stdout_tail, stdout_chars = stdout_cap.snapshot() if stdout_cap is not None else ("", 0)
    stderr_tail, stderr_chars = stderr_cap.snapshot() if stderr_cap is not None else ("", 0)
    atomic_write(os.path.join(session_dir, "progress.json"), {
        "stdout": stdout_tail,
        "stderr": stderr_tail,
        "stdout_chars": stdout_chars,
        "stderr_chars": stderr_chars,
        "elapsed": round(time.time() - progress_state["start"], 1),
        "cell": progress_state.get("cell", ""),
        "id": progress_state.get("id", ""),
    })


def _progress_worker(progress_state, stop_event, session_dir, interval):
    """Background thread: while a command executes, write progress.json every
    `interval` seconds so clients can show partial output during long runs."""
    while not stop_event.wait(interval):
        try:
            _write_progress(progress_state, session_dir)
        except Exception:
            pass


def _fix_semicolons(code):
    """Replace ; before compound keywords with newlines (LLM one-liner fix).

    LLM agents often flatten multi-line Python into a single semicolon-separated
    line, but compound statements (for, if, def, etc.) are illegal after ;.
    This detects the SyntaxError and splits only at those points, preserving
    valid semicolons inside loop bodies (e.g. ``for x: a; b; c``).
    """
    try:
        compile(code, "<pyreplab>", "exec")
        return code
    except SyntaxError:
        fixed = _COMPOUND_KW.sub('\n', code)
        try:
            compile(fixed, "<pyreplab>", "exec")
            return fixed
        except SyntaxError:
            return code


def run_code(code, namespace, max_output=100_000, label="", progress_state=None):
    """Execute code in the persistent namespace, capturing output.

    No server-side timeout — commands run to completion. The client handles
    async polling (returns exit code 2 after its poll timeout, then
    `pyreplab wait` resumes polling until the server writes output).

    If progress_state is given (dict with "stdout"/"stderr" keys), the output
    buffers are exposed there so the monitor thread can snapshot partial
    output into progress.json during execution.
    """
    code = _fix_semicolons(code)
    stdout_buf = _Capture(4000)
    stderr_buf = _Capture(2000)
    if progress_state is not None:
        progress_state["stdout"] = stdout_buf
        progress_state["stderr"] = stderr_buf
    error = None
    filename = f"<pyreplab:{label}>" if label else "<pyreplab>"

    # Reset sys.argv so argparse/click don't see the daemon's args
    saved_argv = sys.argv
    sys.argv = [""]

    try:
        with contextlib.redirect_stdout(stdout_buf), contextlib.redirect_stderr(stderr_buf):
            exec(compile(code, filename, "exec"), namespace)
    except SystemExit as e:
        error = f"SystemExit: code called sys.exit({e.code!r})\nHint: argparse calls sys.exit() on error or --help. Set sys.argv = [''] before using argparse in pyreplab."
    except KeyboardInterrupt:
        error = "KeyboardInterrupt"
    except Exception:
        error = traceback.format_exc()
    finally:
        sys.argv = saved_argv

    stdout = stdout_buf.getvalue()
    stderr = stderr_buf.getvalue()

    stdout = _truncate(stdout, max_output)
    stderr = _truncate(stderr, max_output)

    return stdout, stderr, error


def _truncate(text, max_chars):
    """Truncate at a line boundary, preserving head and tail."""
    if len(text) <= max_chars:
        return text
    lines = text.splitlines(keepends=True)
    total = len(lines)
    head = []
    tail = []
    head_chars = 0
    tail_chars = 0
    budget = max_chars - 80  # reserve space for the ellipsis line
    hi, ti = 0, total - 1
    # Alternate: take from head, then tail
    while hi <= ti:
        if head_chars <= tail_chars and head_chars + len(lines[hi]) <= budget:
            head.append(lines[hi])
            head_chars += len(lines[hi])
            hi += 1
        elif tail_chars + len(lines[ti]) <= budget:
            tail.append(lines[ti])
            tail_chars += len(lines[ti])
            ti -= 1
        else:
            break
    tail.reverse()
    omitted = total - len(head) - len(tail)
    if omitted > 0:
        msg = f"\n... {omitted} lines omitted ({len(text)} chars total) ...\n"
    else:
        msg = f"\n... truncated ({len(text)} chars total) ...\n"
    return "".join(head) + msg + "".join(tail)


def parse_cmd_file(text):
    """Parse a cmd.py file. First line is '# %% id: xxx cwd: /path cell: label', rest is code.

    Returns (code, cmd_id, cmd_cwd, cell_label, notebook_path).
    When notebook_path is set, the daemon should read that file and execute all cells.
    """
    lines = text.split("\n")
    cmd_id = ""
    cmd_cwd = ""
    cell_label = ""
    notebook_path = ""
    if lines and (lines[0].startswith("#%%") or lines[0].startswith("# %%")):
        header = lines[0]
        if "id:" in header:
            rest = header.split("id:", 1)[1]
            # Extract cwd if present
            if "cwd:" in rest:
                cmd_id = rest.split("cwd:", 1)[0].strip()
                rest = rest.split("cwd:", 1)[1]
            else:
                cmd_id = rest.strip()
                rest = ""
            # Extract notebook path if present (server-side multi-cell execution)
            if "notebook:" in rest:
                cmd_cwd = rest.split("notebook:", 1)[0].strip()
                notebook_path = rest.split("notebook:", 1)[1].strip()
            # Extract cell label if present
            elif "cell:" in rest:
                cmd_cwd = rest.split("cell:", 1)[0].strip()
                cell_label = rest.split("cell:", 1)[1].strip()
            else:
                cmd_cwd = rest.strip()
        lines = lines[1:]
    code = "\n".join(lines)
    return code, cmd_id, cmd_cwd, cell_label, notebook_path


def _split_notebook(text):
    """Split a .py notebook into cells based on # %% markers."""
    parts = re.split(r"(?m)^# ?%%[^\n]*\n", text)
    if re.match(r"# ?%%", text):
        return parts[1:]  # skip empty first split before first marker
    return parts


def activate_venv(venv_path):
    """Activate a virtual environment by adding its site-packages to sys.path."""
    venv_path = os.path.abspath(venv_path)
    if not os.path.isdir(venv_path):
        print(f"pyreplab: venv not found: {venv_path}", file=sys.stderr)
        return False

    # Find site-packages: lib/pythonX.Y/site-packages (unix) or Lib/site-packages (windows)
    patterns = [
        os.path.join(venv_path, "lib", "python*", "site-packages"),
        os.path.join(venv_path, "Lib", "site-packages"),
    ]
    site_dirs = []
    for pattern in patterns:
        site_dirs.extend(glob.glob(pattern))

    if not site_dirs:
        print(f"pyreplab: no site-packages found in {venv_path}", file=sys.stderr)
        return False

    for sp in site_dirs:
        site.addsitedir(sp)

    # Set VIRTUAL_ENV so tools/subprocesses know we're in a venv
    os.environ["VIRTUAL_ENV"] = venv_path
    # Prepend venv bin to PATH so subprocess calls find the right python/pip
    bin_dir = os.path.join(venv_path, "bin")
    if not os.path.isdir(bin_dir):
        bin_dir = os.path.join(venv_path, "Scripts")  # Windows
    if os.path.isdir(bin_dir):
        os.environ["PATH"] = bin_dir + os.pathsep + os.environ.get("PATH", "")

    print(f"pyreplab: activated venv {venv_path} ({', '.join(site_dirs)})", file=sys.stderr)
    return True


def _find_env_in_bounds(start, root):
    """Walk upward from `start` to `root` (inclusive) looking for an environment.

    Checks for `.venv` (venv/uv convention) and `.pixi/envs/<name>` (pixi
    convention) at each level; the nearest one wins. If `start` is not under
    `root` (e.g. legacy `--workdir` launched from elsewhere), the root itself
    is checked as a final fallback so `--workdir /proj` still finds
    `/proj/.venv`.
    """
    start = os.path.abspath(start)
    root = os.path.abspath(root)
    name = os.environ.get("PIXI_ENVIRONMENT_NAME", "default")

    def _env_in(d):
        venv = os.path.join(d, ".venv")
        if os.path.isdir(venv):
            return venv, "venv"
        pixi = os.path.join(d, ".pixi", "envs", name)
        if os.path.isdir(pixi):
            return pixi, "pixi"
        # pixi with named envs: if `default` is missing but exactly one named
        # env exists, use it
        pixi_envs = os.path.join(d, ".pixi", "envs")
        if os.path.isdir(pixi_envs):
            named = [e for e in os.listdir(pixi_envs) if os.path.isdir(os.path.join(pixi_envs, e))]
            if len(named) == 1:
                return os.path.join(pixi_envs, named[0]), "pixi"
        return None, None

    d = start
    reached_root = False
    while True:
        env_path, env_type = _env_in(d)
        if env_path:
            return env_path, env_type
        if d == root:
            reached_root = True
            break
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    if not reached_root:
        env_path, env_type = _env_in(root)
        if env_path:
            return env_path, env_type
    return None, None


def _reexec_under_env(env_path):
    """Re-exec the daemon under the environment's own python.

    site.addsitedir() alone leaves the daemon running under whatever python
    the bash launcher found on PATH; if that version differs from the env's,
    compiled extensions (numpy/pandas/...) fail with cryptic errors, and for
    a real venv sys.executable/sys.prefix point at the base interpreter
    instead of the venv. Re-exec makes interpreter, site-packages, sys.prefix
    and .pyc caches consistent.

    Loop guard: a venv's bin/python is a symlink to the same base binary, so
    the binary realpaths match even when the daemon was launched with the base
    interpreter. Two cases:
    - Real venv (pyvenv.cfg present): sys.prefix distinguishes "already in the
      venv" from "same binary, outside the venv" — only skip when both the
      binary and sys.prefix match the env.
    - Non-venv env (conda/pixi dirs, fake venvs in tests, no pyvenv.cfg):
      sys.prefix never changes, so re-exec would loop forever; skip when the
      binary matches (re-exec only matters there for version consistency).
    """
    bin_dir = os.path.join(env_path, "bin")
    if not os.path.isdir(bin_dir):
        bin_dir = os.path.join(env_path, "Scripts")  # Windows
    env_python = os.path.join(bin_dir, "python" if os.name != "nt" else "python.exe")
    if not os.path.isfile(env_python):
        return
    try:
        same_binary = os.path.realpath(env_python) == os.path.realpath(sys.executable)
        is_real_venv = os.path.isfile(os.path.join(env_path, "pyvenv.cfg"))
        already_under_env = (
            same_binary
            and (not is_real_venv or os.path.realpath(sys.prefix) == os.path.realpath(env_path))
        )
    except OSError:
        return
    if already_under_env:
        return
    print(f"pyreplab: re-executing under {env_python}", file=sys.stderr)
    os.execv(env_python, [env_python] + sys.argv)


_MANAGED_CWD = [None]  # module state: the cwd entry we manage in sys.path


def _sync_cwd_to(target):
    """chdir to `target` and enforce sys.path[0] == os.getcwd().

    The previous managed entry is removed and duplicates of the new cwd are
    dropped, so sys.path never accumulates caller directories (imports always
    resolve against the current execution directory, `python script.py`
    style). Returns False if the target no longer exists.
    """
    if not os.path.isdir(target):
        return False
    os.chdir(target)
    cwd = os.getcwd()
    prev = _MANAGED_CWD[0]
    if prev is not None and prev in sys.path:
        sys.path.remove(prev)
    while cwd in sys.path:
        sys.path.remove(cwd)
    sys.path.insert(0, cwd)
    _MANAGED_CWD[0] = cwd
    return True


def find_conda_base():
    """Find conda base environment. Checks $CONDA_PREFIX, $CONDA_EXE, then common paths."""
    # 1. Active conda env
    conda_prefix = os.environ.get("CONDA_PREFIX")
    if conda_prefix and os.path.isdir(conda_prefix):
        return conda_prefix

    # 2. Derive from conda executable path (e.g. ~/miniconda3/bin/conda → ~/miniconda3)
    conda_exe = os.environ.get("CONDA_EXE")
    if conda_exe:
        base = os.path.dirname(os.path.dirname(os.path.abspath(conda_exe)))
        if os.path.isdir(base):
            return base

    # 3. Common install locations
    home = os.path.expanduser("~")
    candidates = [
        os.path.join(home, "miniconda3"),
        os.path.join(home, "anaconda3"),
        os.path.join(home, "miniforge3"),
        os.path.join(home, "mambaforge"),
        "/opt/conda",
        "/opt/homebrew/Caskroom/miniconda/base",
    ]
    for path in candidates:
        if os.path.isdir(path):
            return path

    return None


def configure_display(namespace, max_rows=50, max_cols=20, max_colwidth=80, numpy_threshold=100):
    """Set LLM-friendly display limits for pandas/numpy if available."""
    setup = f"""
try:
    import pandas as pd
    pd.set_option('display.max_rows', {max_rows})
    pd.set_option('display.min_rows', {max_rows})
    pd.set_option('display.max_columns', {max_cols})
    pd.set_option('display.max_colwidth', {max_colwidth})
    pd.set_option('display.width', 200)
except ImportError:
    pass
try:
    import numpy as np
    np.set_printoptions(threshold={numpy_threshold}, linewidth=200, edgeitems=5)
except ImportError:
    pass
"""
    exec(compile(setup, "<pyreplab:display>", "exec"), namespace)


def append_history(session_dir, index, code, stdout, stderr, error):
    """Append an execution record to history.md in the session directory."""
    history_path = os.path.join(session_dir, "history.md")
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    with open(history_path, "w" if index == 0 else "a") as f:
        if index == 0:
            f.write(f"# pyreplab session history\n\n")

        f.write(f"## [{index}] {timestamp}\n\n")
        f.write(f"```python\n{code.strip()}\n```\n\n")

        if stdout.strip():
            f.write(f"**Output:**\n```\n{stdout.rstrip()}\n```\n\n")
        if stderr.strip():
            f.write(f"**Stderr:**\n```\n{stderr.rstrip()}\n```\n\n")
        if error:
            f.write(f"**Error:**\n```\n{error.rstrip()}\n```\n\n")

        f.write("---\n\n")


def cleanup(session_dir):
    """Remove session files on shutdown."""
    for name in ("cmd.py", "cmd.py.tmp", "output.json", "output.json.tmp", "done", "pending_id", "pending_start",
                 "progress.json", "progress.json.tmp"):
        path = os.path.join(session_dir, name)
        if os.path.exists(path):
            os.remove(path)


def main():
    parser = argparse.ArgumentParser(
        description="Persistent Python REPL for LLM CLI tools",
        epilog=(
            "Sessions are keyed to a project root: auto-discovered from the nearest "
            "ancestor containing .git or pyproject.toml (see `pyreplab help` for the "
            "full environment auto-detection order)."
        ),
    )
    parser.add_argument("--session-dir", default="/tmp/pyreplab", help="Session directory (resolved by the CLI; override with PYREPLAB_DIR)")
    parser.add_argument("--session-root", default=None, help="Canonical project root (resolved by the CLI)")
    parser.add_argument("--workdir", default=None, help="[deprecated] alias for --session-root")
    parser.add_argument("--cwd", default=None,
                        help="Lock the REPL's working directory to DIR (sticky). Without it, each command runs in the caller's shell directory")
    parser.add_argument("--venv", default=None,
                        help="Explicit virtualenv (venv/uv) to activate, e.g. /project/.venv")
    parser.add_argument("--conda", default=None, nargs="?", const="base",
                        help="Activate a conda environment (default: base). Use --conda for base, --conda envname for a named env")
    parser.add_argument("--no-conda", action="store_true",
                        help="Disable automatic conda base fallback (explicit --conda still works)")
    parser.add_argument("--max-output", type=int, default=100_000, help="Max output chars per command (default: 100000)")
    parser.add_argument("--max-rows", type=int, default=50, help="Pandas max display rows (default: 50)")
    parser.add_argument("--max-cols", type=int, default=20, help="Pandas max display columns (default: 20)")
    parser.add_argument("--poll-interval", type=float, default=0.05, help="Poll interval in seconds (default: 0.05)")
    parser.add_argument("--progress-interval", type=float, default=1.0,
                        help="Seconds between progress.json snapshots while executing (0 disables, default: 1.0)")
    args = parser.parse_args()

    # --- Resolve session root and working directory ---
    session_root = os.path.abspath(args.session_root or args.workdir or os.getcwd())
    session_dir = args.session_dir
    os.makedirs(session_dir, exist_ok=True)

    # --cwd is sticky: chdir once at startup, skip per-command sync.
    # Without --cwd: follow the caller's shell directory on every run.
    cwd_locked = args.cwd is not None
    if args.cwd is not None:
        if not os.path.isdir(args.cwd):
            print(f"pyreplab: --cwd not found: {args.cwd}", file=sys.stderr)
            sys.exit(1)
        os.chdir(args.cwd)

    # --- Environment auto-detection ---
    # Priority: --venv > $PIXI_ENVIRONMENT_PREFIX > nearest .venv (venv/uv)
    # or .pixi/envs/<name> (pixi) on the way to the session root > conda.
    venv_path = args.venv
    env_type = "venv"
    if venv_path is None:
        pixi_prefix = os.environ.get("PIXI_ENVIRONMENT_PREFIX", "")
        if pixi_prefix and os.path.isdir(pixi_prefix):
            venv_path = pixi_prefix
            env_type = "pixi"
    if venv_path is None:
        found, found_type = _find_env_in_bounds(os.getcwd(), session_root)
        if found:
            venv_path, env_type = found, found_type
    if venv_path is None and not args.no_conda:
        if args.conda:
            conda_base = find_conda_base()
            if conda_base:
                if args.conda == "base":
                    venv_path, env_type = conda_base, "conda"
                else:
                    candidate = os.path.join(conda_base, "envs", args.conda)
                    if os.path.isdir(candidate):
                        venv_path, env_type = candidate, "conda"
                    else:
                        print(f"pyreplab: conda env '{args.conda}' not found at {candidate}", file=sys.stderr)
            else:
                print("pyreplab: conda not found", file=sys.stderr)
        else:
            conda_base = find_conda_base()
            if conda_base:
                venv_path, env_type = conda_base, "conda"

    # Run under the env's own interpreter (version-consistent imports), then
    # add its site-packages to sys.path.
    if venv_path:
        _reexec_under_env(venv_path)
        activate_venv(venv_path)

    # Enforce sys.path[0] == execution cwd (sticky: locked dir; follow:
    # the daemon's start directory until the first command syncs it).
    _sync_cwd_to(os.getcwd())

    # Record resolved session configuration for `pyreplab status` / `ps`
    atomic_write(os.path.join(session_dir, "session.json"), {
        "session_dir": session_dir,
        "session_root": session_root,
        "mode": "sticky" if cwd_locked else "follow",
        "cwd": os.getcwd(),
        "env": {
            "type": env_type if venv_path else "none",
            "path": os.path.abspath(venv_path) if venv_path else None,
            "python": sys.executable,
            "version": sys.version.split()[0],
        },
        "options": {
            "max_output": args.max_output,
            "max_rows": args.max_rows,
            "max_cols": args.max_cols,
            "poll_interval": args.poll_interval,
            "progress_interval": args.progress_interval,
        },
    })

    # Clean any stale files from a previous run
    cleanup(session_dir)

    cmd_path = os.path.join(session_dir, "cmd.py")
    output_path = os.path.join(session_dir, "output.json")
    done_path = os.path.join(session_dir, "done")

    namespace = {"__name__": "__pyreplab__", "__builtins__": __builtins__}
    configure_display(namespace, max_rows=args.max_rows, max_cols=args.max_cols)
    exec_index = 0
    running = True

    def shutdown(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    def cancel_handler(signum, frame):
        if _executing:
            raise KeyboardInterrupt("Cancelled by pyreplab cancel")

    signal.signal(signal.SIGUSR1, cancel_handler)

    print(f"pyreplab: python {sys.version.split()[0]} ({sys.executable})", file=sys.stderr)
    print(f"pyreplab: listening on {session_dir} (poll={args.poll_interval}s)", file=sys.stderr)

    while running:
        if not os.path.exists(cmd_path):
            time.sleep(args.poll_interval)
            continue

        try:
            with open(cmd_path) as f:
                text = f.read()
        except IOError:
            time.sleep(args.poll_interval)
            continue

        os.remove(cmd_path)

        code, cmd_id, cmd_cwd, cell_label, notebook_path = parse_cmd_file(text)

        # Sync working directory and sys.path to caller's cwd (skip if --cwd locked it).
        # If the caller's directory no longer exists, fail the command instead of
        # silently executing in a stale directory.
        if not cwd_locked and cmd_cwd:
            if not _sync_cwd_to(cmd_cwd):
                atomic_write(output_path, {
                    "stdout": "", "stderr": "",
                    "error": f"pyreplab: caller cwd no longer exists: {cmd_cwd}",
                    "id": cmd_id,
                })
                with open(done_path, "w") as f:
                    f.write(cmd_id)
                continue

        global _executing

        # Progress monitoring for this command: a thread snapshots partial
        # output into progress.json while the command runs.
        progress_state = {
            "stdout": None, "stderr": None,
            "cell": cell_label, "id": cmd_id, "start": time.time(),
        }
        stop_progress = threading.Event()
        progress_thread = None
        if args.progress_interval > 0:
            progress_thread = threading.Thread(
                target=_progress_worker,
                args=(progress_state, stop_progress, session_dir, args.progress_interval),
                daemon=True,
            )
            progress_thread.start()

        try:
            if notebook_path:
                # Server-side notebook execution: read file, split cells, run all sequentially
                try:
                    with open(notebook_path) as f:
                        nb_text = f.read()
                except IOError as e:
                    atomic_write(output_path, {
                        "stdout": "", "stderr": "",
                        "error": f"pyreplab: cannot read notebook: {e}",
                        "id": cmd_id,
                    })
                    with open(done_path, "w") as f:
                        f.write(cmd_id)
                    continue

                cells = _split_notebook(nb_text)
                nb_base = os.path.basename(notebook_path)
                all_stdout = []
                all_stderr = []
                error = None

                for i, cell_code in enumerate(cells):
                    if not cell_code.strip():
                        continue
                    _executing = True
                    try:
                        progress_state["cell"] = f"{nb_base}:{i}"
                        stdout, stderr, err = run_code(
                            cell_code, namespace,
                            max_output=args.max_output,
                            label=f"{nb_base}:{i}",
                            progress_state=progress_state,
                        )
                    finally:
                        _executing = False

                    all_stdout.append(stdout)
                    all_stderr.append(stderr)
                    append_history(session_dir, exec_index, cell_code, stdout, stderr, err)
                    exec_index += 1

                    if err:
                        error = f"[cell {nb_base}:{i}] {err}"
                        break

                atomic_write(output_path, {
                    "stdout": "".join(all_stdout),
                    "stderr": "".join(all_stderr),
                    "error": error,
                    "id": cmd_id,
                })
                with open(done_path, "w") as f:
                    f.write(cmd_id)
            else:
                # Single command execution
                _executing = True
                try:
                    stdout, stderr, error = run_code(
                        code, namespace, max_output=args.max_output, label=cell_label,
                        progress_state=progress_state,
                    )
                finally:
                    _executing = False

                append_history(session_dir, exec_index, code, stdout, stderr, error)
                exec_index += 1

                atomic_write(output_path, {
                    "stdout": stdout,
                    "stderr": stderr,
                    "error": error,
                    "id": cmd_id,
                })

                # Signal completion
                with open(done_path, "w") as f:
                    f.write(cmd_id)
        finally:
            # Stop the progress monitor and drop progress.json (the next
            # command starts with a clean slate). Join unconditionally — the
            # worker only writes small files to local /tmp and exits promptly
            # once stop_event is set, so a zombie writer can never recreate
            # progress.json after we remove it.
            stop_progress.set()
            if progress_thread is not None:
                progress_thread.join()
            for name in ("progress.json", "progress.json.tmp"):
                try:
                    os.remove(os.path.join(session_dir, name))
                except OSError:
                    pass

    cleanup(session_dir)
    print("pyreplab: shutdown", file=sys.stderr)


if __name__ == "__main__":
    main()
