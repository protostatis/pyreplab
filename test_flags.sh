#!/usr/bin/env bash
# test_flags.sh — session/flag redesign tests (auto-discovery, --cwd semantics,
# env walk for venv/uv/pixi/conda, re-exec, --session-dir, missing cwd)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR="$SCRIPT_DIR/pyreplab"
export PYREPLAB_STAMP=0

BASE="$(cd -P "$(mktemp -d /tmp/pyreplab_flags_XXXX)" && pwd -P)"  # physical path (macOS /tmp -> /private/tmp)
PIDS=()
cleanup() {
    for p in ${PIDS[@]+"${PIDS[@]}"}; do
        kill -9 "$p" 2>/dev/null || true
    done
    for p in $(pgrep -f "pyreplab.py --session-dir" 2>/dev/null || true); do
        kill -9 "$p" 2>/dev/null || true
    done
    rm -rf "$BASE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

pass=0; fail=0; skip=0
check() {
    local label="$1" result="$2" detail="${3:-}"
    if [ "$result" = "ok" ]; then
        echo "  PASS: $label"
        pass=$((pass + 1))
    elif [ "$result" = "skip" ]; then
        echo "  SKIP: $label — $detail"
        skip=$((skip + 1))
    else
        echo "  FAIL: $label — $detail"
        fail=$((fail + 1))
    fi
}

# Start a session in the given dir (or with extra args), tracking the daemon.
# The session dir is parsed from start's output, so --cwd sessions (whose
# identity derives from the --cwd target) are found too.
new_session() {  # new_session <dir> [extra start args...]
    local dir="$1"; shift
    PIDS=()
    # Stop any daemon for the session we are about to (re)start — sessions
    # persist across tests otherwise, and start would report "already running"
    local pre_sdir=""
    pre_sdir=$(cd "$dir" && "$PR" dir 2>/dev/null || true)
    if [ -n "$pre_sdir" ] && [ -f "$pre_sdir/pyreplab.pid" ]; then
        PYREPLAB_DIR="$pre_sdir" "$PR" stop >/dev/null 2>&1
    fi
    local out sdir pid=""
    out=$(cd "$dir" && "$PR" start "$@" 2>&1)
    sdir=$(printf '%s' "$out" | sed -n 's/.*dir \(.*\)) *$/\1/p' | tail -1)
    [ -n "$sdir" ] && [ -f "$sdir/pyreplab.pid" ] && pid=$(cat "$sdir/pyreplab.pid")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        PIDS+=("$pid")
    fi
    echo "$pid"
}

root_hash() {  # md5 of a canonical path, first 8 chars
    printf '%s' "$1" | md5 -q 2>/dev/null | cut -c1-8
}

echo "=== session/flag redesign tests ==="
echo "base: $BASE"

# ---------------------------------------------------------
echo ""
echo "== T1 root discovery (.git > pyproject.toml > fallback) =="
mkdir -p "$BASE/gitproj/sub" "$BASE/pytproj/sub" "$BASE/plain/sub"
mkdir -p "$BASE/gitproj/.git"; touch "$BASE/pytproj/pyproject.toml"
expected_git="$BASE/pyreplab/../.."  # placeholder
for tcase in "gitproj/sub:gitproj" "pytproj/sub:pytproj" "plain/sub:plain/sub"; do
    sub="${tcase%%:*}"; rootname="${tcase##*:}"
    out=$(cd "$BASE/$sub" && "$PR" dir)
    want="$BASE/../$(echo $BASE | sed 's|.*/||')"  # unused
    want_session="$BASE/../../tmp/pyreplab"  # unused
    # expected: /tmp/pyreplab/<rootname>_<hash of canonical root>
    root=$(cd -P "$BASE/$rootname" && pwd -P)
    want="/tmp/pyreplab/$(basename "$root")_$(root_hash "$root")"
    if [ "$out" = "$want" ]; then
        check "discovery from $sub -> $rootname" ok
    else
        check "discovery from $sub -> $rootname" fail "got $out want $want"
    fi
done
# .git wins over pyproject.toml in the same tree
mkdir -p "$BASE/both/sub"
touch "$BASE/both/.git" "$BASE/both/pyproject.toml"
out=$(cd "$BASE/both/sub" && "$PR" dir)
want="/tmp/pyreplab/both_$(root_hash "$(cd -P "$BASE/both" && pwd -P)")"
[ "$out" = "$want" ] \
    && check ".git preferred over pyproject.toml" ok \
    || check ".git preferred over pyproject.toml" fail "got $out"

# ---------------------------------------------------------
echo ""
echo "== T2 follow mode: execution dir follows the caller =="
mkdir -p "$BASE/follow/a" "$BASE/follow/b"; touch "$BASE/follow/pyproject.toml"
pid=$(new_session "$BASE/follow")
[ -n "$pid" ] && check "follow session started" ok || check "follow session started" fail "no pid"
out=$(cd "$BASE/follow/a" && "$PR" run 'import os; print(os.getcwd())')
[ "$out" = "$(cd -P "$BASE/follow/a" && pwd -P)" ] \
    && check "run from a -> cwd=a" ok || check "run from a -> cwd=a" fail "got $out"
out=$(cd "$BASE/follow/b" && "$PR" run 'import os; print(os.getcwd())')
[ "$out" = "$(cd -P "$BASE/follow/b" && pwd -P)" ] \
    && check "run from b -> cwd=b" ok || check "run from b -> cwd=b" fail "got $out"
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T3 sticky mode + --cwd-only identity isolation =="
mkdir -p "$BASE/proj1/sub" "$BASE/proj2/sub"
touch "$BASE/proj1/pyproject.toml" "$BASE/proj2/pyproject.toml"
pid=$(new_session "$BASE/proj1" --cwd "$BASE/proj1/sub")
[ -n "$pid" ] && check "sticky session started" ok || check "sticky session started" fail "no pid"
out=$(cd "$BASE/proj1" && "$PR" run 'import os; print(os.getcwd())')
[ "$out" = "$(cd -P "$BASE/proj1/sub" && pwd -P)" ] \
    && check "--cwd pins execution dir (sticky)" ok \
    || check "--cwd pins execution dir (sticky)" fail "got $out"
# identity derives from --cwd: state must not bleed between two --cwd projects
"$PR" run 'bleed = 42' >/dev/null 2>&1
"$PR" stop >/dev/null 2>&1
pid=$(new_session "$BASE/proj2" --cwd "$BASE/proj2/sub")
[ -n "$pid" ] && check "second --cwd session started" ok \
    || check "second --cwd session started" fail "no pid"
out=$(cd "$BASE/proj2" && "$PR" run 'print(bleed)' 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qi "NameError"; then
    check "no state bleed between --cwd sessions (separate namespaces)" ok
else
    check "no state bleed between --cwd sessions" fail "rc=$rc out=$out"
fi
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T4 sys.path invariant: sys.path[0] == current exec dir, no accumulation =="
mkdir -p "$BASE/sp/a" "$BASE/sp/b" "$BASE/sp/c"; touch "$BASE/sp/pyproject.toml"
printf 'X = "from-a"\n' > "$BASE/sp/a/mod.py"
printf 'X = "from-b"\n' > "$BASE/sp/b/mod.py"
pid=$(new_session "$BASE/sp")
[ -n "$pid" ] && check "sys.path session started" ok || check "sys.path session started" fail "no pid"
out=$(cd "$BASE/sp/a" && "$PR" run 'import mod; print(mod.X)')
[ "$out" = "from-a" ] && check "import resolves in caller dir a" ok || check "import resolves in caller dir a" fail "got $out"
out=$(cd "$BASE/sp/b" && "$PR" run 'import mod; print(mod.X)')
[ "$out" = "from-a" ] && check "import mod from b returns cached module (persistent-REPL sys.modules semantics)" ok || check "import mod from b returns cached module" fail "got $out"
printf 'X = "from-b"
' > "$BASE/sp/b/mod2.py"
out=$(cd "$BASE/sp/b" && "$PR" run 'import mod2; print(mod2.X)')
[ "$out" = "from-b" ] && check "fresh import resolves in caller dir b" ok || check "fresh import resolves in caller dir b" fail "got $out"
out=$(cd "$BASE/sp/b" && "$PR" run 'import sys; print(sys.path[0])')
[ "$out" = "$(cd -P "$BASE/sp/b" && pwd -P)" ] && check "sys.path[0] == exec dir" ok || check "sys.path[0] == exec dir" fail "got $out"
l1=$(cd "$BASE/sp/c" && "$PR" run 'import sys; print(len(sys.path))' 2>/dev/null || true)
l2=$(cd "$BASE/sp/c" && "$PR" run 'import sys; print(len(sys.path))' 2>/dev/null || true)
[ -n "$l1" ] && [ "$l1" = "$l2" ] \
    && check "sys.path length stable across commands (no accumulation)" ok \
    || check "sys.path length stable across commands" fail "l1=$l1 l2=$l2"
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T5 --session-dir resolved once (split-brain fixed) + deprecation =="
mkdir -p "$BASE/sd"
out=$(cd "$BASE/sd" && "$PR" start --session-dir "$BASE/custom_sess" 2>&1)
echo "$out" | grep -q "deprecated" \
    && check "--session-dir prints deprecation warning" ok \
    || check "--session-dir prints deprecation warning" fail "out=$out"
pid=$(cat "$BASE/custom_sess/pyreplab.pid" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && check "daemon actually listening in the custom session dir" ok \
    || check "daemon actually listening in the custom session dir" fail
out=$(PYREPLAB_DIR="$BASE/custom_sess" "$PR" run 'print("custom-sess-works")')
[ "$out" = "custom-sess-works" ] \
    && check "run works against the custom session dir" ok \
    || check "run works against the custom session dir" fail "out=$out"
PYREPLAB_DIR="$BASE/custom_sess" "$PR" stop >/dev/null 2>&1
out=$(cd "$BASE/sd" && "$PR" start --workdir "$BASE/sd" 2>&1)
echo "$out" | grep -q "deprecated" \
    && check "--workdir prints deprecation warning" ok \
    || check "--workdir prints deprecation warning" fail "out=$out"
PYREPLAB_DIR="$(cd "$BASE/sd" && "$PR" dir)" "$PR" stop >/dev/null 2>&1
rm -rf "$BASE/custom_sess"

# ---------------------------------------------------------
echo ""
echo "== T6 missing caller cwd -> command error, no stale execution =="
mkdir -p "$BASE/mc"
pid=$(new_session "$BASE/mc")
[ -n "$pid" ] && check "missing-cwd session started" ok || check "missing-cwd session started" fail "no pid"
out=$(cd "$BASE/mc" && "$PR" run 'import os; print(os.getcwd())')
[ "$out" = "$(cd -P "$BASE/mc" && pwd -P)" ] && check "baseline sync works" ok || check "baseline sync works" fail
# simulate a caller whose cwd was deleted: craft a command whose header cwd
# points at a directory that is removed before the daemon picks it up
mkdir -p "$BASE/gone"
sdir=$(cd "$BASE/mc" && "$PR" dir)
printf '#%%%% id: cmd_manual cwd: %s\nprint("never")\n' "$BASE/gone" > "$sdir/cmd.py"
printf 'cmd_manual' > "$sdir/pending_id"
date +%s > "$sdir/pending_start"
rm -rf "$BASE/gone"
out=$(cd "$BASE/mc" && "$PR" wait 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "no longer exists"; then
    check "deleted caller cwd -> explicit error, no stale run" ok
else
    check "deleted caller cwd -> explicit error" fail "rc=$rc out=$out"
fi
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T7 env walk: .venv (venv/uv) found between dir and root =="
mkdir -p "$BASE/envroot" "$BASE/envroot/sub"
touch "$BASE/envroot/pyproject.toml"
fakevenv="$BASE/envroot/.venv"
mkdir -p "$fakevenv/bin" "$fakevenv/lib/python3.99/site-packages"
ln -sf "$(command -v python3)" "$fakevenv/bin/python"
pid=$(new_session "$BASE/envroot/sub")
[ -n "$pid" ] && check "env-walk session started" ok || check "env-walk session started" fail "no pid"
st=$(cd "$BASE/envroot/sub" && "$PR" status 2>&1)
sdir_t7=$(cd "$BASE/envroot/sub" && "$PR" dir)
echo "  [debug] sdir=$sdir_t7 files=$(ls "$sdir_t7" | tr '\n' ' ')"
[ -f "$sdir_t7/session.json" ] && echo "  [debug] session.json env line: $(python3 -c 'import json; d=json.load(open("'$sdir_t7'/session.json")); print(d.get("env"))')"
echo "$st" | grep -q "env venv:$fakevenv" \
    && check "status shows auto-detected .venv from subdir" ok \
    || check "status shows auto-detected .venv from subdir" fail "status=$st"
log="$(cd "$BASE/envroot/sub" && "$PR" dir)/daemon.log"
grep -q "activated venv" "$log" 2>/dev/null \
    && check "daemon.log records activation" ok \
    || check "daemon.log records activation" fail "log=$log"
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T7b same-binary real venv (pyvenv.cfg): --venv runs under the venv python =="
rm -rf "$BASE/envroot/.venv" "$BASE/envroot/.pixi"
fakevenv="$BASE/envroot/.venv"
mkdir -p "$fakevenv/bin" "$fakevenv/lib/python3.99/site-packages"
ln -sf "$(command -v python3)" "$fakevenv/bin/python"
# A venv's bin/python is a symlink to the base interpreter; pyvenv.cfg makes
# CPython treat it as a real venv. Regression: the old re-exec guard compared
# only binary realpaths, so a venv created from the same python3 as the
# pyreplab launcher was never re-exec'd into — sys.executable stayed at the
# launcher's python instead of the venv's.
base_py="$(realpath "$(command -v python3)")"
base_bin="$(dirname "$base_py")"
version=$("$base_py" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
printf 'home = %s\nversion = %s\ninclude-system-site-packages = false\nexecutable = %s\n' \
    "$base_bin" "$version" "$base_py" > "$fakevenv/pyvenv.cfg"
pid=$(new_session "$BASE/envroot/sub" --venv "$fakevenv")
[ -n "$pid" ] && check "same-binary venv session started" ok || check "same-binary venv session started" fail "no pid"
out=$(cd "$BASE/envroot/sub" && "$PR" run 'import sys; print(sys.executable); print(sys.prefix); print(sys.base_prefix)')
exec_py=$(printf '%s' "$out" | sed -n '1p')
pref=$(printf '%s' "$out" | sed -n '2p')
base=$(printf '%s' "$out" | sed -n '3p')
[ "$exec_py" = "$fakevenv/bin/python" ] \
    && check "run executes under the venv python, not the launcher's python3" ok \
    || check "run executes under the venv python, not the launcher's python3" fail "executable=$exec_py"
[ "$pref" = "$fakevenv" ] && [ "$pref" != "$base" ] \
    && check "sys.prefix is the venv, sys.base_prefix is the base" ok \
    || check "sys.prefix is the venv, sys.base_prefix is the base" fail "prefix=$pref base=$base"
log="$(cd "$BASE/envroot/sub" && "$PR" dir)/daemon.log"
grep -q "re-executing under" "$log" \
    && check "daemon re-executed into the same-binary venv" ok \
    || check "daemon re-executed into the same-binary venv" fail "log: $(grep -m1 python "$log" 2>/dev/null || echo empty)"
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T8 env walk: pixi (.pixi/envs/default) =="
rm -rf "$BASE/envroot/.venv"
mkdir -p "$BASE/envroot/.pixi/envs/default/bin" "$BASE/envroot/.pixi/envs/default/lib/python3.99/site-packages"
ln -sf "$(command -v python3)" "$BASE/envroot/.pixi/envs/default/bin/python"
pid=$(new_session "$BASE/envroot/sub")
[ -n "$pid" ] && check "pixi session started" ok || check "pixi session started" fail "no pid"
st=$(cd "$BASE/envroot/sub" && "$PR" status 2>&1)
echo "$st" | grep -q "env pixi:$BASE/envroot/.pixi/envs/default" \
    && check "status shows auto-detected .pixi/envs/default" ok \
    || check "status shows auto-detected .pixi/envs/default" fail "status=$st"
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T9 PIXI_ENVIRONMENT_PREFIX override (pixi run/shell) =="
rm -rf "$BASE/envroot/.pixi"
ext_env="$BASE/external_env"
mkdir -p "$ext_env/bin" "$ext_env/lib/python3.99/site-packages"
ln -sf "$(command -v python3)" "$ext_env/bin/python"
pid=$(PIXI_ENVIRONMENT_PREFIX="$ext_env" new_session "$BASE/envroot/sub")
[ -n "$pid" ] && check "PIXI_ENVIRONMENT_PREFIX session started" ok || check "PIXI_ENVIRONMENT_PREFIX session started" fail "no pid"
st=$(cd "$BASE/envroot/sub" && "$PR" status 2>&1)
echo "$st" | grep -q "env pixi:$ext_env" \
    && check "PIXI_ENVIRONMENT_PREFIX honored" ok \
    || check "PIXI_ENVIRONMENT_PREFIX honored" fail "status=$st"
"$PR" stop >/dev/null 2>&1

# ---------------------------------------------------------
echo ""
echo "== T10 re-exec under env python (version consistency) =="
uv_py=""
for p in "$HOME"/.local/share/uv/python/*/bin/python3*; do
    if [ -x "$p" ] && [ "$(realpath "$p")" != "$(realpath "$(command -v python3)")" ]; then
        uv_py="$p"
        break
    fi
done
if [ -z "$uv_py" ]; then
    check "re-exec under env python" skip "no uv-managed python available"
else
    rm -rf "$BASE/envroot/.venv"
    mkdir -p "$BASE/envroot/.venv/bin" "$BASE/envroot/.venv/lib/python3.99/site-packages"
    ln -sf "$uv_py" "$BASE/envroot/.venv/bin/python"
    pid=$(new_session "$BASE/envroot")
    [ -n "$pid" ] && check "re-exec session started" ok || check "re-exec session started" fail "no pid"
    log="$(cd "$BASE/envroot" && "$PR" dir)/daemon.log"
    sleep 0.5
    grep -q "re-executing under" "$log" \
        && check "daemon re-executed under the env's python" ok \
        || check "daemon re-executed under the env's python" fail "log: $(grep -m1 python "$log" 2>/dev/null || echo empty)"
    exp_ver=$("$uv_py" -c 'import sys; print(sys.version.split()[0])' 2>/dev/null)
    st=$(cd "$BASE/envroot" && "$PR" status 2>&1)
    if [ -n "$exp_ver" ] && echo "$st" | grep -q "python $exp_ver"; then
        check "status reports the env's python version ($exp_ver)" ok
    else
        check "status reports the env's python version ($exp_ver)" fail "status=$st"
    fi
    "$PR" stop >/dev/null 2>&1
fi

# ---------------------------------------------------------
echo ""
echo "== T11 help encodes the agent workflow =="
out=$("$PR" help)
echo "$out" | grep -q "AGENT WORKFLOW" \
    && check "help has AGENT WORKFLOW section" ok || check "help has AGENT WORKFLOW section" fail
echo "$out" | grep -q "ENVIRONMENT AUTO-DETECTION" \
    && check "help has ENVIRONMENT AUTO-DETECTION section" ok || check "help has ENVIRONMENT AUTO-DETECTION section" fail
echo "$out" | grep -q "PYREPLAB_DIR" \
    && check "help documents PYREPLAB_DIR" ok || check "help documents PYREPLAB_DIR" fail

# ---------------------------------------------------------
echo ""
echo "=== Results: $pass passed, $fail failed, $skip skipped ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
