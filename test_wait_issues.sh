#!/usr/bin/env bash
# test_wait_issues.sh — replicate issues found in the async-wait review
#
# Each test reports:
#   REPRODUCED   — the defect is present in the current code (expected)
#   NOT-REPRODUCED — the defect could not be shown (may be fixed, or timing)
#   INCONCLUSIVE — scheduling-dependent race not observed this run
#
# These are demonstration tests for known defects, not a regression gate.
# Exit code is 0 when the suite completes; per-test verdicts are printed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR="$SCRIPT_DIR/pyreplab"
export PYREPLAB_STAMP=0

SESSION=""
PIDS=()

cleanup() {
    if [ -n "${SESSION:-}" ]; then
        for p in ${PIDS[@]+"${PIDS[@]}"}; do
            kill -9 "$p" 2>/dev/null || true
        done
        # safety net: any daemon still polling this session dir
        for p in $(pgrep -f "pyreplab.py --session-dir $SESSION" 2>/dev/null || true); do
            kill -9 "$p" 2>/dev/null || true
        done
        rm -rf "$SESSION" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP

new_session() {
    cleanup
    SESSION="$(mktemp -d /tmp/pyreplab_issues_XXXX)"
    PIDS=()
    export PYREPLAB_DIR="$SESSION"
    unset PYREPLAB_TIMEOUT || true
}

start_daemon() {
    "$PR" start >/dev/null 2>&1
    PIDS+=("$(cat "$SESSION/pyreplab.pid")")
}

wait_for_file() {  # wait_for_file <path> <max_seconds>
    local path="$1" max="$2" i
    for i in $(seq 1 "$((max * 10))"); do
        [ -f "$path" ] && return 0
        sleep 0.1
    done
    return 1
}

V=()   # per-test verdicts
record() { V+=("$1"); }

echo "======================================================"
echo " pyreplab async-wait issue replication"
echo "======================================================"

# ---------------------------------------------------------
echo ""
echo "== T1 [P1] id validated — stale output rejected (defect fixed) =="
# Craft a session state where pending_id says cmd_NEW but output.json/done
# carry a different id. The client must NOT consume the stale output.
new_session
start_daemon
printf 'cmd_NEW' > "$SESSION/pending_id"
date +%s > "$SESSION/pending_start"
printf '{"stdout": "STALE-FROM-OLD-ID", "stderr": "", "error": null, "id": "cmd_OLD"}\n' > "$SESSION/output.json"
printf 'cmd_OLD' > "$SESSION/done"
out=$("$PR" wait 2>&1); rc=$?
echo "  wait rc=$rc out=[$out]"
if echo "$out" | grep -q STALE-FROM-OLD-ID; then
    echo "  [REPRODUCED] stale output consumed despite id mismatch (cmd_OLD != cmd_NEW)"
    record REPRODUCED
else
    echo "  [VERIFIED] stale output rejected — wait discarded id-mismatched done/output and kept polling (rc=$rc)"
    record VERIFIED
fi

# ---------------------------------------------------------
echo ""
echo "== T2 [P1] clean during execution — no misdelivery (defect fixed) =="
# run A (slow) times out (rc 2). `clean` removes pending_id. run B is then
# accepted while the daemon is still executing A. B must end up with B's own
# result, not A's.
new_session
export PYREPLAB_TIMEOUT=1
start_daemon
out=$("$PR" run 'import time; time.sleep(3); print("COMMAND-A-OUTPUT")' 2>&1); rc=$?
echo "  run-A rc=$rc (expected 2)"
sleep 0.5
"$PR" clean >/dev/null 2>&1
unset PYREPLAB_TIMEOUT || true
outB=$("$PR" run 'import time; time.sleep(2); print("COMMAND-B-RESULT")' 2>&1); rcB=$?
echo "  run-B rc=$rcB out=[$outB]"
if echo "$outB" | grep -q COMMAND-B-RESULT && ! echo "$outB" | grep -q COMMAND-A-OUTPUT; then
    echo "  [VERIFIED] B received its own result — done/output.json id-validated before consumption"
    record VERIFIED
else
    echo "  [REPRODUCED] run-B received A's result (misdelivery): $outB"
    record REPRODUCED
fi

# ---------------------------------------------------------
echo ""
echo "== T3 [P2] sticky-busy after command finished with no waiter =="
new_session
export PYREPLAB_TIMEOUT=1
start_daemon
out=$("$PR" run 'import time; time.sleep(3); print("REAP-ME")' 2>&1); rc=$?
echo "  run rc=$rc (expected 2)"
wait_for_file "$SESSION/done" 5 && echo "  daemon completed command (done present)"
out=$("$PR" run 'print("SECOND")' 2>&1); rc=$?
echo "  run again rc=$rc out=[$out]"
st=$("$PR" status 2>&1)
echo "  status: [$st]"
outw=$("$PR" wait 2>&1); rcw=$?
echo "  wait rc=$rcw out=[$outw]"
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "busy running previous command"; then
    echo "  [REPRODUCED] run reports 'busy' although the daemon is idle (result pending, nobody reaped)"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED]"
    record "NOT-REPRODUCED"
