#!/usr/bin/env python3
"""pyrepl — Persistent Python REPL for LLM CLI tools.

A background process that keeps a Python namespace in memory.
Communicates via JSON files in a session directory.
Zero dependencies — stdlib only.
"""

import argparse
import contextlib
import io
import json
import os
import signal
import sys
import time
import traceback


def atomic_write(path, data):
    """Write JSON atomically: write to .tmp, then rename."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.rename(tmp, path)


def run_code(code, namespace, timeout=30, max_output=100_000):
    """Execute code in the persistent namespace, capturing output."""
    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()
    error = None

    try:
        with contextlib.redirect_stdout(stdout_buf), contextlib.redirect_stderr(stderr_buf):
            if timeout:
                old_handler = signal.signal(signal.SIGALRM, _timeout_handler)
                signal.alarm(timeout)
            try:
                exec(compile(code, "<pyrepl>", "exec"), namespace)
            finally:
                if timeout:
                    signal.alarm(0)
                    signal.signal(signal.SIGALRM, old_handler)
    except TimeoutError:
        error = f"Timeout: command exceeded {timeout}s limit"
    except Exception:
        error = traceback.format_exc()

    stdout = stdout_buf.getvalue()
    stderr = stderr_buf.getvalue()

    if len(stdout) > max_output:
        stdout = stdout[:max_output] + f"\n... truncated ({len(stdout)} chars total)"
    if len(stderr) > max_output:
        stderr = stderr[:max_output] + f"\n... truncated ({len(stderr)} chars total)"

    return stdout, stderr, error


def _timeout_handler(signum, frame):
    raise TimeoutError()


def cleanup(session_dir):
    """Remove session files on shutdown."""
    for name in ("cmd.json", "cmd.json.tmp", "output.json", "output.json.tmp", "done"):
        path = os.path.join(session_dir, name)
        if os.path.exists(path):
            os.remove(path)


def main():
    parser = argparse.ArgumentParser(description="Persistent Python REPL for LLM CLI tools")
    parser.add_argument("--session-dir", default="/tmp/pyrepl", help="Session directory (default: /tmp/pyrepl)")
    parser.add_argument("--workdir", default=None, help="Working directory for the REPL")
    parser.add_argument("--timeout", type=int, default=30, help="Per-command timeout in seconds (default: 30)")
    parser.add_argument("--max-output", type=int, default=100_000, help="Max output chars (default: 100000)")
    parser.add_argument("--poll-interval", type=float, default=0.05, help="Poll interval in seconds (default: 0.05)")
    args = parser.parse_args()

    session_dir = args.session_dir
    os.makedirs(session_dir, exist_ok=True)

    if args.workdir:
        os.chdir(args.workdir)

    # Clean any stale files from a previous run
    cleanup(session_dir)

    cmd_path = os.path.join(session_dir, "cmd.json")
    output_path = os.path.join(session_dir, "output.json")
    done_path = os.path.join(session_dir, "done")

    namespace = {"__name__": "__pyrepl__", "__builtins__": __builtins__}
    running = True

    def shutdown(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    print(f"pyrepl: listening on {session_dir} (poll={args.poll_interval}s, timeout={args.timeout}s)", file=sys.stderr)

    while running:
        if not os.path.exists(cmd_path):
            time.sleep(args.poll_interval)
            continue

        try:
            with open(cmd_path) as f:
                cmd = json.load(f)
        except (json.JSONDecodeError, IOError):
            time.sleep(args.poll_interval)
            continue

        os.remove(cmd_path)

        code = cmd.get("code", "")
        cmd_id = cmd.get("id", "")

        stdout, stderr, error = run_code(code, namespace, timeout=args.timeout, max_output=args.max_output)

        atomic_write(output_path, {
            "stdout": stdout,
            "stderr": stderr,
            "error": error,
            "id": cmd_id,
        })

        # Signal completion
        with open(done_path, "w") as f:
            f.write(cmd_id)

    cleanup(session_dir)
    print("pyrepl: shutdown", file=sys.stderr)


if __name__ == "__main__":
    main()
