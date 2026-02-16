#!/usr/bin/env bash
# pyrepl.sh — Shell helper for pyrepl
# Source this file, then use: pyrun 'python code here'

PYREPL_DIR="${PYREPL_DIR:-/tmp/pyrepl}"

pyrun() {
    local code="$1"
    local id
    id="cmd_$$_$(date +%s%N 2>/dev/null || echo $RANDOM)"
    local cmd_path="$PYREPL_DIR/cmd.json"
    local done_path="$PYREPL_DIR/done"
    local output_path="$PYREPL_DIR/output.json"
    local timeout="${PYREPL_TIMEOUT:-30}"

    # Remove stale done flag
    rm -f "$done_path"

    # Write command (atomic: write tmp, then move)
    printf '{"code": %s, "id": "%s"}' "$(printf '%s' "$code" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" "$id" > "$cmd_path.tmp"
    mv "$cmd_path.tmp" "$cmd_path"

    # Poll for completion
    local elapsed=0
    while [ ! -f "$done_path" ]; do
        sleep 0.1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$((timeout * 10))" ]; then
            echo "pyrun: timed out waiting for response" >&2
            return 1
        fi
    done

    # Read and display output
    local result
    result=$(cat "$output_path")
    local stdout stderr error
    stdout=$(printf '%s' "$result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("stdout",""),end="")')
    stderr=$(printf '%s' "$result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("stderr",""),end="")')
    error=$(printf '%s' "$result" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d.get("error"); print(e if e else "",end="")')

    [ -n "$stdout" ] && printf '%s\n' "$stdout"
    [ -n "$stderr" ] && printf '%s\n' "$stderr" >&2
    if [ -n "$error" ]; then
        printf '%s\n' "$error" >&2
        return 1
    fi
    return 0
}