fi
if echo "$st" | grep -q "executing command"; then
    echo "  [REPRODUCED] status reports 'executing command' although nothing is executing"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED] status wording"
    record "NOT-REPRODUCED"
fi

# ---------------------------------------------------------
echo ""
echo "== T4 [P3a] cancel defeated by user code swallowing KeyboardInterrupt =="
new_session
export PYREPLAB_TIMEOUT=1
start_daemon
cat > "$SESSION/swallow_nb.py" <<'EOF'
# %% [0]
import time
print("CELL0-ENTERED")
# %% [1]
try:
    time.sleep(15)
except BaseException:
    pass
print("SURVIVED-CANCEL")
EOF
out=$("$PR" run "$SESSION/swallow_nb.py" 2>&1); rc=$?
echo "  run notebook rc=$rc (expected 2)"
# Wait until cell 0 has executed (history.md is written after each cell)
wait_for_file "$SESSION/history.md" 5
for i in $(seq 1 50); do
    grep -q CELL0-ENTERED "$SESSION/history.md" 2>/dev/null && break
    sleep 0.1
done
outc=$("$PR" cancel 2>&1); rcc=$?
echo "  cancel rc=$rcc out=[$outc]"
# Drain: keep waiting until the notebook run completes (cancel may already
# have reaped it if the interrupt aborted the sleep promptly)
wrc=2; rounds=0; last=""
while [ "$wrc" -eq 2 ] && [ "$rounds" -lt 12 ]; do
    rounds=$((rounds + 1))
    last=$("$PR" wait 2>&1); wrc=$?
done
echo "  wait rounds=$rounds final rc=$wrc out=[$last]"
combined="$outc $last"
if echo "$combined" | grep -q SURVIVED-CANCEL && ! echo "$combined" | grep -qi keyboardinterrupt; then
    echo "  [REPRODUCED] notebook survived cancel: KeyboardInterrupt was swallowed, run completed normally (cancel rc=$rcc, reaped by cancel: $([ "$rcc" -eq 0 ] && echo yes || echo no))"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED] combined=$combined"
    record "NOT-REPRODUCED"
fi

# ---------------------------------------------------------
echo ""
echo "== T5 [P3b control] cancel during plain sleep works (normal path) =="
new_session
export PYREPLAB_TIMEOUT=1
start_daemon
out=$("$PR" run 'import time; time.sleep(15); print("UNREACHED")' 2>&1); rc=$?
echo "  run rc=$rc (expected 2)"
sleep 1   # ensure exec started
outc=$("$PR" cancel 2>&1); rcc=$?
echo "  cancel rc=$rcc out=[$outc]"
# rc=1 is the designed error-result path: the daemon reports KeyboardInterrupt as the command error
if [ "$rcc" -eq 1 ] && echo "$outc" | grep -qi "KeyboardInterrupt" && ! echo "$outc" | grep -q UNREACHED; then
    echo "  [REPRODUCED baseline] cancel works when code does not swallow the interrupt (control for T4)"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED] cancel rc=$rcc out=$outc"
    record "NOT-REPRODUCED"
fi

