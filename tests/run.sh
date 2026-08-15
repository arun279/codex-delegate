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
check '[ "$RC" = 2 ] && grep -q "CODEX_DELEGATE_DEADLINE received .0." "$WORK/deadline.out" &&
       grep -q "between 1 and 12960" "$WORK/deadline.out"' \
  "deadline validation is bounded"
unset CODEX_DELEGATE_DEADLINE
"$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --model stub-model-a --effort medium --runid tunable-default \
  >"$WORK/tunable-default.out" 2>"$WORK/tunable-default.err"
RC=$?
check '[ "$RC" = 0 ] &&
       [ "$(json_ "$WORK/runs/tunable-default/status.json" deadline_s)" = 7200 ]' \
  "an unset tunable uses its table default"
CODEX_DELEGATE_DEADLINE=9 "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --model stub-model-a --effort medium \
  --runid tunable-environment >"$WORK/tunable-environment.out" 2>"$WORK/tunable-environment.err"
RC=$?
check '[ "$RC" = 0 ] &&
       [ "$(json_ "$WORK/runs/tunable-environment/status.json" deadline_s)" = 9 ]' \
  "a valid environment override takes effect"
CODEX_DELEGATE_DEADLINE=9 "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --deadline 10 --model stub-model-a --effort medium \
  --runid tunable-cli >"$WORK/tunable-cli.out" 2>"$WORK/tunable-cli.err"
RC=$?
check '[ "$RC" = 0 ] &&
       [ "$(json_ "$WORK/runs/tunable-cli/status.json" deadline_s)" = 10 ]' \
  "the deadline flag wins over its environment variable"
CODEX_DELEGATE_DEADLINE=0 "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  >"$WORK/tunable-bad-environment.out" 2>&1
ENV_RC=$?
unset CODEX_DELEGATE_DEADLINE
"$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --deadline 0 \
  >"$WORK/tunable-bad-flag.out" 2>&1
FLAG_RC=$?
check '[ "$ENV_RC" = 2 ] && [ "$FLAG_RC" = 2 ] &&
       cmp -s "$WORK/tunable-bad-environment.out" "$WORK/tunable-bad-flag.out" &&
       grep -q "CODEX_DELEGATE_DEADLINE received .0." "$WORK/tunable-bad-environment.out"' \
  "environment and flag values share validation and diagnostics"
printf 'CODEX_DELEGATE_LAUNCHER_PID=2147483647\n' >"$WORK/runner-ended.out"
CODEX_DELEGATE_READ_BATCH=bogus "$BIN" runner-wait "$WORK/runner-ended.out" \
  >"$WORK/runner-scoped.out" 2>"$WORK/runner-scoped.err"
RC=$?
check '[ "$RC" = 0 ] && [ "$(cat "$WORK/runner-scoped.out")" = ENDED ] &&
       [ ! -s "$WORK/runner-scoped.err" ]' \
  "runner-wait ignores invalid environment values for unrelated tunables"
CODEX_DELEGATE_RUNNER_WAIT_SECONDS=110 CODEX_DELEGATE_RUNNER_STARTUP_SECONDS=110 \
  "$BIN" runner-wait "$WORK/runner-ended.out" >"$WORK/runner-inverted.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] &&
       grep -q "CODEX_DELEGATE_RUNNER_STARTUP_SECONDS received .110." \
         "$WORK/runner-inverted.out" &&
       grep -q "must be less than CODEX_DELEGATE_RUNNER_WAIT_SECONDS" \
         "$WORK/runner-inverted.out"' \
  "runner startup grace must fit inside the runner wait bound"
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
  "status has exactly the reduced 17-field schema"
check '[ "$(stat -f %Lp "$RD/status.json")" = 400 ]' "status is published read-only"
check '[ "$(json_ "$RD/status.json" terminal_event)" = '"'"'"turn.completed"'"'"' ] &&
       python3 -c '"'"'import json,sys; raise SystemExit(json.load(open(sys.argv[1]))["final_message_path"] != sys.argv[2])'"'"' "$RD/status.json" "$RD/final.txt"' \
  "terminal type and final path are actionable"
check 'python3 -c '"'"'import json,sys; expected={"input_tokens":101,"cached_input_tokens":80,"cache_write_input_tokens":7,"output_tokens":23,"reasoning_output_tokens":5}; raise SystemExit(json.load(open(sys.argv[1]))["usage"] != expected)'"'"' "$RD/status.json"' \
  "Codex CLI usage counters pass through unchanged"

STUB_MODE=ok STUB_FINAL_BYTES=20005 \
  "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid final-cap-default \
  >"$WORK/final-cap-default.out" 2>"$WORK/final-cap-default.err"
