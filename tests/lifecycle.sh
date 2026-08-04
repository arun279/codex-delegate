#!/bin/bash
# Process lifecycle checks for one foreground blocking run.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=$ROOT/bin/codex-delegate
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" lifecycle || {
  echo "lifecycle: temporary directory creation failed" >&2
  exit 2
}
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  test_temp_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$WORK/home" "$WORK/runs" "$WORK/job" || exit 2
printf 'exercise lifecycle\n' >"$WORK/prompt.txt"
export HOME=$WORK/home
export CODEX_DELEGATE_HOME=$WORK/runs
export PATH=$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$*"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$*"
}
check() { if eval "$1"; then ok "$2"; else bad "$2 [$1]"; fi; }
head_() { printf '\n== %s\n' "$*"; }
json_() {
  python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); [value:=value[key] for key in sys.argv[2].split(".")]; print(json.dumps(value))' "$1" "$2"
}
text_() {
  python3 -c 'import json,sys; value=json.load(open(sys.argv[1]))[sys.argv[2]]; print("null" if value is None else value)' "$1" "$2"
}
wait_file() {
  local path=$1 i=0
  while [ ! -s "$path" ] && [ "$i" -lt 200 ]; do
    i=$((i + 1))
    sleep 0.02
  done
  [ -s "$path" ]
}
wait_gone() {
  local pid=$1 i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do
    i=$((i + 1))
    sleep 0.02
  done
  ! kill -0 "$pid" 2>/dev/null
}

run_args=(--prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job"
  --model gpt-5.6-sol --effort medium)

head_ "blocking terminal path"
SECONDS=0
STUB_MODE=ok "$BIN" run "${run_args[@]}" --deadline 10 --runid lc-completed \
  >"$WORK/completed.out" 2>"$WORK/completed.err"
RC=$?
ELAPSED=$SECONDS
RD=$WORK/runs/lc-completed
check '[ "$RC" = 0 ] && [ "$ELAPSED" -lt 3 ]' "completed run returns promptly with exit 0"
check '[ "$(json_ "$RD/status.json" verdict)" = '"'"'"COMPLETED"'"'"' ]' \
  "completed run publishes its terminal verdict"
check 'grep -q "STUB FINAL MESSAGE" "$WORK/completed.out" && grep -q '"'"'"verdict": "COMPLETED"'"'"' "$WORK/completed.out"' \
  "one blocking call returns the final message and status"

head_ "terminal event ends a process that does not exit"
STUB_MODE=terminal_hold STUB_PID_CAPTURE=$WORK/terminal.pid \
  "$BIN" run "${run_args[@]}" --deadline 10 --runid lc-terminal-hold \
  >"$WORK/terminal.out" 2>"$WORK/terminal.err"
RC=$?
CHILD=$(cat "$WORK/terminal.pid")
RD=$WORK/runs/lc-terminal-hold
check '[ "$RC" = 0 ]' "first terminal event wins even when Codex does not exit"
check 'wait_gone "$CHILD"' "terminal cleanup reaps the Codex group leader"
check '[ "$(json_ "$RD/status.json" terminal_event)" = '"'"'"turn.completed"'"'"' ] &&
       [ "$(json_ "$RD/status.json" process_exit_code)" = -9 ]' \
  "status records both terminal evidence and forced process exit"
printf 'TERMINAL BEFORE HANG' >"$WORK/terminal.expected"
check 'cmp -s "$WORK/terminal.expected" "$RD/final.txt" &&
       [ "$(text_ "$RD/status.json" verdict)" = COMPLETED ] &&
       grep -q "TERMINAL BEFORE HANG" "$WORK/terminal.out"' \
  "a streamed final message survives a Codex process killed before it wrote one"

head_ "the process handle a blocked caller waits on"
STUB_MODE=hold STUB_PID_CAPTURE=$WORK/handle.pid STUB_DESCENDANT_CAPTURE=$WORK/handle-child.pid \
  "$BIN" run "${run_args[@]}" --deadline 30 --runid lc-handle \
  >"$WORK/handle.out" 2>"$WORK/handle.err" &