# ---------------------------------------------------------
echo ""
echo "== T6 [P4a] concurrent waiters race on done/output.json =="
race_seen="no"
for round in 1 2 3; do
    new_session
    export PYREPLAB_TIMEOUT=1
    start_daemon
    out=$("$PR" run 'import time; time.sleep(6); print("RACE-RESULT")' 2>&1); rc=$?
    [ "$rc" -eq 2 ] || echo "  round $round: run rc=$rc (unexpected)"
    sleep 4.2   # completion happens ~1s after exec start; launch waiters just before
    for w in 1 2 3; do
        ( out=$("$PR" wait 2>&1); printf '%s' "$?" > "$SESSION/w$w.rc"; printf '%s' "$out" > "$SESSION/w$w.out" ) &
    done
    sleep 0.3
    wait
    correct=0; misleading=0; details=""
    for w in 1 2 3; do
        r=$(cat "$SESSION/w$w.rc")
        o=$(cat "$SESSION/w$w.out")
        if [ "$r" -eq 0 ] && echo "$o" | grep -q RACE-RESULT; then
            correct=$((correct + 1))
        else
            misleading=$((misleading + 1))
            details="$details waiter$w(rc=$r: $(echo "$o" | head -1)); "
        fi
    done
    echo "  round $round: correct=$correct misleading=$misleading"
    if [ "$misleading" -gt 0 ]; then
        race_seen="yes"
        echo "  [REPRODUCED] $details"
        record REPRODUCED
        break
    fi
done
if [ "$race_seen" = "no" ]; then
    echo "  [INCONCLUSIVE] no misled waiter observed in 3 rounds"
    record INCONCLUSIVE
fi

# ---------------------------------------------------------
echo ""
echo "== T7 [P4b] concurrent run submissions — busy check is not atomic =="
lost_seen="no"
for round in 1 2 3 4; do
    new_session
    start_daemon
    "$PR" run 'print("TAG-A")' > "$SESSION/a.out" 2>&1 & p1=$!
    "$PR" run 'print("TAG-B")' > "$SESSION/b.out" 2>&1 & p2=$!
    wait $p1; a_rc=$?
    wait $p2; b_rc=$?
    Aout=$(cat "$SESSION/a.out")
    Bout=$(cat "$SESSION/b.out")
    echo "  round $round: A(rc=$a_rc)=[$Aout] B(rc=$b_rc)=[$Bout]"
    if [ "$Aout" != "TAG-A" ] || [ "$Bout" != "TAG-B" ]; then
        lost_seen="yes"
        echo "  [REPRODUCED] one command was lost or misdelivered (shared cmd.py.tmp / late pending_id write)"
        record REPRODUCED
        break
    fi
done
if [ "$lost_seen" = "no" ]; then
    echo "  [INCONCLUSIVE] both runs got their own output in 4 rounds"
    record INCONCLUSIVE
fi

# ---------------------------------------------------------
echo ""
echo "== T8 [P5] stop during a running command orphans the daemon; second start doubles it =="
new_session
export PYREPLAB_TIMEOUT=1
start_daemon
old_pid="${PIDS[0]}"
out=$("$PR" run 'import time; time.sleep(12); print("OLD-ORPHAN-OUTPUT")' 2>&1); rc=$?
echo "  run-old rc=$rc (expected 2)"
sleep 0.5
out=$("$PR" stop 2>&1); src=$?
echo "  stop rc=$src: $out"
if kill -0 "$old_pid" 2>/dev/null; then
    echo "  [REPRODUCED] daemon still alive after stop returned (orphaned, pidfile removed)"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED] daemon died cleanly"
    record "NOT-REPRODUCED"
fi
"$PR" start >/dev/null 2>&1
new_pid=$(cat "$SESSION/pyreplab.pid")
PIDS+=("$new_pid")
echo "  old_pid=$old_pid new_pid=$new_pid"
if kill -0 "$old_pid" 2>/dev/null && kill -0 "$new_pid" 2>/dev/null && [ "$old_pid" != "$new_pid" ]; then
    echo "  [REPRODUCED] two live daemons polling the same session dir"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED] second start did not double up"
    record "NOT-REPRODUCED"
