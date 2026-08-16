#!/bin/bash
# Security boundaries of the foreground blocking run.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=$ROOT/bin/codex-delegate
PERMISSION_HOOK=$ROOT/hooks/permission-allow.py
PRIVACY=$ROOT/PRIVACY.md
SECURITY=$ROOT/SECURITY.md
RELEASE_INVARIANTS=$ROOT/scripts/release-invariants.py
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" security || {
  echo "security: temporary directory creation failed" >&2
  exit 2
}
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
test_temp_install_traps

mkdir -p "$WORK/home" "$WORK/runs" "$WORK/job" "$WORK/extra" || exit 2
printf 'security prompt\n' >"$WORK/prompt.txt"
export HOME=$WORK/home
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
dynamic_eval_check_() { python3 "$RELEASE_INVARIANTS" dynamic-eval; }

permission_request() {
  PERMISSION_OUT=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" |
    python3 "$PERMISSION_HOOK")
  PERMISSION_RC=$?
}

head_ "false-green regression suite"
CHECKS_OUT=$WORK/checks.out
CHECKS_CASES=$WORK/checks-cases.actual
bash "$ROOT/tests/checks.sh" >"$CHECKS_OUT" 2>&1
RC=$?
cat "$CHECKS_OUT"
sed -n 's/^  ok   //p' "$CHECKS_OUT" >"$CHECKS_CASES"
check '[ "$RC" = 0 ] &&
       cmp -s "$ROOT/tests/red-fixtures/checks-cases.txt" "$CHECKS_CASES"' \
  "the focused hardening suite runs its complete pinned case set"

head_ "normal permission boundary"
SENSITIVE='codex-delegate run --sandbox danger-full-access --prompt-file ~/.aws/credentials'
permission_request "$SENSITIVE"
check '[ "$PERMISSION_RC" = 0 ] && [ -z "$PERMISSION_OUT" ]' \
  "the hook never auto-approves a sensitive launcher command"
permission_request 'codex-delegate run --sandbox read-only --prompt-stdin'
check '[ "$PERMISSION_RC" = 0 ] && [ -z "$PERMISSION_OUT" ]' \
  "the hook leaves even a simple run at the user boundary"

head_ "no internal interpreter surface"
CODEX_DELEGATE_HOME=$WORK/runs "$BIN" __supervise "$WORK/forged" \
  >"$WORK/internal.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "invalid choice" "$WORK/internal.out"' \
  "the deleted supervisor is not executable"
dynamic_eval_check_ <"$BIN"
RC=$?
check '[ "$RC" = 0 ]' \
  "the launcher has no built-in evaluation/import, importlib/runpy, or os process-dispatch surface for run-directory code"

head_ "isolated Python startup"
mkdir "$WORK/hostile-modules"
printf '%s\n' \
  'import os' \
  'open(os.environ["JSON_MARKER"], "w").write("imported")' \
  >"$WORK/hostile-modules/json.py"
printf '%s\n' \
  'import os' \
  'open(os.environ["SECRETS_MARKER"], "w").write("imported")' \
  >"$WORK/hostile-modules/secrets.py"
(cd "$WORK/hostile-modules" && PYTHONPATH=$WORK/hostile-modules \
  JSON_MARKER=$WORK/cwd-json SECRETS_MARKER=$WORK/cwd-secrets \
  "$BIN" --help >"$WORK/hostile-help.out" 2>&1)
RC=$?
check '[ "$RC" = 0 ] && [ ! -e "$WORK/cwd-json" ] && [ ! -e "$WORK/cwd-secrets" ]' \
  "PYTHONPATH and the caller working directory cannot shadow standard-library imports"
check 'head -n 1 "$BIN" | grep -Fxq "#!/usr/bin/env -S python3 -I -S"' \
  "the launcher shebang requires isolated startup without site initialization"
(cd "$WORK/hostile-modules" && PYTHONPATH=$WORK/hostile-modules \
  JSON_MARKER=$WORK/guard-json SECRETS_MARKER=$WORK/guard-secrets \
  python3 "$BIN" --help >"$WORK/non-isolated.out" 2>&1)
RC=$?
check '[ "$RC" = 2 ] &&
       grep -Fxq "codex-delegate: the launcher must run under python3 -I -S" "$WORK/non-isolated.out" &&
       [ ! -e "$WORK/guard-json" ] && [ ! -e "$WORK/guard-secrets" ]' \
  "the runtime guard rejects a non-isolated interpreter before hostile PYTHONPATH imports"