RC=$?
CAP_RD=$WORK/runs/final-cap-default
check '[ "$RC" = 0 ] && python3 -c '"'"'import sys
output=open(sys.argv[1], "rb").read(); artifact=sys.argv[2]
header=f"\n--- FINAL MESSAGE ({artifact}) ---\n".encode()
marker=f"\n--- FINAL MESSAGE TRUNCATED: 5 bytes omitted; complete artifact: {artifact} ---\n".encode()
raise SystemExit(not output.startswith(header + b"A" * 20000 + marker))'"'"' "$WORK/final-cap-default.out" "$CAP_RD/final.txt"' \
  "an over-budget final message prints the bounded head and exact omission marker"
check 'python3 -c '"'"'import json,sys
output=open(sys.argv[1], "rb").read(); encoded=output.rsplit(b"\n--- STATUS ---\n", 1)[1]
status=json.loads(encoded); stored=open(sys.argv[2], "rb").read()
raise SystemExit(status["verdict"] != "COMPLETED" or encoded != stored)'"'"' "$WORK/final-cap-default.out" "$CAP_RD/status.json"' \
  "a capped final message leaves complete parseable status JSON"
check 'python3 -c '"'"'import sys
data=open(sys.argv[1], "rb").read(); raise SystemExit(data != b"A" * 20005)'"'"' "$CAP_RD/final.txt"' \
  "a capped print leaves the complete artifact bytes intact"

STUB_MODE=ok STUB_FINAL_BYTES=20000 \
  "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid final-cap-exact \
  >"$WORK/final-cap-exact.out" 2>"$WORK/final-cap-exact.err"
RC=$?
EXACT_RD=$WORK/runs/final-cap-exact
check '[ "$RC" = 0 ] && ! grep -q "FINAL MESSAGE TRUNCATED" "$WORK/final-cap-exact.out" &&
       python3 -c '"'"'import sys
output=open(sys.argv[1], "rb").read(); artifact=sys.argv[2]
header=f"\n--- FINAL MESSAGE ({artifact}) ---\n".encode()
raise SystemExit(not output.startswith(header + b"A" * 20000 + b"\n\n--- STATUS ---\n"))'"'"' "$WORK/final-cap-exact.out" "$EXACT_RD/final.txt"' \
  "a final message exactly at the budget prints in full without a marker"
check 'python3 -c '"'"'import sys
data=open(sys.argv[1], "rb").read(); raise SystemExit(data != b"A" * 20000)'"'"' "$EXACT_RD/final.txt"' \
  "an exactly-budgeted print leaves the complete artifact bytes intact"

CODEX_DELEGATE_FINAL_MESSAGE_PRINT_LIMIT=7 STUB_MODE=ok STUB_FINAL_BYTES=8 \
  "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --deadline 10 --model stub-model-a \
  --effort medium --runid final-cap-environment >"$WORK/final-cap-environment.out" \
  2>"$WORK/final-cap-environment.err"
RC=$?
ENV_CAP_RD=$WORK/runs/final-cap-environment
check '[ "$RC" = 0 ] && python3 -c '"'"'import sys
output=open(sys.argv[1], "rb").read(); artifact=sys.argv[2]
header=f"\n--- FINAL MESSAGE ({artifact}) ---\n".encode()
marker=f"\n--- FINAL MESSAGE TRUNCATED: 1 byte omitted; complete artifact: {artifact} ---\n".encode()
raise SystemExit(not output.startswith(header + b"A" * 7 + marker))'"'"' "$WORK/final-cap-environment.out" "$ENV_CAP_RD/final.txt"' \
  "the final-message print budget responds to its environment variable with a grammatical singular marker"
check 'python3 -c '"'"'import sys
data=open(sys.argv[1], "rb").read(); raise SystemExit(data != b"A" * 8)'"'"' "$ENV_CAP_RD/final.txt"' \
  "an environment-capped print leaves the complete artifact bytes intact"

CODEX_DELEGATE_FINAL_MESSAGE_PRINT_LIMIT=7 STUB_MODE=ok \
  STUB_FINAL_HEX=414141414141c3a95a \
  "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --deadline 10 --model stub-model-a \
  --effort medium --runid final-cap-utf8 >"$WORK/final-cap-utf8.out" \
  2>"$WORK/final-cap-utf8.err"