fi
# Damage phase: submit a new slow command; the orphaned daemon wakes at ~12.5s,
# writes its stale output, then cleanup(session_dir) deletes the session state.
out=$("$PR" run 'import time; time.sleep(10); print("NEW-SLOW-RESULT")' 2>&1); nrc=$?
echo "  run-new-slow rc=$nrc out=[$out]"
outw=$("$PR" wait 2>&1); wr=$?
echo "  wait rc=$wr out=[$outw]"
dead="no"
for i in $(seq 1 200); do
    kill -0 "$old_pid" 2>/dev/null || { dead="yes"; break; }
    sleep 0.1
done
echo "  orphan exited after its exec finished: $dead"
combined="$out $outw"
if ! echo "$combined" | grep -q NEW-SLOW-RESULT; then
    echo "  [REPRODUCED] new command's result lost/corrupted by stale daemon output+cleanup (got: [$combined])"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED] new command delivered its own result"
    record "NOT-REPRODUCED"
fi
# Recovery check: the new daemon may still be executing the queued command —
# drain with wait calls and verify the session eventually delivers results.
wrc=2; rounds=0; last=""
while [ "$wrc" -eq 2 ] && [ "$rounds" -lt 12 ]; do
    rounds=$((rounds + 1))
    last=$("$PR" wait 2>&1); wrc=$?
done
echo "  session after orphan: $rounds wait rounds, final rc=$wrc out=[$last]"

# ---------------------------------------------------------
echo ""
echo "== T9 [P6] uncaught BaseException in user code kills the daemon =="
new_session
export PYREPLAB_TIMEOUT=3
start_daemon
daemon_pid="${PIDS[0]}"
out=$("$PR" run 'raise GeneratorExit()' 2>&1); rc=$?
echo "  run rc=$rc out=[$out] (expected 2 — daemon died, no output ever came)"
if ! kill -0 "$daemon_pid" 2>/dev/null; then
    echo "  [REPRODUCED] daemon killed by user code: GeneratorExit is not caught by run_code (only Exception/SystemExit/KeyboardInterrupt)"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED] daemon survived"
    record "NOT-REPRODUCED"
fi
outw=$("$PR" wait 2>&1); wr=$?
echo "  wait rc=$wr out=[$outw]"
if [ "$wr" -eq 1 ] && echo "$outw" | grep -q "server died"; then
    echo "  [REPRODUCED] wait detects dead server and cleans up"
    record REPRODUCED
else
    echo "  [NOT-REPRODUCED]"
    record "NOT-REPRODUCED"
fi

# ---------------------------------------------------------
echo ""
echo "== T10 [P4c] concurrent starts — no lock, two daemons on one dir =="
doubled="no"
for round in 1 2; do
    new_session
    "$PR" start > "$SESSION/s1.out" 2>&1 & p1=$!
    "$PR" start > "$SESSION/s2.out" 2>&1 & p2=$!
    wait $p1; wait $p2
    count=$(pgrep -f "pyreplab.py --session-dir $SESSION" 2>/dev/null | wc -l | tr -d ' ')
    for p in $(pgrep -f "pyreplab.py --session-dir $SESSION" 2>/dev/null || true); do
        PIDS+=("$p")
    done
    echo "  round $round: live daemons=$count"
    if [ "$count" -ge 2 ]; then
        doubled="yes"
        echo "  [REPRODUCED] both starts passed the pidfile check and spawned daemons"
        record REPRODUCED
        break
    fi
done
if [ "$doubled" = "no" ]; then
    echo "  [INCONCLUSIVE] starts serialized by timing"
    record INCONCLUSIVE
fi