head_ "run storage authentication"
ln -s "$WORK/runs" "$WORK/link-root"
CODEX_DELEGATE_HOME=$WORK/link-root "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" >"$WORK/link.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "must not be a symlink" "$WORK/link.out"' \
  "a symlinked run root is refused"
mkdir "$WORK/shared"
chmod 0777 "$WORK/shared"
CODEX_DELEGATE_HOME=$WORK/shared/runs "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" >"$WORK/shared.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "writable by other users" "$WORK/shared.out"' \
  "a swappable non-sticky ancestor is refused"
CODEX_DELEGATE_HOME=$WORK/runs "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox read-only --cwd "$WORK/job" --runid ../outside >"$WORK/traversal.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && [ ! -e "$WORK/outside" ]' \
  "run ids cannot traverse outside control storage"

head_ "workspace control-state separation"
CODEX_DELEGATE_HOME=$WORK/job/control "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox workspace-write --cwd "$WORK/job" >"$WORK/inside.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "overlaps writable root" "$WORK/inside.out"' \
  "control state cannot live below a writable cwd"
mkdir -p "$WORK/outer/control"
CODEX_DELEGATE_HOME=$WORK/outer "$BIN" run --prompt-file "$WORK/prompt.txt" \
  --sandbox workspace-write --cwd "$WORK/outer/control" >"$WORK/contains.out" 2>&1
RC=$?
check '[ "$RC" = 2 ] && grep -q "overlaps writable root" "$WORK/contains.out"' \
  "a writable cwd cannot live below control state"

head_ "prompt privacy and literal paths"
SECRET='secret value with spaces $() and `backticks`'
printf '%s\n' "$SECRET" >"$WORK/secret-prompt.txt"
mkdir "$WORK/job/-P"
cd "$WORK/job" || exit 2
CODEX_DELEGATE_HOME=$WORK/runs STUB_MODE=ok STUB_ARGV_CAPTURE=$WORK/argv.txt \
  STUB_STDIN_CAPTURE=$WORK/stdin.txt "$BIN" run --prompt-file "$WORK/secret-prompt.txt" \
  --sandbox read-only --cwd=-P --runid secure >"$WORK/secure.out" 2>"$WORK/secure.err"
RC=$?
cd "$ROOT" || exit 2
check '[ "$RC" = 0 ] && cmp -s "$WORK/secret-prompt.txt" "$WORK/stdin.txt"' \
  "prompt content reaches Codex intact through stdin"
check '[ -f "$WORK/argv.txt" ] && ! grep -Fq "$SECRET" "$WORK/argv.txt"' \
  "prompt content is absent from Codex argv"
check 'grep -Fxq "cwd=$WORK/job/-P" "$WORK/argv.txt" &&
       grep -Fxq "process_cwd=$WORK/job/-P" "$WORK/argv.txt"' \
  "an option-like cwd is treated as a literal path"
check '[ "$(stat -f %Lp "$WORK/runs")" = 700 ] &&
       [ "$(stat -f %Lp "$WORK/runs/secure/prompt.txt")" = 600 ] &&
       [ "$(stat -f %Lp "$WORK/runs/secure/status.json")" = 400 ]' \
  "run storage and artifacts remain owner-only"
check 'python3 "$ROOT/tests/status_schema.py" "$WORK/runs/secure/status.json"' \
  "the security verdict fixture has exactly 17 status fields"

head_ "documented trust boundary"
check 'grep -q "raw Bash or Monitor command text contains.*runner-handoff" "$SECURITY" &&
       grep -q "parsed read-only searches whose inspected positions contain no invocation" "$SECURITY" &&
       grep -q "code sink outside the modeled set is not inspected" "$SECURITY" &&
       grep -q "guard makes them inert heredoc data, but does not verify" "$SECURITY" &&
       grep -q "danger-full-access" "$SECURITY" && grep -q "process group" "$SECURITY"' \
  "SECURITY.md states the scoped kickoff control and remaining trust limits"
check 'grep -q "prompt.txt" "$PRIVACY" && grep -q "stdin" "$PRIVACY"' \
  "PRIVACY.md discloses prompt storage and child transport"

printf '\nSecurity summary: %s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