RC=$?
UTF8_CAP_RD=$WORK/runs/final-cap-utf8
# Mutation: writing the raw seven-byte slice emits a dangling UTF-8 lead byte and reports only two omitted bytes.
check '[ "$RC" = 0 ] && python3 -c '"'"'import sys
output=open(sys.argv[1], "rb").read(); artifact=sys.argv[2]
header=f"\n--- FINAL MESSAGE ({artifact}) ---\n".encode()
marker=f"\n--- FINAL MESSAGE TRUNCATED: 3 bytes omitted; complete artifact: {artifact} ---\n".encode()
expected=header + b"A" * 6 + marker
raise SystemExit(not output.startswith(expected) or output[len(header):].split(b"\n", 1)[0].decode() != "AAAAAA")'"'"' "$WORK/final-cap-utf8.out" "$UTF8_CAP_RD/final.txt"' \
  "a UTF-8 sequence straddling the budget is omitted without a dangling fragment"
check 'python3 -c '"'"'import sys
data=open(sys.argv[1], "rb").read(); raise SystemExit(data != bytes.fromhex("414141414141c3a95a"))'"'"' "$UTF8_CAP_RD/final.txt"' \
  "a UTF-8 boundary trim leaves the complete artifact bytes intact"

CODEX_DELEGATE_FINAL_MESSAGE_PRINT_LIMIT=0 "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only >"$WORK/final-cap-below-bound.out" 2>&1
BELOW_CAP_RC=$?
CODEX_DELEGATE_FINAL_MESSAGE_PRINT_LIMIT=1073741825 "$BIN" run \
  --prompt-file "$WORK/prompt.txt" --sandbox read-only \
  >"$WORK/final-cap-above-bound.out" 2>&1
ABOVE_CAP_RC=$?
check '[ "$BELOW_CAP_RC" = 2 ] && [ "$ABOVE_CAP_RC" = 2 ] &&
       grep -q "between 1 and 1073741824" "$WORK/final-cap-below-bound.out" &&
       grep -q "between 1 and 1073741824" "$WORK/final-cap-above-bound.out"' \
  "the final-message print budget rejects values outside its documented bounds"

run_case missing_usage missing-usage 0
check '[ "$(json_ "$WORK/runs/missing-usage/status.json" usage)" = null ]' \
  "a completed event without usage publishes null"

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

head_ "owned run retention"
FRESH_ROOT=$WORK/fresh-runs
CODEX_DELEGATE_HOME=$FRESH_ROOT STUB_MODE=ok "$BIN" run \
  --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid marked-run \
  >"$WORK/marked-run.out" 2>"$WORK/marked-run.err"
RC=$?
check '[ "$RC" = 0 ] &&
       [ "$(dd if="$FRESH_ROOT/CACHEDIR.TAG" bs=43 count=1 2>/dev/null)" = "Signature: 8a477f597d28d172789f06886806bc55" ] &&
       [ "$(cat "$FRESH_ROOT/marked-run/.codex-delegate-run")" = "codex-delegate run directory" ]' \
  "launcher-created roots and runs carry their ownership markers"

UNPROVEN_ROOT=$WORK/unproven-runs
mkdir -p "$UNPROVEN_ROOT/no-marker" "$UNPROVEN_ROOT/wrong-marker" "$WORK/outside-run"
printf '%s\n' 'not a codex-delegate marker' \
  >"$UNPROVEN_ROOT/wrong-marker/.codex-delegate-run"
: >"$UNPROVEN_ROOT/no-marker/pid"
: >"$UNPROVEN_ROOT/wrong-marker/pid"
: >"$WORK/outside-run/pid"
ln -s "$WORK/outside-run" "$UNPROVEN_ROOT/directory-symlink"
printf '%s\n' 'codex-delegate run directory' >"$UNPROVEN_ROOT/.codex-delegate-run"
: >"$UNPROVEN_ROOT/pid"
CODEX_DELEGATE_HOME=$UNPROVEN_ROOT CODEX_DELEGATE_TEST_BIN=$BIN \
  CODEX_DELEGATE_TEST_KEEP_LIMIT=0 STUB_MODE=ok "$BIN" run \
  --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid retention-unproven \
  >"$WORK/retention-unproven.out" 2>"$WORK/retention-unproven.err"
RC=$?
# Mutation: accepting a name, absent marker, wrong marker, or followed symlink as proof removes a seed.
check '[ "$RC" = 0 ] && [ -d "$UNPROVEN_ROOT/no-marker" ] &&
       [ -d "$UNPROVEN_ROOT/wrong-marker" ] &&
       [ -L "$UNPROVEN_ROOT/directory-symlink" ] && [ -d "$WORK/outside-run" ]' \
  "limit zero silently preserves every unproven directory and directory symlink"
# Mutation: allowing the run root into the candidate set removes the store itself.
check '[ -d "$UNPROVEN_ROOT" ] && [ -f "$UNPROVEN_ROOT/.codex-delegate-run" ]' \
  "a prune pass refuses the run root itself"

