#!/bin/bash
# Public launcher contract for the reduced blocking-only surface.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${CODEX_DELEGATE_TEST_BIN:-$ROOT/bin/codex-delegate}
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" run || {
  echo "run suite: temporary directory creation failed" >&2
  exit 2
}
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
test_temp_install_traps

mkdir -p "$WORK/home" "$WORK/runs" "$WORK/job" "$WORK/extra" || exit 2
printf '{"type":"object"}\n' >"$WORK/schema.json"
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
status_schemas_() {
  python3 "$ROOT/tests/status_schema.py" "$WORK"/runs/*/status.json
}

run_case() {
  local mode=$1 runid=$2 expected=$3 rc
  STUB_MODE=$mode "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
    --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
    --runid "$runid" >"$WORK/$runid.out" 2>"$WORK/$runid.err"
  rc=$?
  check '[ "$rc" = "$expected" ]' "$runid exits $expected (got $rc)"
  check '[ -f "$WORK/runs/$runid/status.json" ]' "$runid writes one status record"
  check '[ "$(json_ "$WORK/runs/$runid/status.json" exit_code)" = "$expected" ]' \
    "$runid status exit matches the command"
}

stdin_case() {
  local name=$1 expected=$2 capture=$WORK/$1.stdin rc
  STUB_MODE=ok STUB_STDIN_CAPTURE=$capture "$BIN" run --prompt-stdin \
    --sandbox read-only --cwd "$WORK/job" --deadline 10 --model stub-model-a \
    --effort medium --runid "$name" >"$WORK/$name.out" 2>"$WORK/$name.err"
  rc=$?
  check '[ "$rc" = 0 ] && cmp -s "$expected" "$capture"' \
    "$name transports the exact stdin bytes (got exit $rc)"
}

printf 'Prompt body with $(), backticks `x`, quotes, and CODEX_DELEGATE_PROMPT_EOF.\n' >"$WORK/prompt.txt"

head_ "two-command surface"
"$BIN" --help >"$WORK/help.out" 2>&1
RC=$?
check '[ "$RC" = 0 ]' "top-level help exits 0"
check 'grep -q "{run,models}" "$WORK/help.out"' "help exposes run and models"
check '! grep -Eq "^[[:space:]]+(start|wait|status|reap)[[:space:]]" "$WORK/help.out" &&
       ! grep -Eq "review|computer-use" "$WORK/help.out"' \
  "help omits every retired command and mode"
"$BIN" start >"$WORK/start.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "invalid choice" "$WORK/start.out"' "start is not dispatched"
"$BIN" run --mode review --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  >"$WORK/review.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "unrecognized arguments: --mode review" "$WORK/review.out"' \
  "review mode is not accepted"

head_ "live model catalog"
"$BIN" models >"$WORK/models.out" 2>"$WORK/models.err"
RC=$?
check '[ "$RC" = 0 ] && head -1 "$WORK/models.out" | grep -q $'"'"'^slug\tdefault_effort\treasoning_efforts$'"'"'' \
  "models prints one compact live-catalog table"
check 'grep -q $'"'"'^stub-model-a\tmedium\tlow,medium,high,xhigh,max,ultra$'"'"' "$WORK/models.out"' \
  "models reports the supported pair"
STUB_CATALOG_MODE=minimal "$BIN" models >"$WORK/models-minimal.out" 2>&1
RC=$?
check '[ "$RC" = 0 ] && grep -q $'"'"'^minimal-model\tbespoke\tbespoke$'"'"' "$WORK/models-minimal.out"' \
  "an honest minimal catalog remains usable"
STUB_CATALOG_MODE=invalid "$BIN" models >"$WORK/models-invalid.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "no efforts for broken-model" "$WORK/models-invalid.out"' \
  "an invalid catalog fails instead of dropping entries"
STUB_CATALOG_MODE=fail "$BIN" models >"$WORK/models-fail.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "exit 75" "$WORK/models-fail.out"' \
  "an unavailable live catalog fails instead of degrading"
STUB_CATALOG_MODE=fail STUB_MODE=ok "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --deadline 10 --model stub-model-a \
  --effort medium --runid catalog-fail-explicit \
  >"$WORK/catalog-fail-explicit.out" 2>"$WORK/catalog-fail-explicit.err"
RC=$?
check '[ "$RC" = 0 ] && grep -q "exit 75" "$WORK/catalog-fail-explicit.err" &&
       grep -q "explicit pair unvalidated" "$WORK/catalog-fail-explicit.err"' \
  "an explicit pair proceeds with one warning when the catalog is unavailable"
STUB_CATALOG_MODE=fail "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --deadline 10 --model stub-model-a \
  >"$WORK/catalog-fail-no-effort.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "exit 75" "$WORK/catalog-fail-no-effort.out"' \
  "an unavailable catalog still fails when effort is missing"
STUB_CATALOG_MODE=fail "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --deadline 10 --effort medium \
  >"$WORK/catalog-fail-no-model.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "exit 75" "$WORK/catalog-fail-no-model.out"' \
  "an unavailable catalog still fails when model is missing"

head_ "argument validation"
"$BIN" run --prompt-file "$WORK/prompt.txt" >"$WORK/no-sandbox.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q -- "--sandbox" "$WORK/no-sandbox.out"' \
  "sandbox selection is required"
"$BIN" run --sandbox read-only >"$WORK/no-prompt.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q -- "--prompt-stdin" "$WORK/no-prompt.out"' \
  "exactly one prompt source is required"
"$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --deadline 0 \
  >"$WORK/deadline.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "between 1 and 12960" "$WORK/deadline.out"' \
  "deadline validation is bounded"
"$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --network \
  >"$WORK/network.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "requires --sandbox workspace-write" "$WORK/network.out"' \
  "network is limited to workspace-write"
"$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --model missing \
  >"$WORK/model.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "not in the live catalog" "$WORK/model.out"' \
  "an unknown model is rejected before allocation"
"$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --model stub-model-a \
  --effort impossible >"$WORK/effort.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "not supported" "$WORK/effort.out"' \
  "an unsupported model-effort pair is rejected"

sed 's/if platform.system() != "Darwin":/if True:/' "$BIN" \
  >"$WORK/platform-unsupported-launcher"
chmod 700 "$WORK/platform-unsupported-launcher"
"$WORK/platform-unsupported-launcher" --help >"$WORK/platform.out" 2>&1
RC=$?
check '[ "$RC" = 18 ] && grep -q "unsupported platform" "$WORK/platform.out"' \
  "an unsupported platform returns PLATFORM_UNSUPPORTED"
"$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --runid ../escape \
  >"$WORK/runid.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && [ ! -e "$WORK/escape" ]' "a traversing run id is rejected"

mkdir "$WORK/launch-error-bin"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "${1:-}" = debug ] && [ "${2:-}" = models ]; then' \
  '  printf '\''%s\n'\'' '\''{"models":[{"slug":"stub-model-a","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"medium"}]}]}'\''' \
  '  rm -- "$0"' \
  '  exit 0' \
  'fi' \
  'exit 64' >"$WORK/launch-error-bin/codex"
chmod 700 "$WORK/launch-error-bin/codex"
PATH=$WORK/launch-error-bin:/usr/bin:/bin:/usr/sbin:/sbin \
  "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid launch-error >"$WORK/launch-error.out" 2>"$WORK/launch-error.err"
RC=$?
check '[ "$RC" = 12 ] &&
       [ "$(json_ "$WORK/runs/launch-error/status.json" verdict)" = '\''"LAUNCH_ERROR"'\'' ] &&
       grep -q "could not launch Codex" "$WORK/launch-error.out"' \
  "an OS launch failure publishes LAUNCH_ERROR"
STUB_ARGV_CAPTURE=$WORK/absent-prompt.argv \
  "$BIN" run --prompt-file "$WORK/absent-prompt.txt" --sandbox read-only \
  --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid absent-prompt >"$WORK/absent-prompt.out" 2>"$WORK/absent-prompt.err"
RC=$?
check '[ "$RC" = 2 ] && grep -q "cannot read prompt file" "$WORK/absent-prompt.err" &&
       [ ! -e "$WORK/runs/absent-prompt" ] &&
       [ ! -e "$WORK/absent-prompt.argv" ] &&
       [ ! -e "$WORK/runs/absent-prompt/status.json" ]' \
  "a missing prompt file fails validation before allocating a run"

head_ "native exec invocation and prompt integrity"
STUB_ARGV_CAPTURE=$WORK/argv.txt STUB_STDIN_CAPTURE=$WORK/stdin.txt STUB_MODE=ok \
  "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox workspace-write --network \
  --cwd "$WORK/job" --add-dir "$WORK/extra" --schema "$WORK/schema.json" \
  --deadline 10 --model stub-model-a --effort high --runid argv \
  >"$WORK/argv.out" 2>"$WORK/argv.err"
RC=$?
check '[ "$RC" = 0 ] && cmp -s "$WORK/prompt.txt" "$WORK/stdin.txt"' \
  "prompt bytes reach Codex only through stdin"
check 'grep -Fxq "mode=exec" "$WORK/argv.txt" && grep -Fxq "json=true" "$WORK/argv.txt" &&
       grep -Fxq "model=stub-model-a" "$WORK/argv.txt" && grep -Fxq "effort=high" "$WORK/argv.txt"' \
  "Codex receives exec, JSON, model, and effort"
check 'grep -Fxq "sandbox=workspace-write" "$WORK/argv.txt" && grep -Fxq "network=enabled" "$WORK/argv.txt" &&
       grep -Fxq "cwd=$WORK/job" "$WORK/argv.txt" && grep -Fxq "process_cwd=$WORK/job" "$WORK/argv.txt"' \
  "Codex receives the canonical cwd, sandbox, and network posture"
check 'grep -Fxq "add_dir=$WORK/extra" "$WORK/argv.txt" && grep -Fxq "schema=$WORK/schema.json" "$WORK/argv.txt"' \
  "native add-dir and output-schema flags survive"
check '! grep -Fq "Prompt body" "$WORK/argv.txt"' "prompt text is absent from captured argv"

STUB_ARGV_CAPTURE=$WORK/workspace-offline.argv STUB_MODE=ok \
  "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox workspace-write \
  --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid workspace-offline >"$WORK/workspace-offline.out" 2>"$WORK/workspace-offline.err"
RC=$?
check '[ "$RC" = 0 ] && grep -Fxq "sandbox=workspace-write" "$WORK/workspace-offline.argv" &&
       grep -Fxq "network=disabled" "$WORK/workspace-offline.argv"' \
  "workspace-write succeeds with network disabled by default"

STUB_ARGV_CAPTURE=$WORK/read-only-add-dir.argv STUB_MODE=ok \
  "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  --cwd "$WORK/job" --add-dir "$HOME" --deadline 10 --model stub-model-a \
  --effort medium --runid read-only-add-dir \
  >"$WORK/read-only-add-dir.out" 2>"$WORK/read-only-add-dir.err"
RC=$?
check '[ "$RC" = 0 ] && grep -Fxq "sandbox=read-only" "$WORK/read-only-add-dir.argv" &&
       grep -Fxq "add_dir=$HOME" "$WORK/read-only-add-dir.argv"' \
  "read-only forwards --add-dir HOME without rejecting it"

head_ "runner-shaped stdin prompt transport"
printf 'ordinary prompt through stdin\n' >"$WORK/stdin-ordinary.expected"
stdin_case stdin-ordinary "$WORK/stdin-ordinary.expected" <<'CODEX_DELEGATE_PROMPT_11111111111111111111111111111111'
ordinary prompt through stdin
CODEX_DELEGATE_PROMPT_11111111111111111111111111111111

printf '%s\n' before CODEX_DELEGATE_PROMPT_22222222222222222222222222222222 after \
  >"$WORK/stdin-delimiter.expected"
stdin_case stdin-delimiter "$WORK/stdin-delimiter.expected" <<'CODEX_DELEGATE_PROMPT_33333333333333333333333333333333'
before
CODEX_DELEGATE_PROMPT_22222222222222222222222222222222
after
CODEX_DELEGATE_PROMPT_33333333333333333333333333333333

printf '%s\n' \
  'literal $HOME ${PATH} $(printf expanded) `uname` ; | & < > "double" '"'"'single'"'"' \\' \
  >"$WORK/stdin-metacharacters.expected"
stdin_case stdin-metacharacters "$WORK/stdin-metacharacters.expected" <<'CODEX_DELEGATE_PROMPT_44444444444444444444444444444444'
literal $HOME ${PATH} $(printf expanded) `uname` ; | & < > "double" 'single' \\
CODEX_DELEGATE_PROMPT_44444444444444444444444444444444

printf 'first trailing line\nsecond trailing line\n\n\n' >"$WORK/stdin-trailing.expected"
stdin_case stdin-trailing "$WORK/stdin-trailing.expected" <<'CODEX_DELEGATE_PROMPT_55555555555555555555555555555555'
first trailing line
second trailing line


CODEX_DELEGATE_PROMPT_55555555555555555555555555555555

NO_TRAILING_NEWLINE=$(
  cat <<'CODEX_DELEGATE_PROMPT_66666666666666666666666666666666'
stdin prompt with no trailing newline
CODEX_DELEGATE_PROMPT_66666666666666666666666666666666
)
printf %s "$NO_TRAILING_NEWLINE" >"$WORK/stdin-no-newline.expected"
stdin_case stdin-no-newline "$WORK/stdin-no-newline.expected" \
  < <(printf %s "$NO_TRAILING_NEWLINE")

printf '%s\n' 'UTF-8: café — 雪 — 🙂 — decomposed é' >"$WORK/stdin-utf8.expected"
stdin_case stdin-utf8 "$WORK/stdin-utf8.expected" <<'CODEX_DELEGATE_PROMPT_77777777777777777777777777777777'
UTF-8: café — 雪 — 🙂 — decomposed é
CODEX_DELEGATE_PROMPT_77777777777777777777777777777777

: >"$WORK/stdin-empty.expected"
STUB_MODE=ok STUB_STDIN_CAPTURE=$WORK/stdin-empty.stdin \
  "$BIN" run --prompt-stdin --sandbox read-only --cwd "$WORK/job" --deadline 10 \
  --model stub-model-a --effort medium --runid stdin-empty \
  >"$WORK/stdin-empty.out" 2>"$WORK/stdin-empty.err" <<'CODEX_DELEGATE_PROMPT_88888888888888888888888888888888'
CODEX_DELEGATE_PROMPT_88888888888888888888888888888888
RC=$?
check '[ "$RC" = 12 ] && grep -q "the prompt is empty" "$WORK/stdin-empty.err" &&
       cmp -s "$WORK/stdin-empty.expected" "$WORK/runs/stdin-empty/prompt.txt" &&
       [ ! -e "$WORK/stdin-empty.stdin" ] &&
       [ "$(json_ "$WORK/runs/stdin-empty/status.json" verdict)" = '"'"'"LAUNCH_ERROR"'"'"' ]' \
  "an empty stdin body is stored empty and rejected before Codex starts"

STUB_MODE=ok "$BIN" run --prompt-stdin --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid stdin-closed \
  0<&- >"$WORK/stdin-closed.out" 2>"$WORK/stdin-closed.err"
RC=$?
check '[ "$RC" = 12 ] &&
       grep -q "cannot read prompt from stdin: standard input is closed" "$WORK/stdin-closed.err" &&
       ! grep -q "Traceback" "$WORK/stdin-closed.err" &&
       [ "$(json_ "$WORK/runs/stdin-closed/status.json" verdict)" = '"'"'"LAUNCH_ERROR"'"'"' ]' \
  "a closed stdin is a clean pre-launch validation failure"

STUB_MODE=ok "$BIN" run --prompt-stdin --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid stdin-unreadable \
  0>/dev/null >"$WORK/stdin-unreadable.out" 2>"$WORK/stdin-unreadable.err"
RC=$?
check '[ "$RC" = 12 ] &&
       grep -q "cannot read prompt from stdin: reading standard input failed" "$WORK/stdin-unreadable.err" &&
       ! grep -q "standard input is closed" "$WORK/stdin-unreadable.err" &&
       ! grep -q "Traceback" "$WORK/stdin-unreadable.err" &&
       [ "$(json_ "$WORK/runs/stdin-unreadable/status.json" verdict)" = '"'"'"LAUNCH_ERROR"'"'"' ]' \
  "an unreadable stdin reports the failed read instead of a missing stream"

head_ "terminal event and status contract"
run_case ok completed 0
RD=$WORK/runs/completed
check '[ "$(json_ "$RD/status.json" verdict)" = '"'"'"COMPLETED"'"'"' ]' "completed verdict is exact"
check 'grep -q "STUB FINAL MESSAGE" "$WORK/completed.out"' "blocking run returns the final message"
FINAL_LINE=$(grep -n '^--- FINAL MESSAGE' "$WORK/completed.out" | cut -d: -f1)
STATUS_LINE=$(grep -n '^--- STATUS' "$WORK/completed.out" | cut -d: -f1)
check '[ "$FINAL_LINE" -lt "$STATUS_LINE" ]' "final message precedes status"
check 'python3 "$ROOT/tests/status_schema.py" "$RD/status.json"' \
  "status has exactly the reduced 16-field schema"
check '[ "$(stat -f %Lp "$RD/status.json")" = 400 ]' "status is published read-only"
check '[ "$(json_ "$RD/status.json" terminal_event)" = '"'"'"turn.completed"'"'"' ] &&
       python3 -c '"'"'import json,sys; raise SystemExit(json.load(open(sys.argv[1]))["final_message_path"] != sys.argv[2])'"'"' "$RD/status.json" "$RD/final.txt"' \
  "terminal type and final path are actionable"

run_case native_mismatch native-output 0
RD=$WORK/runs/native-output
printf 'LONGER NATIVE DOCUMENT\n' >"$WORK/native-output.expected"
check 'cmp -s "$WORK/native-output.expected" "$RD/final.txt" &&
       [ "$(json_ "$RD/status.json" verdict)" = '"'"'"COMPLETED"'"'"' ]' \
  "an intact native -o document is neither replaced nor reported missing"

LATE_RD=$WORK/runs/late-document
LATE_PROMPT_GATE=$WORK/late-document-prompt-gate
mkfifo "$LATE_PROMPT_GATE"
STUB_MODE=native_mismatch STUB_STDIN_CAPTURE=$LATE_PROMPT_GATE \
  "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid late-document >"$WORK/late-document.out" 2>"$WORK/late-document.err" &
LATE_PID=$!
(
  until [ -d "$LATE_RD" ]; do
    sleep 0.02
  done
  mkfifo "$LATE_RD/final.txt"
  cat "$LATE_PROMPT_GATE" >/dev/null
  until grep -q '"type":"turn.completed"' "$LATE_RD/events.jsonl" 2>/dev/null; do
    sleep 0.02
  done
  (
    sleep 0.9
    : >"$LATE_RD/final.txt"
  ) &
  LATE_DUMMY_PID=$!
  sleep 1
  mv "$LATE_RD/final.txt" "$WORK/late-document.fifo"
  : >"$LATE_RD/final.txt"
  cat "$WORK/late-document.fifo" >"$LATE_RD/final.txt"
  wait "$LATE_DUMMY_PID"
) &
LATE_WRITER_PID=$!
wait "$LATE_PID"
RC=$?
wait "$LATE_WRITER_PID"
printf 'LONGER NATIVE DOCUMENT\n' >"$WORK/late-document.expected"
check '[ "$RC" = 0 ] && cmp -s "$WORK/late-document.expected" "$LATE_RD/final.txt" &&
       [ "$(json_ "$LATE_RD/status.json" verdict)" = '"'"'"COMPLETED"'"'"' ]' \
  "a native document arriving one second after the terminal event is collected"

STUB_MODE=ok "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid stdout-closed 1>&- 2>"$WORK/stdout-closed.err"
RC=$?
check '[ "$RC" = 0 ] &&
       [ "$(json_ "$WORK/runs/stdout-closed/status.json" verdict)" = '"'"'"COMPLETED"'"'"' ] &&
       ! grep -q "Traceback" "$WORK/stdout-closed.err"' \
  "a closed stdout preserves the completed verdict exit without a traceback"

STUB_MODE=ok "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid stdout-unwritable 1</dev/null 2>"$WORK/stdout-unwritable.err"
RC=$?
check '[ "$RC" = 0 ] &&
       [ "$(json_ "$WORK/runs/stdout-unwritable/status.json" verdict)" = '"'"'"COMPLETED"'"'"' ] &&
       ! grep -q "Traceback\|Exception ignored" "$WORK/stdout-unwritable.err"' \
  "an unwritable stdout preserves the completed verdict exit without a traceback"

STUB_MODE=ok "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid stdout-broken-pipe 2>"$WORK/stdout-broken-pipe.err" | head -n 1 \
  >"$WORK/stdout-broken-pipe.out"
RC=${PIPESTATUS[0]}
check '[ "$RC" = 0 ] &&
       [ "$(json_ "$WORK/runs/stdout-broken-pipe/status.json" verdict)" = '"'"'"COMPLETED"'"'"' ] &&
       [ ! -s "$WORK/stdout-broken-pipe.err" ]' \
  "an early-exiting stdout reader preserves the completed verdict exit without stderr"

run_case fail failed 10
check '[ "$(json_ "$WORK/runs/failed/status.json" verdict)" = '"'"'"FAILED"'"'"' ] &&
       [ "$(json_ "$WORK/runs/failed/status.json" diagnostic)" = '"'"'"stub was told to fail"'"'"' ]' \
  "turn.failed preserves its diagnostic"
run_case duplicate_terminal duplicate 17
check '[ "$(json_ "$WORK/runs/duplicate/status.json" diagnostic)" = '"'"'"duplicate_terminal_event"'"'"' ]' \
  "duplicate terminal events fail deterministically"
run_case malformed malformed 17
check '[ "$(json_ "$WORK/runs/malformed/status.json" diagnostic)" = '"'"'"malformed_event_record"'"'"' ]' \
  "malformed JSON cannot become success"
run_case truncated truncated 17
check '[ "$(json_ "$WORK/runs/truncated/status.json" diagnostic)" = '"'"'"truncated_event_record"'"'"' ]' \
  "a truncated suffix cannot become success"
run_case no_terminal no-terminal 21
check '[ "$(json_ "$WORK/runs/no-terminal/status.json" verdict)" = '"'"'"NO_TERMINAL_EVENT"'"'"' ]' \
  "process exit without a terminal event is distinct"
run_case no_final no-final 23
check '[ "$(json_ "$WORK/runs/no-final/status.json" verdict)" = '"'"'"OUTPUT_MISSING"'"'"' ] &&
       [ ! -e "$WORK/runs/no-final/final.txt" ]' \
  "completion without any message in the stream is the only OUTPUT_MISSING"
run_case multi_message multi-message 0
printf 'THE LAST MESSAGE' >"$WORK/multi-message.expected"
check 'cmp -s "$WORK/multi-message.expected" "$WORK/runs/multi-message/final.txt"' \
  "a later record without text cannot unseat the last streamed agent message"
run_case process_exit process-exit 0
check '[ "$(json_ "$WORK/runs/process-exit/status.json" process_exit_code)" = 7 ]' \
  "terminal evidence remains authoritative while process exit stays diagnostic"

head_ "run storage trust boundary"
MODE=$(stat -f %Lp "$WORK/runs")
check '[ "$MODE" = 700 ]' "run storage is owner-only"
CODEX_DELEGATE_HOME=$WORK/job/control "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox workspace-write --cwd "$WORK/job" >"$WORK/overlap.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "overlaps writable root" "$WORK/overlap.out"' \
  "workspace-write cannot overlap launcher control state"

check 'status_schemas_' "every run-suite verdict fixture has exactly 16 status fields"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