LAUNCHER=$!
PIDS+=("$LAUNCHER")
RD=$WORK/runs/lc-handle
check 'wait_file "$RD/pid"' "the launcher records its pid before it starts Codex"
wait_file "$WORK/handle.pid" && wait_file "$WORK/handle-child.pid"
CHILD=$(cat "$WORK/handle.pid")
DESCENDANT=$(cat "$WORK/handle-child.pid")
PIDS+=("$CHILD" "$DESCENDANT")
check '[ "$(cat "$RD/pid")" = "$LAUNCHER" ]' "the recorded pid is the process the caller holds"
check 'kill -0 "$(cat "$RD/pid")" 2>/dev/null' "that pid answers kill -0 while the run is alive"
kill -KILL "$LAUNCHER"
wait "$LAUNCHER" 2>/dev/null
check '! kill -0 "$(cat "$RD/pid")" 2>/dev/null' \
  "and stops answering after a kill the launcher cannot report"
check '[ ! -e "$RD/status.json" ] && [ ! -s "$WORK/handle.out" ]' \
  "that kill leaves no status and no output, so silence is a death and not a result"
kill -KILL "$CHILD" 2>/dev/null
kill -KILL "$DESCENDANT" 2>/dev/null

head_ "wall-clock deadline"
SECONDS=0
STUB_MODE=hold STUB_PID_CAPTURE=$WORK/deadline.pid STUB_DESCENDANT_CAPTURE=$WORK/deadline-child.pid \
  "$BIN" run "${run_args[@]}" --deadline 1 --runid lc-deadline \
  >"$WORK/deadline.out" 2>"$WORK/deadline.err"
RC=$?
ELAPSED=$SECONDS
CHILD=$(cat "$WORK/deadline.pid")
DESCENDANT=$(cat "$WORK/deadline-child.pid")
RD=$WORK/runs/lc-deadline
check '[ "$RC" = 11 ] && [ "$ELAPSED" -lt 5 ]' "deadline is terminal and bounded"
check 'wait_gone "$CHILD" && wait_gone "$DESCENDANT"' \
  "deadline kills the complete inherited process group"
check '[ "$(json_ "$RD/status.json" verdict)" = '"'"'"DEADLINE"'"'"' ] &&
       [ "$(json_ "$RD/status.json" exit_code)" = 11 ]' \
  "deadline status agrees with the command exit"

head_ "direct stop signals"
signal_case() {
  local name=$1 number=$2 expected=$3 launcher child descendant rc rd
  STUB_MODE=hold STUB_PID_CAPTURE=$WORK/$name.pid \
    STUB_DESCENDANT_CAPTURE=$WORK/$name-child.pid \
    "$BIN" run "${run_args[@]}" --deadline 30 --runid "$name" \
    >"$WORK/$name.out" 2>"$WORK/$name.err" &
  launcher=$!
  PIDS+=("$launcher")
  wait_file "$WORK/$name.pid" && wait_file "$WORK/$name-child.pid"
  child=$(cat "$WORK/$name.pid")
  descendant=$(cat "$WORK/$name-child.pid")
  PIDS+=("$child" "$descendant")
  kill -"$number" "$launcher"
  wait "$launcher"
  rc=$?
  rd=$WORK/runs/$name
  check '[ "$rc" = "$expected" ]' "$number returns conventional exit $expected"
  check 'wait_gone "$child" && wait_gone "$descendant"' \
    "$number leaves no process in the Codex group"
  check '[ "$(text_ "$rd/status.json" verdict)" = STOPPED ] &&
         [ "$(text_ "$rd/status.json" signal)" = "SIG$number" ] &&
         [ "$(json_ "$rd/status.json" exit_code)" = "$expected" ]' \
    "$number status names the stop signal and exit"
}
signal_case lc-int INT 130
signal_case lc-term TERM 143

head_ "deadline wins over late terminal output"
STUB_MODE=deadline_edge STUB_TERMINAL_DELAY=1.2 "$BIN" run "${run_args[@]}" \
  --deadline 1 --runid lc-deadline-edge >"$WORK/edge.out" 2>"$WORK/edge.err"
RC=$?
RD=$WORK/runs/lc-deadline-edge
check '[ "$RC" = 11 ]' "a terminal event observed after the deadline cannot reverse it"
check '[ "$(text_ "$RD/status.json" verdict)" = DEADLINE ] &&
       [ "$(json_ "$RD/status.json" exit_code)" = 11 ]' \
  "late output is not reported as completed"
printf 'LATE TERMINAL OUTPUT' >"$WORK/edge.expected"
check 'cmp -s "$WORK/edge.expected" "$RD/final.txt"' \
  "a captured message is kept as evidence without becoming a completion"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