FIFO_ROOT=$WORK/fifo-runs
mkdir -p "$FIFO_ROOT/fifo-marker" "$FIFO_ROOT/fifo-pid"
mkfifo "$FIFO_ROOT/fifo-marker/.codex-delegate-run"
printf '%s\n' 'codex-delegate run directory' \
  >"$FIFO_ROOT/fifo-pid/.codex-delegate-run"
mkfifo "$FIFO_ROOT/fifo-pid/pid"
CODEX_DELEGATE_HOME=$FIFO_ROOT CODEX_DELEGATE_TEST_BIN=$BIN \
  CODEX_DELEGATE_TEST_KEEP_LIMIT=0 STUB_MODE=ok "$BIN" run \
  --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid retention-fifo \
  >"$WORK/retention-fifo.out" 2>"$WORK/retention-fifo.err" &
FIFO_LAUNCHER_PID=$!
FIFO_WAIT=0
while kill -0 "$FIFO_LAUNCHER_PID" 2>/dev/null && [ "$FIFO_WAIT" -lt 500 ]; do
  sleep 0.01
  FIFO_WAIT=$((FIFO_WAIT + 1))
done
if kill -0 "$FIFO_LAUNCHER_PID" 2>/dev/null; then
  kill -9 "$FIFO_LAUNCHER_PID" 2>/dev/null || true
  wait "$FIFO_LAUNCHER_PID" 2>/dev/null || true
  RC=124
else
  wait "$FIFO_LAUNCHER_PID"
  RC=$?
fi
# Mutation: omitting O_NONBLOCK from either ownership-marker or pid opens hangs pruning.
check '[ "$RC" = 0 ] && [ -p "$FIFO_ROOT/fifo-marker/.codex-delegate-run" ] &&
       [ -p "$FIFO_ROOT/fifo-pid/pid" ]' \
  "FIFO marker and pid paths are kept without blocking prune completion"

ORDER_ROOT=$WORK/ordered-runs
mkdir -p "$ORDER_ROOT/valid-old" "$ORDER_ROOT/valid-new"
for RUN_NAME in valid-old valid-new; do
  printf '%s\n' 'codex-delegate run directory' \
    >"$ORDER_ROOT/$RUN_NAME/.codex-delegate-run"
  : >"$ORDER_ROOT/$RUN_NAME/pid"
done
touch -t 202001010000 "$ORDER_ROOT/valid-old/.codex-delegate-run"
touch -t 202101010000 "$ORDER_ROOT/valid-new/.codex-delegate-run"
CODEX_DELEGATE_HOME=$ORDER_ROOT CODEX_DELEGATE_TEST_BIN=$BIN \
  CODEX_DELEGATE_TEST_KEEP_LIMIT=1 STUB_MODE=ok "$BIN" run \
  --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid retention-order \
  >"$WORK/retention-order.out" 2>"$WORK/retention-order.err"
RC=$?
# Mutation: sorting newest-first removes valid-new instead of valid-old.
check '[ "$RC" = 0 ] && [ ! -e "$ORDER_ROOT/valid-old" ] &&
       [ -d "$ORDER_ROOT/valid-new" ]' \
  "retention removes only the oldest proven inactive run beyond the limit"

LIVE_ROOT=$WORK/live-runs
mkdir -p "$LIVE_ROOT/live-old"
printf '%s\n' 'codex-delegate run directory' >"$LIVE_ROOT/live-old/.codex-delegate-run"
python3 -c 'import fcntl, os, sys, time
descriptor = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(descriptor, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)' "$LIVE_ROOT/live-old/pid" "$WORK/live-lock-ready" &
LIVE_LOCK_PID=$!
while [ ! -e "$WORK/live-lock-ready" ]; do sleep 0.01; done
CODEX_DELEGATE_HOME=$LIVE_ROOT CODEX_DELEGATE_TEST_BIN=$BIN \
  CODEX_DELEGATE_TEST_KEEP_LIMIT=0 STUB_MODE=ok "$BIN" run \
  --prompt-file "$WORK/prompt.txt" --sandbox read-only --cwd "$WORK/job" \
  --deadline 10 --model stub-model-a --effort medium --runid retention-live \
  >"$WORK/retention-live.out" 2>"$WORK/retention-live.err"
RC=$?
kill "$LIVE_LOCK_PID" 2>/dev/null || true
wait "$LIVE_LOCK_PID" 2>/dev/null || true
# Mutation: omitting the nonblocking pid-lock check removes live-old.
check '[ "$RC" = 0 ] && [ -d "$LIVE_ROOT/live-old" ]' \
  "a live proven run survives limit zero regardless of age"

check 'status_schemas_' "every run-suite verdict fixture has exactly 17 status fields"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