# ---------------------------------------------------------
echo ""
echo "== T11 [feature] progress streaming during long commands =="
# Long loop with prints: `run` and `wait` should show partial output
# (progress lines on stderr) instead of silence until completion.
new_session
export PYREPLAB_TIMEOUT=1
start_daemon
prog_seen="no"
out=$("$PR" run 'import time
for i in range(400):
    print("iter %d" % i)
    time.sleep(0.02)' 2>&1); rc=$?
echo "  run rc=$rc (expected 2)"
# Drain with wait calls, collecting stderr (progress lines) as we go
wrc=2; rounds=0; last=""; all_stderr=""
while [ "$wrc" -eq 2 ] && [ "$rounds" -lt 15 ]; do
    rounds=$((rounds + 1))
    werr=$(mktemp)
    last=$("$PR" wait 2>"$werr"); wrc=$?
    all_stderr="$all_stderr $(cat "$werr")"
    rm -f "$werr"
done
echo "  wait rounds=$rounds final rc=$wrc"
echo "  progress lines: $(echo "$all_stderr" | grep -c 'pyreplab: progress')"
if echo "$all_stderr" | grep -q "pyreplab: progress" && echo "$all_stderr" | grep -q "iter "; then
    echo "  [VERIFIED] progress streamed during wait — partial output visible before completion"
    record VERIFIED
else
    echo "  [NOT-REPRODUCED] no progress lines seen: $all_stderr"
    record "NOT-REPRODUCED"
fi
if [ "$wrc" -eq 0 ] && echo "$last" | grep -q "iter 399"; then
    echo "  [VERIFIED] final output still delivered intact after progress streaming"
    record VERIFIED
else
    echo "  [NOT-REPRODUCED] final output missing: rc=$wrc last=[$last]"
    record "NOT-REPRODUCED"
fi

# ---------------------------------------------------------
echo ""
echo "== T12 [feature] start detaches daemon from the shell session =="
# The daemon must survive the invoking bash session ending (nohup + disown),
# ignore SIGHUP, and not hold the caller's stdout/stderr pipes open.
new_session
# 1) Daemon started inside a subshell must survive that subshell exiting
( export PYREPLAB_DIR="$SESSION"; "$PR" start >/dev/null 2>&1 )
daemon_pid=$(cat "$SESSION/pyreplab.pid")
if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    echo "  [VERIFIED] daemon survived its starting shell exiting (started in subshell)"
    record VERIFIED
    PIDS+=("$daemon_pid")
else
    echo "  [NOT-REPRODUCED] daemon died when its shell exited"
    record "NOT-REPRODUCED"
fi
# 2) Daemon must ignore SIGHUP (nohup semantics)
kill -HUP "$daemon_pid" 2>/dev/null
sleep 0.3
if kill -0 "$daemon_pid" 2>/dev/null; then
    echo "  [VERIFIED] daemon ignored SIGHUP (nohup)"
    record VERIFIED
else
    echo "  [NOT-REPRODUCED] daemon killed by SIGHUP"
    record "NOT-REPRODUCED"
fi
# 3) Session must still be fully functional after shell exit + SIGHUP
out=$("$PR" run 'print("ALIVE-AFTER-DETACH")' 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q ALIVE-AFTER-DETACH; then
    echo "  [VERIFIED] session functional after detach (run worked)"
    record VERIFIED
else
    echo "  [NOT-REPRODUCED] run failed after detach: rc=$rc out=$out"
    record "NOT-REPRODUCED"
fi
# 4) Fresh start in the current shell: startup messages must go to
#    daemon.log, not leak to the caller's stderr
"$PR" stop >/dev/null 2>&1
start_out=$("$PR" start 2>&1)
if echo "$start_out" | grep -q "listening on"; then
    echo "  [REPRODUCED] daemon startup messages still leak to the caller's stderr"
    record REPRODUCED
else
    echo "  [VERIFIED] start output clean (daemon messages redirected)"
    record VERIFIED
fi
if [ -f "$SESSION/daemon.log" ] && grep -q "listening on" "$SESSION/daemon.log"; then
    echo "  [VERIFIED] daemon startup messages recorded in daemon.log"
    record VERIFIED
else
    echo "  [NOT-REPRODUCED] daemon.log missing startup messages"
    record "NOT-REPRODUCED"
fi

# ---------------------------------------------------------
echo ""
echo "======================================================"
echo " SUMMARY"
echo "======================================================"
repro=0; notrep=0; incon=0; ver=0
for v in "${V[@]}"; do
    case "$v" in
        REPRODUCED) repro=$((repro + 1)) ;;
        INCONCLUSIVE) incon=$((incon + 1)) ;;
        VERIFIED) ver=$((ver + 1)) ;;
        *) notrep=$((notrep + 1)) ;;
    esac
done
echo "  REPRODUCED: $repro   VERIFIED: $ver   NOT-REPRODUCED: $notrep   INCONCLUSIVE: $incon"
echo "  (REPRODUCED means the defect is still present; VERIFIED means the feature worked)"
exit 0
