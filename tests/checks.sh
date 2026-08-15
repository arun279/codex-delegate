#!/bin/bash
# Regression cases for release checks whose former green result proved too little.
# There is deliberately no embedded-Python line cap here: a cap that recognizes only some
# shell spellings of an embedded block passes files it never inspected, worse than no cap.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=$ROOT/bin/codex-delegate
GUARD_BASH=$ROOT/hooks/guard-bash.py
RELEASE_INVARIANTS=$ROOT/scripts/release-invariants.py
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" checks || {
  echo "checks: temporary directory creation failed" >&2
  exit 2
}
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
test_temp_install_traps
export TMPDIR=$WORK

PASS=0
FAIL=0
CASE=0

ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  if [ -s "$2" ]; then
    sed 's/^/       | /' "$2"
  else
    printf '       | (no output)\n'
  fi
}

run_case() {
  CASE=$((CASE + 1))
  CASE_OUT=$WORK/case-$CASE.out
  "$@" >"$CASE_OUT" 2>&1
  CASE_RC=$?
}

expect_diagnostic() { # expected-exit newline-separated-fixed-diagnostics label command...
  local expected_rc=$1 diagnostic=$2 label=$3
  local missing=
  shift 3
  run_case "$@"
  while IFS= read -r required; do
    if ! grep -Fq "$required" "$CASE_OUT"; then
      missing="${missing}${missing:+; }$required"
    fi
  done <<<"$diagnostic"
  if [ "$CASE_RC" -eq "$expected_rc" ] && [ -z "$missing" ]; then
    ok "$label"
  else
    bad "$label (exit $CASE_RC, expected $expected_rc; missing: $missing)" "$CASE_OUT"
  fi
}

expect_diagnostic_without() { # expected-exit required forbidden label command...
  local expected_rc=$1 required=$2 forbidden=$3 label=$4
  shift 4
  run_case "$@"
  if [ "$CASE_RC" -eq "$expected_rc" ] && grep -Fq "$required" "$CASE_OUT" &&
    ! grep -Fq "$forbidden" "$CASE_OUT"; then
    ok "$label"
  else
    bad "$label (exit $CASE_RC, expected $expected_rc; required: $required; forbidden: $forbidden)" \
      "$CASE_OUT"
  fi
}

expect_silent_exit() { # expected-exit label command...
  local expected_rc=$1 label=$2
  shift 2
  run_case "$@"
  if [ "$CASE_RC" -eq "$expected_rc" ] && [ ! -s "$CASE_OUT" ]; then
    ok "$label"
  else
    bad "$label (exit $CASE_RC, expected silent exit $expected_rc)" "$CASE_OUT"
  fi
}

guard_request() { # guard command
  local guard=$1 command=$2
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1],"run_in_background":True}}))' "$command" |
    "$guard"
}

expect_guard() { # allow|deny label guard command
  local expected=$1 label=$2 guard=$3 command=$4
  run_case guard_request "$guard" "$command"
  if [ "$CASE_RC" -ne 0 ]; then
    bad "$label (hook exited $CASE_RC)" "$CASE_OUT"
  elif [ "$expected" = allow ] && [ ! -s "$CASE_OUT" ]; then
    ok "$label"
  elif [ "$expected" = deny ] && grep -Fq '"permissionDecision": "deny"' "$CASE_OUT" &&
    grep -Fq "Re-emit the kickoff exactly as the runner instructions specify." "$CASE_OUT"; then
    ok "$label"
  else
    bad "$label (expected $expected)" "$CASE_OUT"
  fi
}

expect_guard_denies() { # label guard command
  local label=$1 guard=$2 command=$3
  run_case guard_request "$guard" "$command"
  if [ "$CASE_RC" -eq 0 ] && grep -Fq '"permissionDecision": "deny"' "$CASE_OUT"; then
    ok "$label"
  else
    bad "$label (expected deny)" "$CASE_OUT"
  fi
}

expect_mutant_allows() { # mutant label command
  expect_guard allow "$2" "$1" "$3"
}

expect_mutant_denies() { # mutant label command
  expect_guard_denies "$2" "$1" "$3"
}

printf '\n== runner kickoff grammar\n'
RUNNER_DELIMITER=CODEX_DELEGATE_PROMPT_0123456789ABCDEFGHIJKLMNOPQRSTUV
RUNNER_VALID="codex-delegate run --runner-handoff --sandbox workspace-write --cwd /tmp/job --add-dir /tmp/extra --schema ./result.json --model gpt-5.1 --effort high --deadline 7200 --network --prompt-stdin <<'$RUNNER_DELIMITER'
prompt bytes with \$() and quotes stay inert
$RUNNER_DELIMITER
"
RUNNER_HYPHENATED_EFFORT="codex-delegate run --runner-handoff --sandbox workspace-write --cwd /tmp/My_Project/repo --add-dir /tmp/Application-Support/data --schema /tmp/result-schema.json --effort x-high --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_CATALOG_EFFORT="codex-delegate run --runner-handoff --sandbox read-only --effort X2.high_low --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_LAUNCHER_SANDBOX="codex-delegate run --runner-handoff --sandbox bogus --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_LAUNCHER_DEADLINE="codex-delegate run --runner-handoff --sandbox read-only --deadline 999999 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_QUOTED_PATH="codex-delegate run --runner-handoff --sandbox read-only --cwd '/tmp/My Project/repo' --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_ESCAPED_PATH="codex-delegate run --runner-handoff --sandbox read-only --cwd /tmp/My\\ Project/repo --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_OPTION_PATH="codex-delegate run --runner-handoff --sandbox read-only --cwd '--option-like path' --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_SUBSTITUTION="codex-delegate run --runner-handoff --sandbox read-only --model safe\$(printf x) --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_UNQUOTED="codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<$RUNNER_DELIMITER
prompt
$RUNNER_DELIMITER
"
RUNNER_WRONG_DELIMITER="codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<'SHORT'
prompt
SHORT
"
RUNNER_INTERIOR="codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
more prompt
$RUNNER_DELIMITER
"
RUNNER_SECOND="codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
printf done
"
RUNNER_RUNID="codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --runid chosen --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_PROMPT_FILE="codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-file /tmp/prompt --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_ASSIGNMENT="SAFE=1 codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_WRAPPER="env codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_SU_CODE="su -c 'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin'"
RUNNER_MAKE_STDIN="make -f - <<'MAKEFILE'
all:
	codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin
MAKEFILE
"
RUNNER_TRAP="trap 'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --cwd \$(touch /tmp/runner-trap-side-effect) --prompt-stdin <<EOF
\$(id -un)
EOF' EXIT"
RUNNER_GIT_CORE_PAGER="git -c core.pager='codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --cwd \$(touch /tmp/runner-git-side-effect) --prompt-stdin' log"
RUNNER_GIT_CORE_SSH="git -c core.sshCommand='codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin' fetch"
RUNNER_GIT_DIFF_EXTERNAL="git -c diff.external='codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin' diff"
RUNNER_GIT_EXTERNAL_DIFF_ENV="GIT_EXTERNAL_DIFF='codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin' git diff"
RUNNER_GIT_SSH_ENV="GIT_SSH_COMMAND='codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin' git fetch"
RUNNER_GIT_PAGER_ENV="GIT_PAGER='codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin' git log"
RUNNER_PAGER_ENV="PAGER='codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin' git log"
RUNNER_BRACE_RUNID="codex-delegate run --runner-handoff --sandbox read-only --add-dir {/tmp,--runid,chosen} --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_BRACE_SANDBOX="codex-delegate run --runner-handoff --sandbox read-only --add-dir {/tmp,--sandbox,danger-full-access} --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_DUPLICATE_SANDBOX="codex-delegate run --runner-handoff --sandbox read-only --sandbox danger-full-access --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_GLOB="codex-delegate run --runner-handoff --sandbox read-only --add-dir /tmp/* --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_BASH_C="bash -c 'codex-delegate run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin'"
RUNNER_BASH_C_UNTERMINATED_HEREDOC="bash -c 'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin <<D
INJECTED
'"
RUNNER_SH_C_UNTERMINATED_HEREDOC="sh -c 'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin <<D
INJECTED
'"
RUNNER_EVAL_UNTERMINATED_HEREDOC="eval 'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin <<D
INJECTED
'"
RUNNER_ENV_BASH_C_UNTERMINATED_HEREDOC="env bash -c 'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin <<D
INJECTED
'"
RUNNER_BASH_C_INDENTED_HEREDOC="bash -c 'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin <<D
INJECTED
  D
'"
RUNNER_BASH_HERE_STRING="bash <<<'codex-delegate run --runner-handoff --sandbox danger-full-access --deadline 60 --prompt-stdin'"
RUNNER_ENV_EXPAND="DELEGATE=codex-delegate
\$DELEGATE run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_CONSTRUCTED="\$(printf codex-delegate) run --runner-handoff --sandbox read-only --deadline 10 --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_AMBIGUOUS="codex-delegate run --runner-handoff '"
RUNNER_RAW_SUFFIX="run --runner-handoff --sandbox read-only --deadline 10 --cwd \$(printf PWNED) __CODEX_DELEGATE_GUARD_PART_ --prompt-stdin <<'$RUNNER_DELIMITER'
prompt
$RUNNER_DELIMITER
"
RUNNER_RAW_TAB="codex-delegate"$'\t'"$RUNNER_RAW_SUFFIX"
RUNNER_RAW_SPACES="codex-delegate  $RUNNER_RAW_SUFFIX"
RUNNER_RAW_CONTINUED="codex-delegate \\"
RUNNER_RAW_CONTINUED="$RUNNER_RAW_CONTINUED
$RUNNER_RAW_SUFFIX"
RUNNER_DEEP='codex exec hi; echo '
RUNNER_DEEP_SUFFIX=
for _ in $(seq 1 300); do
  RUNNER_DEEP="${RUNNER_DEEP}\$("
  RUNNER_DEEP_SUFFIX=")${RUNNER_DEEP_SUFFIX}"
done
RUNNER_DEEP="${RUNNER_DEEP}echo hi${RUNNER_DEEP_SUFFIX}"

expect_guard allow "the documented runner kickoff passes the real PreToolUse hook" "$GUARD_BASH" "$RUNNER_VALID"
expect_guard allow "an unquoted safe path and hyphenated effort pass the real PreToolUse hook" \
  "$GUARD_BASH" "$RUNNER_HYPHENATED_EFFORT"
expect_guard allow "the launcher's full effort token class passes the real PreToolUse hook" \
  "$GUARD_BASH" "$RUNNER_CATALOG_EFFORT"
expect_guard allow "sandbox value validation remains launcher-owned" "$GUARD_BASH" "$RUNNER_LAUNCHER_SANDBOX"
expect_guard allow "deadline value validation remains launcher-owned" "$GUARD_BASH" "$RUNNER_LAUNCHER_DEADLINE"
expect_guard allow "a quoted read-only search for both trigger strings remains allowed" "$GUARD_BASH" \
  "rg -n 'codex-delegate run' -- '--runner-handoff' README.md"
expect_guard allow "quoted grep patterns for both trigger strings remain allowed" "$GUARD_BASH" \
  "grep -e 'codex-delegate run' -e '--runner-handoff' README.md"
expect_guard allow "rg can search the launcher for the runner handoff flag" "$GUARD_BASH" \
  "rg -n -- --runner-handoff bin/codex-delegate"
expect_guard allow "grep can search the launcher for the runner handoff flag" "$GUARD_BASH" \
  "grep -n -e '--runner-handoff' bin/codex-delegate"
expect_guard allow "git log can search launcher history for the runner handoff flag" "$GUARD_BASH" \
  "git log -S --runner-handoff -- bin/codex-delegate"
expect_guard allow "a comment can name the runner handoff flag beside a launcher path" "$GUARD_BASH" \
  "wc -l bin/codex-delegate agents/runner.md # --runner-handoff"
expect_guard deny "a quoted runner path is denied" "$GUARD_BASH" "$RUNNER_QUOTED_PATH"
expect_guard deny "a backslash-escaped runner path is denied" "$GUARD_BASH" "$RUNNER_ESCAPED_PATH"
expect_guard deny "an option-like quoted cwd is denied" "$GUARD_BASH" "$RUNNER_OPTION_PATH"
expect_guard deny "argument command substitution is denied" "$GUARD_BASH" "$RUNNER_SUBSTITUTION"
expect_guard deny "brace expansion cannot smuggle a runner run ID" "$GUARD_BASH" "$RUNNER_BRACE_RUNID"
expect_guard deny "brace expansion cannot override the runner sandbox" "$GUARD_BASH" "$RUNNER_BRACE_SANDBOX"
expect_guard deny "a duplicate sandbox flag cannot override the runner sandbox" "$GUARD_BASH" \
  "$RUNNER_DUPLICATE_SANDBOX"
expect_guard deny "pathname expansion is denied in runner arguments" "$GUARD_BASH" "$RUNNER_GLOB"
expect_guard deny "a bash -c runner wrapper is denied" "$GUARD_BASH" "$RUNNER_BASH_C"
expect_guard deny "an unterminated runner heredoc in bash -c is denied" \
  "$GUARD_BASH" "$RUNNER_BASH_C_UNTERMINATED_HEREDOC"
expect_guard deny "an unterminated runner heredoc in sh -c is denied" \
  "$GUARD_BASH" "$RUNNER_SH_C_UNTERMINATED_HEREDOC"
expect_guard deny "an unterminated runner heredoc in eval is denied" \
  "$GUARD_BASH" "$RUNNER_EVAL_UNTERMINATED_HEREDOC"
expect_guard deny "an unterminated runner heredoc in env bash -c is denied" \
  "$GUARD_BASH" "$RUNNER_ENV_BASH_C_UNTERMINATED_HEREDOC"
expect_guard deny "an indented runner heredoc terminator in bash -c is denied" \
  "$GUARD_BASH" "$RUNNER_BASH_C_INDENTED_HEREDOC"
expect_guard deny "a runner kickoff in a bash here-string is denied" \
  "$GUARD_BASH" "$RUNNER_BASH_HERE_STRING"
expect_guard deny "an assigned runner executable expansion is denied" "$GUARD_BASH" "$RUNNER_ENV_EXPAND"
expect_guard deny "a command substitution producing the runner executable is denied" \
  "$GUARD_BASH" "$RUNNER_CONSTRUCTED"
expect_guard deny "an unquoted runner heredoc delimiter is denied" "$GUARD_BASH" "$RUNNER_UNQUOTED"
expect_guard deny "a runner heredoc delimiter with the wrong shape is denied" "$GUARD_BASH" "$RUNNER_WRONG_DELIMITER"
expect_guard deny "an interior runner delimiter line is denied" "$GUARD_BASH" "$RUNNER_INTERIOR"
expect_guard deny "a second command after the runner heredoc is denied" "$GUARD_BASH" "$RUNNER_SECOND"
expect_guard deny "a runner-selected run ID is denied" "$GUARD_BASH" "$RUNNER_RUNID"
expect_guard deny "a runner prompt file is denied" "$GUARD_BASH" "$RUNNER_PROMPT_FILE"
expect_guard deny "a runner environment-assignment prefix is denied" "$GUARD_BASH" "$RUNNER_ASSIGNMENT"
expect_guard deny "a runner wrapper program is denied" "$GUARD_BASH" "$RUNNER_WRAPPER"
expect_guard deny "a runner kickoff in su command code is denied" "$GUARD_BASH" "$RUNNER_SU_CODE"
expect_guard deny "a runner kickoff in a stdin makefile is denied" "$GUARD_BASH" "$RUNNER_MAKE_STDIN"
expect_guard deny "a runner kickoff in a trap handler is denied" "$GUARD_BASH" "$RUNNER_TRAP"
expect_guard deny "a runner kickoff in git core.pager is denied" "$GUARD_BASH" "$RUNNER_GIT_CORE_PAGER"
expect_guard deny "a runner kickoff in git core.sshCommand is denied" "$GUARD_BASH" "$RUNNER_GIT_CORE_SSH"
expect_guard deny "a runner kickoff in git diff.external is denied" "$GUARD_BASH" "$RUNNER_GIT_DIFF_EXTERNAL"
expect_guard deny "a runner kickoff in GIT_EXTERNAL_DIFF remains denied" "$GUARD_BASH" \
  "$RUNNER_GIT_EXTERNAL_DIFF_ENV"
expect_guard deny "a runner kickoff in GIT_SSH_COMMAND remains denied" "$GUARD_BASH" "$RUNNER_GIT_SSH_ENV"
expect_guard deny "a runner kickoff in GIT_PAGER remains denied" "$GUARD_BASH" "$RUNNER_GIT_PAGER_ENV"
expect_guard deny "a runner kickoff in PAGER remains denied" "$GUARD_BASH" "$RUNNER_PAGER_ENV"
expect_guard deny "an unparseable raw runner signature fails closed" "$GUARD_BASH" "$RUNNER_AMBIGUOUS"
expect_guard deny "a tab-separated unparseable runner signature fails closed" "$GUARD_BASH" "$RUNNER_RAW_TAB"
expect_guard deny "a double-space unparseable runner signature fails closed" "$GUARD_BASH" "$RUNNER_RAW_SPACES"
expect_guard deny "a continued-line unparseable runner signature fails closed" "$GUARD_BASH" "$RUNNER_RAW_CONTINUED"
expect_guard_denies "a direct Codex launch remains denied after runner-validator recursion" \
  "$GUARD_BASH" "$RUNNER_DEEP"

MUTANT_ROOT=$WORK/runner-mutants
mkdir -p "$MUTANT_ROOT"
sed -e 's/^    if invalid_raw:/    if False:/' \
  -e 's/^    if any(kind != "literal" for word in words for kind, _ in word.parts):/    if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/literal-protections-dropped.py"
sed 's/^    if invalid_raw:/    if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/raw-argument-character-check-dropped.py"
sed -e 's/^    if not heredoc.quoted:/    if False:/' \
  -e 's/^    if header_match is None or header_match.group("delimiter") != delimiter:/    if False:/' \
  -e 's/header_match.group("argv")/" ".join(word.raw for word in words)/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/quoted-delimiter-check-dropped.py"
sed -e 's/^    if len(commands) != 1:/    if False:/' \
  -e 's/^    if remainder and not remainder.isspace():/    if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/single-command-rule-dropped.py"
sed 's@return "rule 1 (an ambiguous kickoff parse must fail closed)" if _runner_raw_matches(command) else None@return None@' \
  "$GUARD_BASH" >"$MUTANT_ROOT/ambiguity-branch-made-allow.py"
sed 's/^        return runner$/        return False/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/nested-parse-failure-made-allow.py"
sed 's/^        deny = starts_codex(command)$/        runner_kickoff_violation(command)\n        deny = starts_codex(command)/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/runner-validation-before-direct-check.py"
sed 's@^RUNNER_DELIMITER = .*@RUNNER_DELIMITER = re.compile(r"^.+$")@' \
  "$GUARD_BASH" >"$MUTANT_ROOT/delimiter-shape-check-dropped.py"
sed 's@^RUNNER_VALUE_FLAGS = .*@RUNNER_VALUE_FLAGS = RUNNER_FLAGS | {"--runid", "--prompt-file"}@' \
  "$GUARD_BASH" >"$MUTANT_ROOT/forbidden-flags-allowed.py"
sed -e 's/^    if assigned or len(words) != len(simple.words):/    if False:/' \
  -e 's/^    if invalid_raw:/    if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/assignment-prefix-check-dropped.py"
awk '
  $0 == "    if assigned or len(words) != len(simple.words):" { print "    if False:"; next }
  $0 == "    if invalid_raw:" { print "    if False:"; next }
  { print }
  $0 == "    del local" {
    print "    if words and _resolve_word(words[0], {}) == \"env\":"
    print "        words = words[1:]"
  }
' "$GUARD_BASH" >"$MUTANT_ROOT/wrapper-program-check-dropped.py"
sed 's/^        if _runner_raw_matches(command) and _scan_shell(command, {}, {}, runner=True):/        if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/nested-runner-check-dropped.py"
sed 's/^    if runner and name == "su":/    if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/su-code-sink-check-dropped.py"
sed 's/^        if effective is not None and runner and _program_name(effective\[0\]) == "make":/        if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/make-stdin-code-sink-check-dropped.py"
sed 's/^    if name == "trap" and args:/    if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/trap-code-sink-check-dropped.py"
sed 's/^    if name == "git":/    if False:/' \
  "$GUARD_BASH" >"$MUTANT_ROOT/git-config-code-sink-check-dropped.py"
awk '
  { print }
  $0 == "    stripped = _strip_heredoc_bodies(command)" {
    print "    if \"codex-delegate\" in command:"
    print "        return \"strictness mutant\""
  }
' "$GUARD_BASH" >"$MUTANT_ROOT/any-runner-text-denied.py"
chmod 700 "$MUTANT_ROOT"/*.py

expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the documented-kickoff allow check" "$RUNNER_VALID"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the hyphenated-effort allow check" \
  "$RUNNER_HYPHENATED_EFFORT"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the full-effort-token allow check" \
  "$RUNNER_CATALOG_EFFORT"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the launcher-owned sandbox allow check" \
  "$RUNNER_LAUNCHER_SANDBOX"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the launcher-owned deadline allow check" \
  "$RUNNER_LAUNCHER_DEADLINE"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the rg-search allow check" \
  "rg -n 'codex-delegate run' -- '--runner-handoff' README.md"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the grep-search allow check" \
  "grep -e 'codex-delegate run' -e '--runner-handoff' README.md"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the launcher-target rg check" \
  "rg -n -- --runner-handoff bin/codex-delegate"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the launcher-target grep check" \
  "grep -n -e '--runner-handoff' bin/codex-delegate"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the launcher-target git-log check" \
  "git log -S --runner-handoff -- bin/codex-delegate"
expect_mutant_denies "$MUTANT_ROOT/any-runner-text-denied.py" \
  "the any-runner-text-denied mutant is killed by the launcher-target comment check" \
  "wc -l bin/codex-delegate agents/runner.md # --runner-handoff"
expect_mutant_allows "$MUTANT_ROOT/literal-protections-dropped.py" \
  "the literal-protections-dropped mutant is killed by the substitution check" "$RUNNER_SUBSTITUTION"
expect_mutant_allows "$MUTANT_ROOT/literal-protections-dropped.py" \
  "the literal-protections-dropped mutant is killed by the constructed-executable check" \
  "$RUNNER_CONSTRUCTED"
expect_mutant_allows "$MUTANT_ROOT/raw-argument-character-check-dropped.py" \
  "the raw-argument-character-check-dropped mutant is killed by the run-ID brace check" \
  "$RUNNER_BRACE_RUNID"
expect_mutant_allows "$MUTANT_ROOT/raw-argument-character-check-dropped.py" \
  "the raw-argument-character-check-dropped mutant is killed by the sandbox brace check" \
  "$RUNNER_BRACE_SANDBOX"
expect_mutant_allows "$MUTANT_ROOT/raw-argument-character-check-dropped.py" \
  "the raw-argument-character-check-dropped mutant is killed by the quoted-path check" \
  "$RUNNER_QUOTED_PATH"
expect_mutant_allows "$MUTANT_ROOT/raw-argument-character-check-dropped.py" \
  "the raw-argument-character-check-dropped mutant is killed by the escaped-path check" \
  "$RUNNER_ESCAPED_PATH"
expect_mutant_allows "$MUTANT_ROOT/raw-argument-character-check-dropped.py" \
  "the raw-argument-character-check-dropped mutant is killed by the option-like-path check" \
  "$RUNNER_OPTION_PATH"
expect_mutant_allows "$MUTANT_ROOT/raw-argument-character-check-dropped.py" \
  "the raw-argument-character-check-dropped mutant is killed by the pathname-expansion check" \
  "$RUNNER_GLOB"
expect_mutant_allows "$MUTANT_ROOT/quoted-delimiter-check-dropped.py" \
  "the quoted-delimiter-check-dropped mutant is killed by the unquoted-delimiter check" "$RUNNER_UNQUOTED"
expect_mutant_allows "$MUTANT_ROOT/single-command-rule-dropped.py" \
  "the single-command-rule-dropped mutant is killed by the interior-delimiter check" "$RUNNER_INTERIOR"
expect_mutant_allows "$MUTANT_ROOT/single-command-rule-dropped.py" \
  "the single-command-rule-dropped mutant is killed by the trailing-command check" "$RUNNER_SECOND"
expect_mutant_allows "$MUTANT_ROOT/ambiguity-branch-made-allow.py" \
  "the ambiguity-branch-made-allow mutant is killed by the ambiguous-signature check" "$RUNNER_AMBIGUOUS"
expect_mutant_allows "$MUTANT_ROOT/ambiguity-branch-made-allow.py" \
  "the ambiguity-branch-made-allow mutant is killed by the tab-separated-signature check" "$RUNNER_RAW_TAB"
expect_mutant_allows "$MUTANT_ROOT/ambiguity-branch-made-allow.py" \
  "the ambiguity-branch-made-allow mutant is killed by the double-space-signature check" "$RUNNER_RAW_SPACES"
expect_mutant_allows "$MUTANT_ROOT/ambiguity-branch-made-allow.py" \
  "the ambiguity-branch-made-allow mutant is killed by the continued-line-signature check" "$RUNNER_RAW_CONTINUED"
expect_mutant_allows "$MUTANT_ROOT/runner-validation-before-direct-check.py" \
  "the runner-validation-before-direct-check mutant is killed by the recursion check" "$RUNNER_DEEP"
expect_mutant_allows "$MUTANT_ROOT/delimiter-shape-check-dropped.py" \
  "the delimiter-shape-check-dropped mutant is killed by the delimiter-shape check" "$RUNNER_WRONG_DELIMITER"
expect_mutant_allows "$MUTANT_ROOT/forbidden-flags-allowed.py" \
  "the forbidden-flags-allowed mutant is killed by the run-ID check" "$RUNNER_RUNID"
expect_mutant_allows "$MUTANT_ROOT/forbidden-flags-allowed.py" \
  "the forbidden-flags-allowed mutant is killed by the prompt-file check" "$RUNNER_PROMPT_FILE"
expect_mutant_allows "$MUTANT_ROOT/assignment-prefix-check-dropped.py" \
  "the assignment-prefix-check-dropped mutant is killed by the assignment-prefix check" "$RUNNER_ASSIGNMENT"
expect_mutant_allows "$MUTANT_ROOT/wrapper-program-check-dropped.py" \
  "the wrapper-program-check-dropped mutant is killed by the wrapper check" "$RUNNER_WRAPPER"
expect_mutant_allows "$MUTANT_ROOT/su-code-sink-check-dropped.py" \
  "the su-code-sink-check-dropped mutant is killed by the su command-code check" "$RUNNER_SU_CODE"
expect_mutant_allows "$MUTANT_ROOT/make-stdin-code-sink-check-dropped.py" \
  "the make-stdin-code-sink-check-dropped mutant is killed by the stdin-makefile check" \
  "$RUNNER_MAKE_STDIN"
expect_mutant_allows "$MUTANT_ROOT/trap-code-sink-check-dropped.py" \
  "the trap-code-sink-check-dropped mutant is killed by the trap-handler check" "$RUNNER_TRAP"
expect_mutant_allows "$MUTANT_ROOT/git-config-code-sink-check-dropped.py" \
  "the git-config-code-sink-check-dropped mutant is killed by the inline-pager check" \
  "$RUNNER_GIT_CORE_PAGER"
expect_mutant_allows "$MUTANT_ROOT/nested-runner-check-dropped.py" \
  "the nested-runner-check-dropped mutant is killed by the bash wrapper check" "$RUNNER_BASH_C"
expect_mutant_allows "$MUTANT_ROOT/nested-parse-failure-made-allow.py" \
  "the nested-parse-failure-made-allow mutant is killed by the malformed bash wrapper check" \
  "$RUNNER_BASH_C_UNTERMINATED_HEREDOC"
expect_mutant_allows "$MUTANT_ROOT/nested-parse-failure-made-allow.py" \
  "the nested-parse-failure-made-allow mutant is killed by the malformed sh wrapper check" \
  "$RUNNER_SH_C_UNTERMINATED_HEREDOC"
expect_mutant_allows "$MUTANT_ROOT/nested-parse-failure-made-allow.py" \
  "the nested-parse-failure-made-allow mutant is killed by the malformed eval check" \
  "$RUNNER_EVAL_UNTERMINATED_HEREDOC"
expect_mutant_allows "$MUTANT_ROOT/nested-parse-failure-made-allow.py" \
  "the nested-parse-failure-made-allow mutant is killed by the malformed env bash wrapper check" \
  "$RUNNER_ENV_BASH_C_UNTERMINATED_HEREDOC"
expect_mutant_allows "$MUTANT_ROOT/nested-parse-failure-made-allow.py" \
  "the nested-parse-failure-made-allow mutant is killed by the indented terminator check" \
  "$RUNNER_BASH_C_INDENTED_HEREDOC"
expect_mutant_allows "$MUTANT_ROOT/nested-runner-check-dropped.py" \
  "the nested-runner-check-dropped mutant is killed by the bash here-string check" \
  "$RUNNER_BASH_HERE_STRING"
expect_mutant_allows "$MUTANT_ROOT/nested-runner-check-dropped.py" \
  "the nested-runner-check-dropped mutant is killed by the assigned expansion check" \
  "$RUNNER_ENV_EXPAND"

tripwire() {
  printf '%s\n' "$1" | python3 "$RELEASE_INVARIANTS" dynamic-eval
}

timed_tripwire() {
  printf '%s\n' "$1" |
    perl -e 'alarm shift; exec @ARGV' 5 python3 "$RELEASE_INVARIANTS" dynamic-eval
}

invalid_utf8_tripwire() {
  printf 'x = 1\n\377\376\n' |
    PYTHONIOENCODING=utf-8:strict python3 "$RELEASE_INVARIANTS" dynamic-eval
}

null_byte_tripwire() {
  printf 'x = 1\000\n' | python3 "$RELEASE_INVARIANTS" dynamic-eval
}

decoded_streaming_check() {
  python3 -c 'import base64,importlib.util,sys; spec=importlib.util.spec_from_file_location("privacy_scan",sys.argv[1]); module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module; spec.loader.exec_module(module); text="\n".join(base64.b64encode(bytes([index])*65536).decode() for index in range(1,21)); values=list(module.encoded_candidates(text)); raise SystemExit(len(values) != 20 or max(len(value) for _,value in values) > module.MAX_DECODED_BYTES)' \
    "$ROOT/scripts/privacy-scan.py"
}

mutate_json() {
  python3 -c 'import json,sys; from functools import reduce; p,keys,raw=sys.argv[1],sys.argv[2].split("."),sys.argv[3]; value=json.load(open(p)); parent=reduce(lambda current,key: current[int(key)] if isinstance(current,list) else current[key],keys[:-1],value); last=keys[-1]; parent[last if isinstance(parent,dict) else int(last)]=json.loads(raw); json.dump(value,open(p,"w"))' "$@"
}

remove_json_phrase() { # file dotted-key phrase
  python3 -c 'import json,sys; from functools import reduce; p,keys,phrase=sys.argv[1],sys.argv[2].split("."),sys.argv[3]; value=json.load(open(p)); parent=reduce(lambda current,key: current[int(key)] if isinstance(current,list) else current[key],keys[:-1],value); last=keys[-1]; index=last if isinstance(parent,dict) else int(last); parent[index]=parent[index].replace(phrase,""); json.dump(value,open(p,"w"))' "$@"
}

isolation_mutation_check() {
  local isolated=$WORK/isolated-neighbor deisolated=$WORK/deisolated-neighbor
  local isolated_rc deisolated_rc
  mkdir "$isolated" "$deisolated" "$WORK/isolation-home" "$WORK/isolation-job" || return 2
  cp "$BIN" "$isolated/codex-delegate"
  awk '
    NR == 1 { print "#!/usr/bin/env python3"; next }
    $0 == "if not sys.flags.isolated or not sys.flags.no_site:" { guard = 1; next }
    guard && $0 == "    raise SystemExit(2)" { guard = 0; next }
    !guard { print }
  ' "$BIN" >"$deisolated/codex-delegate"
  chmod 700 "$isolated/codex-delegate" "$deisolated/codex-delegate"
  printf '%s\n' \
    'import os' \
    'open(os.environ["SECRETS_MARKER"], "w").write("imported")' \
    >"$isolated/secrets.py"
  cp "$isolated/secrets.py" "$deisolated/secrets.py"
  printf 'isolation prompt\n' >"$WORK/isolation-prompt.txt"

  env HOME="$WORK/isolation-home" PATH="$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_DELEGATE_HOME="$WORK/isolated-runs" STUB_MODE=ok \
    SECRETS_MARKER="$WORK/isolated-secrets" \
    "$isolated/codex-delegate" run --prompt-file "$WORK/isolation-prompt.txt" \
    --sandbox read-only --cwd "$WORK/isolation-job" --deadline 10 \
    --model stub-model-a --effort medium --runid isolated-neighbor \
    >"$WORK/isolated-copy.out" 2>&1
  isolated_rc=$?
  env HOME="$WORK/isolation-home" PATH="$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_DELEGATE_HOME="$WORK/deisolated-runs" STUB_MODE=ok \
    SECRETS_MARKER="$WORK/deisolated-secrets" \
    "$deisolated/codex-delegate" run --prompt-file "$WORK/isolation-prompt.txt" \
    --sandbox read-only --cwd "$WORK/isolation-job" --deadline 10 \
    --model stub-model-a --effort medium --runid deisolated-neighbor \
    >"$WORK/deisolated-copy.out" 2>&1
  deisolated_rc=$?

  [ "$isolated_rc" -eq 0 ] && [ ! -e "$WORK/isolated-secrets" ] &&
    python3 "$ROOT/tests/status_schema.py" --verdict COMPLETED \
      "$WORK/isolated-runs/isolated-neighbor/status.json" &&
    [ "$deisolated_rc" -ne 0 ] && [ -e "$WORK/deisolated-secrets" ]
}

preflight_does_not_spawn_launcher() {
  rm -f "$PREFLIGHT_MARKER"
  env PATH="$PREFLIGHT_PLUGIN_ROOT/bin:$PREFLIGHT_CODEX_PATH:$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
    PREFLIGHT_MARKER="$PREFLIGHT_MARKER" CLAUDE_PLUGIN_ROOT="$PREFLIGHT_PLUGIN_ROOT" \
    sh "$ROOT/hooks/preflight.sh" || return
  [ ! -e "$PREFLIGHT_MARKER" ]
}

bounded_preflight_version_probe() {
  local started=$SECONDS
  env PATH="$PREFLIGHT_VERSION_PATH:/usr/bin:/bin:/usr/sbin:/sbin" \
    CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/preflight.sh"
  [ $((SECONDS - started)) -lt 6 ]
}

write_stop_transcript() { # path kickoff-output later-output filler-count prose-suffix
  python3 -c '
import json, sys
path, kickoff, later, filler, suffix = sys.argv[1:]
records = [
    {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "kickoff-id", "name": "Bash", "input": {"command": "codex-delegate run --runner-handoff --sandbox read-only --deadline 7200"}}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "kickoff-id", "content": f"Command running in background with ID: kickoff. Output is being written to: {kickoff}.output{suffix}"}]}},
]
if later != "-":
    records.extend([
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "wait-id", "name": "Bash", "input": {"command": "codex-delegate runner-wait other.output"}}]}},
        {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "wait-id", "content": f"Command running in background with ID: wait. Output is being written to: {later}.output. If it exits while you are still working, call runner-wait again."}]}},
    ])
records.extend({"type": "progress", "message": {"role": "user", "content": [{"type": "text", "text": f"record {index}"}]}} for index in range(int(filler)))
with open(path, "w", encoding="utf-8") as stream:
    for record in records:
        stream.write(json.dumps(record) + "\n")
' "$@"
}

write_stop_payload() { # main-transcript agent-type agent-transcript-or-dash
  python3 -c '
import json, sys
main, agent_type, agent = sys.argv[1:]
payload = {
    "session_id": "session-probe",
    "transcript_path": main,
    "cwd": "/tmp/project",
    "permission_mode": "default",
    "hook_event_name": "SubagentStop",
    "stop_hook_active": False,
    "agent_id": "runner-probe",
    "agent_type": agent_type,
}
if agent != "-":
    payload["agent_transcript_path"] = agent
print(json.dumps(payload))
' "$@"
}

mutate_stop_hook() { # source destination old new
  python3 -c '
import sys
source, destination, old, new = sys.argv[1:]
text = open(source, encoding="utf-8").read()
if text.count(old) != 1:
    raise SystemExit(f"mutation target count was {text.count(old)}, expected 1")
with open(destination, "w", encoding="utf-8") as stream:
    stream.write(text.replace(old, new))
' "$@" && chmod 700 "$2"
}

stop_hook_run() { # hook payload plugin-root result-prefix
  local hook=$1 payload=$2 plugin_root=$3 prefix=$4
  env CLAUDE_PLUGIN_ROOT="$plugin_root" STUB_ARGV_CAPTURE="$prefix.argv" \
    STUB_ENV_CAPTURE="$prefix.env" "$hook" <"$payload" >"$prefix.stdout" 2>"$prefix.stderr"
  STOP_RC=$?
}

printf '\n== runner SubagentStop protection\n'
STOP_PLUGIN=$WORK/stop-plugin
STOP_HOOK=$ROOT/hooks/subagent-stop.py
mkdir -p "$STOP_PLUGIN/bin"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$@" >"$STUB_ARGV_CAPTURE"' \
  'printf "%s\n%s\n" "$CODEX_DELEGATE_RUNNER_WAIT_SECONDS" "$CODEX_DELEGATE_RUNNER_STARTUP_SECONDS" >"$STUB_ENV_CAPTURE"' \
  'case "$2" in *ended*) printf "%s\n" ENDED ;; *) printf "%s\n" RUNNING ;; esac' \
  >"$STOP_PLUGIN/bin/codex-delegate"
chmod 700 "$STOP_PLUGIN/bin/codex-delegate"

write_stop_transcript "$WORK/stop-main-ended.jsonl" "$WORK/main-ended" - 0 \
  '. If it exits while you are still working, call runner-wait again.'
write_stop_transcript "$WORK/stop-main-running.jsonl" "$WORK/main-running" - 0 \
  '. If it exits while you are still working, call runner-wait again.'
write_stop_transcript "$WORK/stop-running.jsonl" "$WORK/job-running" - 0 \
  '. If it exits while you are still working, call runner-wait again.'
write_stop_payload "$WORK/stop-main-ended.jsonl" codex-delegate:runner \
  "$WORK/stop-running.jsonl" >"$WORK/stop-running.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-running.payload" "$STOP_PLUGIN" "$WORK/stop-running"
if [ "$STOP_RC" -eq 2 ] &&
  grep -Fxq 'The delegated job is still RUNNING; keep calling runner-wait until it returns ENDED.' \
    "$WORK/stop-running.stderr" &&
  grep -Fxq 110 "$WORK/stop-running.env" && grep -Fxq 60 "$WORK/stop-running.env"; then
  ok "a RUNNING launcher blocks the runner stop with the corrective wait instruction"
else
  bad "a RUNNING launcher blocks the runner stop with the corrective wait instruction" \
    "$WORK/stop-running.stderr"
fi
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-wrong-transcript.py" \
  'payload.get("agent_transcript_path")' 'payload.get("transcript_path")' || {
  bad "the transcript-path mutation applies" "$WORK/stop-wrong-transcript.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-wrong-transcript.py" "$WORK/stop-running.payload" \
  "$STOP_PLUGIN" "$WORK/stop-wrong-transcript"
if [ "$STOP_RC" -eq 0 ]; then
  ok "the RUNNING case kills a transcript_path-for-agent_transcript_path mutant"
else
  bad "the RUNNING case kills a transcript_path-for-agent_transcript_path mutant" \
    "$WORK/stop-wrong-transcript.stderr"
fi

write_stop_transcript "$WORK/stop-ended.jsonl" "$WORK/job-ended" - 0 \
  '. If it exits while you are still working, call runner-wait again.'
write_stop_payload "$WORK/stop-main-running.jsonl" codex-delegate:runner \
  "$WORK/stop-ended.jsonl" >"$WORK/stop-ended.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-ended.payload" "$STOP_PLUGIN" "$WORK/stop-ended"
expect_ended_rc=$STOP_RC
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-ended-blocks.py" \
  'result.stdout.strip() == "RUNNING"' 'result.stdout.strip() in {"RUNNING", "ENDED"}' || {
  bad "the ENDED-blocking mutation applies" "$WORK/stop-ended-mutant.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-ended-blocks.py" "$WORK/stop-ended.payload" \
  "$STOP_PLUGIN" "$WORK/stop-ended-mutant"
if [ "$expect_ended_rc" -eq 0 ] && [ "$STOP_RC" -eq 2 ]; then
  ok "ENDED allows the stop and kills an ENDED-blocking mutant"
else
  bad "ENDED allows the stop and kills an ENDED-blocking mutant" "$WORK/stop-ended-mutant.stderr"
fi

write_stop_payload "$WORK/stop-main-ended.jsonl" another:runner \
  "$WORK/stop-running.jsonl" >"$WORK/stop-nonrunner.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-nonrunner.payload" "$STOP_PLUGIN" "$WORK/stop-nonrunner"
nonrunner_rc=$STOP_RC
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-no-type-check.py" \
  'if not isinstance(payload, dict) or payload.get("agent_type") != RUNNER_TYPE:' \
  'if not isinstance(payload, dict):' || {
  bad "the agent-type-check mutation applies" "$WORK/stop-nonrunner-mutant.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-no-type-check.py" "$WORK/stop-nonrunner.payload" \
  "$STOP_PLUGIN" "$WORK/stop-nonrunner-mutant"
if [ "$nonrunner_rc" -eq 0 ] && [ "$STOP_RC" -eq 2 ]; then
  ok "a non-runner allows the stop and kills an agent-type-check mutant"
else
  bad "a non-runner allows the stop and kills an agent-type-check mutant" \
    "$WORK/stop-nonrunner-mutant.stderr"
fi

mutate_stop_hook "$STOP_HOOK" "$WORK/stop-main-fallback.py" \
  'payload.get("agent_transcript_path")' \
  'payload.get("agent_transcript_path") or payload.get("transcript_path")' || {
  bad "the missing-transcript fallback mutation applies" "$WORK/stop-missing-path-mutant.stderr"
  exit 1
}
write_stop_payload "$WORK/stop-main-running.jsonl" codex-delegate:runner - \
  >"$WORK/stop-missing-path.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-missing-path.payload" "$STOP_PLUGIN" \
  "$WORK/stop-missing-path"
missing_path_rc=$STOP_RC
stop_hook_run "$WORK/stop-main-fallback.py" "$WORK/stop-missing-path.payload" \
  "$STOP_PLUGIN" "$WORK/stop-missing-path-mutant"
missing_path_mutant_rc=$STOP_RC
write_stop_payload "$WORK/stop-main-running.jsonl" codex-delegate:runner \
  "$WORK/does-not-exist.jsonl" >"$WORK/stop-unreadable.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-unreadable.payload" "$STOP_PLUGIN" "$WORK/stop-unreadable"
unreadable_rc=$STOP_RC
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-unreadable-fallback.py" \
  '_output_path(transcript_path)' \
  '_output_path(transcript_path) or _output_path(payload["transcript_path"])' || {
  bad "the unreadable-transcript fallback mutation applies" \
    "$WORK/stop-unreadable-mutant.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-unreadable-fallback.py" "$WORK/stop-unreadable.payload" \
  "$STOP_PLUGIN" "$WORK/stop-unreadable-mutant"
unreadable_mutant_rc=$STOP_RC
if [ "$missing_path_rc" -eq 0 ] && [ "$missing_path_mutant_rc" -eq 2 ] &&
  [ "$unreadable_rc" -eq 0 ] && [ "$unreadable_mutant_rc" -eq 2 ]; then
  ok "missing and unreadable agent transcripts allow and kill main-transcript fallback mutants"
else
  bad "missing and unreadable agent transcripts allow and kill main-transcript fallback mutants" \
    "$WORK/stop-unreadable-mutant.stderr"
fi

mutate_stop_hook "$STOP_HOOK" "$WORK/stop-error-blocks.py" \
  'except (OSError, ValueError, subprocess.TimeoutExpired):' \
  'except subprocess.TimeoutExpired:' || {
  bad "the launch-error mutation applies" "$WORK/stop-missing-launcher-mutant.stderr"
  exit 1
}
write_stop_payload "$WORK/stop-main-ended.jsonl" codex-delegate:runner \
  "$WORK/stop-running.jsonl" >"$WORK/stop-missing-launcher.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-missing-launcher.payload" "$WORK/missing-plugin" \
  "$WORK/stop-missing-launcher"
missing_launcher_rc=$STOP_RC
stop_hook_run "$WORK/stop-error-blocks.py" "$WORK/stop-missing-launcher.payload" \
  "$WORK/missing-plugin" "$WORK/stop-missing-launcher-mutant"
if [ "$missing_launcher_rc" -eq 0 ] && [ "$STOP_RC" -eq 1 ]; then
  ok "a missing launcher allows the stop and kills an uncaught-launch-error mutant"
else
  bad "a missing launcher allows the stop and kills an uncaught-launch-error mutant" \
    "$WORK/stop-missing-launcher-mutant.stderr"
fi

write_stop_transcript "$WORK/stop-correlated.jsonl" "$WORK/correlated-running" \
  "$WORK/later-ended" 0 '. If it exits while you are still working, call runner-wait again.'
write_stop_payload "$WORK/stop-main-ended.jsonl" codex-delegate:runner \
  "$WORK/stop-correlated.jsonl" >"$WORK/stop-correlated.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-correlated.payload" "$STOP_PLUGIN" "$WORK/stop-correlated"
correlated_rc=$STOP_RC
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-uncorrelated.py" \
  'if block.get("type") != "tool_result" or block.get("tool_use_id") not in kickoff_ids:' \
  'if block.get("type") != "tool_result":' || {
  bad "the uncorrelated-result mutation applies" "$WORK/stop-uncorrelated.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-uncorrelated.py" "$WORK/stop-correlated.payload" \
  "$STOP_PLUGIN" "$WORK/stop-uncorrelated"
if [ "$correlated_rc" -eq 2 ] && grep -Fxq "$WORK/correlated-running.output" \
  "$WORK/stop-correlated.argv" && [ "$STOP_RC" -eq 0 ]; then
  ok "only kickoff-correlated results supply the path and the last-record mutant fails"
else
  bad "only kickoff-correlated results supply the path and the last-record mutant fails" \
    "$WORK/stop-uncorrelated.stderr"
fi

write_stop_transcript "$WORK/stop-prose.jsonl" "$WORK/prose-running" - 0 \
  '. If it exits while you are still working, keep waiting for the launcher.'
write_stop_payload "$WORK/stop-main-ended.jsonl" codex-delegate:runner \
  "$WORK/stop-prose.jsonl" >"$WORK/stop-prose.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-prose.payload" "$STOP_PLUGIN" "$WORK/stop-prose"
prose_rc=$STOP_RC
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-greedy.py" \
  '(.+?\.output)(?=$|[\s.,;:!?\])}])' '(.+\.output.*)' || {
  bad "the greedy-regex mutation applies" "$WORK/stop-greedy.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-greedy.py" "$WORK/stop-prose.payload" "$STOP_PLUGIN" "$WORK/stop-greedy"
if [ "$prose_rc" -eq 2 ] && grep -Fxq "$WORK/prose-running.output" "$WORK/stop-prose.argv" &&
  [ "$STOP_RC" -eq 2 ] && [ -s "$WORK/stop-greedy.argv" ] &&
  ! grep -Fxq "$WORK/prose-running.output" "$WORK/stop-greedy.argv"; then
  ok "real harness prose yields a bare path and kills a greedy-regex mutant"
else
  bad "real harness prose yields a bare path and kills a greedy-regex mutant" \
    "$WORK/stop-greedy.stderr"
fi

write_stop_transcript "$WORK/stop-long.jsonl" "$WORK/long-running" - 4000 \
  '. If it exits while you are still working, call runner-wait again.'
write_stop_payload "$WORK/stop-main-ended.jsonl" codex-delegate:runner \
  "$WORK/stop-long.jsonl" >"$WORK/stop-long.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-long.payload" "$STOP_PLUGIN" "$WORK/stop-long"
long_rc=$STOP_RC
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-tail.py" \
  'for line in transcript:' 'for line in list(transcript)[-200:]:' || {
  bad "the transcript-tail mutation applies" "$WORK/stop-tail.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-tail.py" "$WORK/stop-long.payload" "$STOP_PLUGIN" "$WORK/stop-tail"
if [ "$long_rc" -eq 2 ] && [ "$STOP_RC" -eq 0 ]; then
  ok "the whole transcript is scanned and a last-200-lines mutant fails"
else
  bad "the whole transcript is scanned and a last-200-lines mutant fails" "$WORK/stop-tail.stderr"
fi

write_stop_transcript "$WORK/stop-torn.jsonl" "$WORK/torn-running" - 0 \
  '. If it exits while you are still working, call runner-wait again.'
printf '%s\342' '{"type":"progress","message":"' >>"$WORK/stop-torn.jsonl"
write_stop_payload "$WORK/stop-main-ended.jsonl" codex-delegate:runner \
  "$WORK/stop-torn.jsonl" >"$WORK/stop-torn.payload"
stop_hook_run "$STOP_HOOK" "$WORK/stop-torn.payload" "$STOP_PLUGIN" "$WORK/stop-torn"
torn_rc=$STOP_RC
mutate_stop_hook "$STOP_HOOK" "$WORK/stop-torn-whole-file.py" \
  'except json.JSONDecodeError:
                    continue' \
  'except json.JSONDecodeError:
                    return None' || {
  bad "the whole-file parse-failure mutation applies" "$WORK/stop-torn-mutant.stderr"
  exit 1
}
stop_hook_run "$WORK/stop-torn-whole-file.py" "$WORK/stop-torn.payload" \
  "$STOP_PLUGIN" "$WORK/stop-torn-mutant"
if [ "$torn_rc" -eq 2 ] && [ "$STOP_RC" -eq 0 ]; then
  ok "a torn UTF-8 trailing record preserves kickoff protection and kills the whole-file mutant"
else
  bad "a torn UTF-8 trailing record preserves kickoff protection and kills the whole-file mutant" \
    "$WORK/stop-torn-mutant.stderr"
fi

printf '\n== preflight launcher reachability\n'
PREFLIGHT_CODEX_PATH=$WORK/preflight-codex
mkdir -p "$PREFLIGHT_CODEX_PATH"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "codex-cli 0.146.1"' \
  >"$PREFLIGHT_CODEX_PATH/codex"
chmod 700 "$PREFLIGHT_CODEX_PATH/codex"
expect_silent_exit 0 \
  "the shipped launcher passes by absolute path without plugin bin on hook PATH" \
  env PATH="$PREFLIGHT_CODEX_PATH:$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/preflight.sh"

expect_diagnostic 0 "CLAUDE_PLUGIN_ROOT is empty" \
  "an empty plugin root produces a preflight diagnostic" \
  env PATH="$PREFLIGHT_CODEX_PATH:$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT= sh "$ROOT/hooks/preflight.sh"

MISSING_PLUGIN_ROOT=$WORK/missing-plugin
mkdir -p "$MISSING_PLUGIN_ROOT/bin"
expect_diagnostic 0 "is missing or not executable" \
  "a missing shipped launcher produces a preflight diagnostic" \
  env PATH="$PREFLIGHT_CODEX_PATH:$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$MISSING_PLUGIN_ROOT" sh "$ROOT/hooks/preflight.sh"

DIRECTORY_PLUGIN_ROOT=$WORK/directory-plugin
mkdir -p "$DIRECTORY_PLUGIN_ROOT/bin/codex-delegate"
expect_diagnostic 0 "is missing or not executable" \
  "a directory at the shipped launcher path produces a preflight diagnostic" \
  env PATH="$PREFLIGHT_CODEX_PATH:$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$DIRECTORY_PLUGIN_ROOT" sh "$ROOT/hooks/preflight.sh"

BROKEN_PLUGIN_ROOT=$WORK/broken-plugin
mkdir -p "$BROKEN_PLUGIN_ROOT/bin"
printf '%s\n' '#!/bin/sh' 'exit 42' >"$BROKEN_PLUGIN_ROOT/bin/codex-delegate"
chmod 700 "$BROKEN_PLUGIN_ROOT/bin/codex-delegate"
expect_diagnostic 0 $'Unsafe codex-delegate PATH mismatch\nIf you intend to use the separate copy instead, disable this plugin.' \
  "a different codex-delegate earlier on PATH produces a preflight diagnostic" \
  env PATH="$BROKEN_PLUGIN_ROOT/bin:$PREFLIGHT_CODEX_PATH:$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/preflight.sh"

PREFLIGHT_PLUGIN_ROOT=$WORK/preflight-plugin
PREFLIGHT_MARKER=$WORK/preflight-launcher-ran
mkdir -p "$PREFLIGHT_PLUGIN_ROOT/bin"
printf '%s\n' '#!/bin/sh' ': >"$PREFLIGHT_MARKER"' 'exit 0' \
  >"$PREFLIGHT_PLUGIN_ROOT/bin/codex-delegate"
chmod 700 "$PREFLIGHT_PLUGIN_ROOT/bin/codex-delegate"
expect_silent_exit 0 \
  "SessionStart inspects but does not spawn the shipped launcher" \
  preflight_does_not_spawn_launcher

printf '\n== preflight Codex CLI version\n'
PREFLIGHT_VERSION_PATH=$WORK/preflight-version
mkdir -p "$PREFLIGHT_VERSION_PATH"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "codex-cli 0.145.0"' \
  >"$PREFLIGHT_VERSION_PATH/codex"
chmod 700 "$PREFLIGHT_VERSION_PATH/codex"
expect_diagnostic 0 "Codex CLI version 0.145.0 is below the required minimum 0.146.1" \
  "a Codex CLI below the verified floor produces a warning" \
  env PATH="$PREFLIGHT_VERSION_PATH:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/preflight.sh"

printf '%s\n' '#!/bin/sh' 'printf "%s\n" "codex-cli 0.146.1"' \
  >"$PREFLIGHT_VERSION_PATH/codex"
expect_silent_exit 0 \
  "the current verified Codex CLI version produces no warning" \
  env PATH="$PREFLIGHT_VERSION_PATH:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/preflight.sh"

printf '%s\n' '#!/bin/sh' 'printf "%s\n" "codex-cli 0.148.0-alpha.9"' \
  >"$PREFLIGHT_VERSION_PATH/codex"
expect_silent_exit 0 \
  "a prerelease Codex CLI above the floor produces no warning" \
  env PATH="$PREFLIGHT_VERSION_PATH:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/preflight.sh"

printf '%s\n' '#!/bin/sh' 'exit 1' >"$PREFLIGHT_VERSION_PATH/codex"
expect_diagnostic 0 "Note: codex --version did not answer successfully" \
  "a failing Codex CLI version probe is non-blocking" \
  env PATH="$PREFLIGHT_VERSION_PATH:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/preflight.sh"

printf '%s\n' '#!/usr/bin/python3' 'import subprocess' \
  'raise SystemExit(subprocess.run(["/bin/sleep", "10"]).returncode)' \
  >"$PREFLIGHT_VERSION_PATH/codex"
expect_diagnostic 0 "Note: codex --version did not answer successfully" \
  "a wrapper with a hanging child is bounded and non-blocking" \
  bounded_preflight_version_probe

printf '\n== privacy representations\n'
MAC_USERS_SEGMENT=Users
PRIVATE_HOME="/$MAC_USERS_SEGMENT/someone/private.txt"
printf 'file://%s\n' "$PRIVATE_HOME" >"$WORK/file-uri.txt"
expect_diagnostic 1 "macos-home-path" \
  "a local file URI cannot hide an absolute macOS home path" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/file-uri.txt"

REMOVED_ENCODED_CANDIDATE_LIMIT=64
python3 -c '
import base64
import sys

benign = [
    base64.b64encode(f"benign-value-{index:04d}".encode())
    for index in range(int(sys.argv[3]))
]
private = base64.b64encode(sys.argv[2].encode())
with open(sys.argv[1], "wb") as output:
    output.write(b"\n".join([*benign, private]) + b"\n")
' "$WORK/base64-budget.txt" "$PRIVATE_HOME" "$REMOVED_ENCODED_CANDIDATE_LIMIT"
expect_diagnostic 1 "macos-home-path" \
  "benign base64 candidates cannot hide a later encoded home path" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/base64-budget.txt"

python3 -c '
import base64
import sys

chunk = base64.b64encode(b"A" * (600 * 1024))
with open(sys.argv[1], "wb") as output:
    output.write(chunk + b"\n" + chunk + b"\n")
' "$WORK/base64-aggregate.txt"
expect_diagnostic 0 "privacy scan: ok" \
  "benign aggregate base64 is scanned without aborting the scan" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/base64-aggregate.txt"

python3 -c '
import base64
import sys

decoy = b"B" * (1024 * 1024)
private = sys.argv[3].encode()
with open(sys.argv[1], "wb") as output:
    output.write(base64.b64encode(decoy) + b"\n" + base64.b64encode(private) + b"\n")
with open(sys.argv[2], "w", encoding="ascii") as output:
    output.write(decoy.hex() + "\n" + private.hex() + "\n")
' "$WORK/base64-late.txt" "$WORK/hex-late.txt" "$PRIVATE_HOME"
expect_diagnostic 1 "macos-home-path" \
  "a one-MiB base64 decoy cannot hide a later encoded home path" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/base64-late.txt"
expect_diagnostic 1 "macos-home-path" \
  "a one-MiB hex decoy cannot hide a later encoded home path" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/hex-late.txt"

python3 -c '
import base64
import sys

private = sys.argv[2].encode() + b"\n"
with open(sys.argv[1], "wb") as output:
    output.write(base64.b64encode(private + b"A" * (1100 * 1024)))
with open(sys.argv[3], "wb") as output:
    output.write((b"xxxx\n" + sys.argv[4].encode()).hex().encode() + b"00" * (1100 * 1024))
with open(sys.argv[5], "wb") as output:
    output.write(base64.b64encode(b"xxxx\n" + sys.argv[4].encode()).rstrip(b"="))
' "$WORK/base64-overlong.txt" "$PRIVATE_HOME" "$WORK/hex-overlong.txt" \
  "/$MAC_USERS_SEGMENT/a" "$WORK/base64-unpadded.txt"
expect_diagnostic 1 "macos-home-path" \
  "an overlong base64 run still scans its bounded decoded prefix" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/base64-overlong.txt"
expect_diagnostic 1 "macos-home-path" \
  "an overlong hexadecimal run still scans its bounded decoded prefix" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/hex-overlong.txt"
expect_diagnostic 1 "macos-home-path" \
  "an unpadded base64 run retains its final decoded bytes" \
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/base64-unpadded.txt"
expect_silent_exit 0 \
  "decoded candidates remain per-run bounded instead of forming an aggregate view" \
  decoded_streaming_check

printf '\n== release invariant types and versions\n'
RELEASE_ROOT=$WORK/release-fixture
mkdir -p "$RELEASE_ROOT/scripts" "$RELEASE_ROOT/.claude-plugin"
cp "$ROOT/scripts/release-invariants.py" "$RELEASE_ROOT/scripts/release-invariants.py"
cp "$ROOT/.claude-plugin/marketplace.json" "$RELEASE_ROOT/.claude-plugin/marketplace.clean.json"
cp "$ROOT/.claude-plugin/plugin.json" "$RELEASE_ROOT/.claude-plugin/plugin.json"
cp "$ROOT/package.json" "$RELEASE_ROOT/package.json"

cp "$RELEASE_ROOT/.claude-plugin/marketplace.clean.json" \
  "$RELEASE_ROOT/.claude-plugin/marketplace.json"
mutate_json "$RELEASE_ROOT/.claude-plugin/marketplace.json" owner.name 1
expect_diagnostic 1 "owner.name must be a non-empty string" \
  "marketplace owner.name rejects an integer" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" manifests

cp "$RELEASE_ROOT/.claude-plugin/marketplace.clean.json" \
  "$RELEASE_ROOT/.claude-plugin/marketplace.json"
mutate_json "$RELEASE_ROOT/.claude-plugin/marketplace.json" plugins.0.source 7
expect_diagnostic 1 "source must be a string or object" \
  "marketplace plugin source rejects an integer" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" manifests

mutate_json "$RELEASE_ROOT/package.json" version '"not-semver"'
mutate_json "$RELEASE_ROOT/.claude-plugin/plugin.json" version '"not-semver"'
expect_diagnostic 1 "is not valid SemVer" \
  "matching non-SemVer package and plugin versions are rejected" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" versions
expect_diagnostic 1 "is not valid SemVer" \
  "release-tag validation also rejects matching non-SemVer versions" \
  env RELEASE_TAG=vnot-semver GITHUB_OUTPUT="$WORK/release-output" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" release-versions

mutate_json "$RELEASE_ROOT/package.json" version '"0.2.0-rc.1"'
mutate_json "$RELEASE_ROOT/.claude-plugin/plugin.json" version '"0.2.0-rc.1"'
expect_diagnostic 0 "version 0.2.0-rc.1" \
  "SemVer prerelease identifiers are accepted" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" versions

mutate_json "$RELEASE_ROOT/package.json" version '"0.2.0+build.7"'
mutate_json "$RELEASE_ROOT/.claude-plugin/plugin.json" version '"0.2.0+build.7"'
expect_diagnostic 0 "version 0.2.0+build.7" \
  "SemVer build metadata identifiers are accepted" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" versions

cp "$RELEASE_ROOT/.claude-plugin/marketplace.clean.json" \
  "$RELEASE_ROOT/.claude-plugin/marketplace.json"
mutate_json "$RELEASE_ROOT/.claude-plugin/marketplace.json" owner.name '"Owner\u0001"'
expect_diagnostic 1 "owner.name holds hidden character U+0001" \
  "marketplace owner.name rejects hidden control characters" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" manifests

for manifest_key in \
  'package.json description' \
  '.claude-plugin/plugin.json description' \
  '.claude-plugin/marketplace.json plugins.0.description'; do
  set -- $manifest_key
  cp "$ROOT/package.json" "$RELEASE_ROOT/package.json"
  cp "$ROOT/.claude-plugin/plugin.json" "$RELEASE_ROOT/.claude-plugin/plugin.json"
  cp "$ROOT/.claude-plugin/marketplace.json" \
    "$RELEASE_ROOT/.claude-plugin/marketplace.json"
  remove_json_phrase "$RELEASE_ROOT/$1" "$2" \
    'Uses your ChatGPT Codex allowance or API-billed usage. '
  expect_diagnostic 1 "description omits account-funded usage" \
    "$1 pins the account-funded usage disclosure" \
    python3 "$RELEASE_ROOT/scripts/release-invariants.py" manifests
done
cp "$ROOT/package.json" "$RELEASE_ROOT/package.json"
cp "$ROOT/.claude-plugin/plugin.json" "$RELEASE_ROOT/.claude-plugin/plugin.json"
cp "$ROOT/.claude-plugin/marketplace.json" \
  "$RELEASE_ROOT/.claude-plugin/marketplace.json"
expect_silent_exit 0 \
  "all unmodified description copies satisfy the manifest disclosures" \
  python3 "$RELEASE_ROOT/scripts/release-invariants.py" manifests

printf '\n== publication copy\n'
PUBLICATION_ROOT=$WORK/publication-fixture
mkdir -p "$PUBLICATION_ROOT"/{agents,commands,scripts,skills/routing}
cp "$ROOT/scripts/release-invariants.py" \
  "$PUBLICATION_ROOT/scripts/release-invariants.py"
for publication_path in \
  agents/runner.md \
  commands/uninstall.md \
  skills/routing/SKILL.md \
  invalid.txt; do
  printf '%s\n' 'plain publication copy' >"$PUBLICATION_ROOT/$publication_path"
done
git -C "$PUBLICATION_ROOT" init --quiet
git -C "$PUBLICATION_ROOT" add .
expect_diagnostic 0 "publication copy: PASS" \
  "an unmodified publication copy passes" \
  python3 "$PUBLICATION_ROOT/scripts/release-invariants.py" publication-copy

for publication_path in \
  agents/runner.md \
  commands/uninstall.md \
  skills/routing/SKILL.md; do
  printf 'typographic \342\200\224 dash\n' >"$PUBLICATION_ROOT/$publication_path"
  expect_diagnostic 1 "$publication_path:1 contains typographic dash U+2014" \
    "$publication_path is covered by publication copy" \
    python3 "$PUBLICATION_ROOT/scripts/release-invariants.py" publication-copy
  printf '%s\n' 'plain publication copy' >"$PUBLICATION_ROOT/$publication_path"
done

printf '\377\376\n' >"$PUBLICATION_ROOT/invalid.txt"
expect_diagnostic_without 1 "invalid.txt cannot be read as UTF-8:" "Traceback" \
  "non-UTF-8 publication copy produces a clean diagnostic" \
  python3 "$PUBLICATION_ROOT/scripts/release-invariants.py" publication-copy
printf '%s\n' 'plain publication copy' >"$PUBLICATION_ROOT/invalid.txt"
expect_diagnostic 0 "publication copy: PASS" \
  "publication copy passes after every mutation is removed" \
  python3 "$PUBLICATION_ROOT/scripts/release-invariants.py" publication-copy

CLAIM_ROOT=$WORK/claim-fixture
mkdir -p "$CLAIM_ROOT"/{agents,bin,commands,hooks,scripts} \
  "$CLAIM_ROOT/.claude-plugin" "$CLAIM_ROOT/skills/routing/reference"
cp "$ROOT/agents/runner.md" "$CLAIM_ROOT/agents/runner.md"
cp "$ROOT/bin/codex-delegate" "$CLAIM_ROOT/bin/codex-delegate"
cp "$ROOT/commands/uninstall.md" "$CLAIM_ROOT/commands/uninstall.md"
cp "$ROOT/hooks/guard-bash.py" "$ROOT/hooks/hooks.json" "$CLAIM_ROOT/hooks/"
cp "$ROOT/scripts/claim-check.py" "$CLAIM_ROOT/scripts/claim-check.py"
cp "$ROOT/skills/routing/SKILL.md" "$CLAIM_ROOT/skills/routing/SKILL.md"
cp "$ROOT/skills/routing/reference/prompting.md" \
  "$ROOT/skills/routing/reference/status-and-trust.md" \
  "$CLAIM_ROOT/skills/routing/reference/"
cp "$ROOT/README.md" "$ROOT/PRIVACY.md" "$ROOT/SECURITY.md" "$CLAIM_ROOT/"
for manifest in package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  cp "$ROOT/$manifest" "$CLAIM_ROOT/$manifest"
done

for manifest_key in \
  'package.json description' \
  '.claude-plugin/plugin.json description' \
  '.claude-plugin/marketplace.json plugins.0.description'; do
  set -- $manifest_key
  cp "$ROOT/$1" "$CLAIM_ROOT/$1"
  remove_json_phrase "$CLAIM_ROOT/$1" "$2" 'Prompts and files are sent to OpenAI. '
  expect_diagnostic 1 "description omits the OpenAI data-egress disclosure" \
    "$1 pins the OpenAI data-egress disclosure" \
    python3 "$CLAIM_ROOT/scripts/claim-check.py"
done

CHANGELOG_ROOT=$WORK/changelog-fixture
mkdir -p "$CHANGELOG_ROOT/scripts" "$CHANGELOG_ROOT/bin"
cp "$ROOT/scripts/release-invariants.py" "$CHANGELOG_ROOT/scripts/release-invariants.py"
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '### Changed' '' \
  >"$CHANGELOG_ROOT/CHANGELOG.md"
printf '%s\n' 'retention behavior baseline' >"$CHANGELOG_ROOT/bin/codex-delegate"
git -C "$CHANGELOG_ROOT" init --quiet
git -C "$CHANGELOG_ROOT" config user.email checks@example.invalid
git -C "$CHANGELOG_ROOT" config user.name checks
git -C "$CHANGELOG_ROOT" add CHANGELOG.md bin/codex-delegate
git -C "$CHANGELOG_ROOT" commit --quiet -m baseline
printf '%s\n' 'retention behavior changed safely' >>"$CHANGELOG_ROOT/bin/codex-delegate"
expect_diagnostic 1 "product surface changed without a new CHANGELOG.md entry" \
  "a product-surface diff without a changelog entry is rejected" \
  env CHANGELOG_BASE=HEAD python3 "$CHANGELOG_ROOT/scripts/release-invariants.py" changelog
printf '%s\n' \
  '- Changed retention behavior safely.' \
  '  <!-- evidence: bin/codex-delegate :: retention behavior changed safely -->' \
  >>"$CHANGELOG_ROOT/CHANGELOG.md"
expect_diagnostic 0 "changelog: PASS (1 verified entries)" \
  "a product-surface diff with an evidenced changelog entry is accepted" \
  env CHANGELOG_BASE=HEAD python3 "$CHANGELOG_ROOT/scripts/release-invariants.py" changelog

NO_GIT_CHANGELOG_ROOT=$WORK/changelog-no-git
mkdir -p "$NO_GIT_CHANGELOG_ROOT/scripts" "$NO_GIT_CHANGELOG_ROOT/bin"
cp "$ROOT/scripts/release-invariants.py" \
  "$NO_GIT_CHANGELOG_ROOT/scripts/release-invariants.py"
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '### Changed' '' \
  '- Changed retention behavior safely.' \
  '  <!-- evidence: bin/codex-delegate :: retention behavior changed safely -->' \
  >"$NO_GIT_CHANGELOG_ROOT/CHANGELOG.md"
printf '%s\n' 'retention behavior changed safely' \
  >"$NO_GIT_CHANGELOG_ROOT/bin/codex-delegate"
expect_diagnostic 0 "product-diff coverage SKIP (no comparable Git base)" \
  "a source tree without Git metadata skips product-diff coverage" \
  env GIT_CEILING_DIRECTORIES="$WORK" \
  python3 "$NO_GIT_CHANGELOG_ROOT/scripts/release-invariants.py" changelog

ROOT_COMMIT_CHANGELOG_ROOT=$WORK/changelog-root-commit
cp -R "$NO_GIT_CHANGELOG_ROOT" "$ROOT_COMMIT_CHANGELOG_ROOT"
git -C "$ROOT_COMMIT_CHANGELOG_ROOT" init --quiet --initial-branch=feature
git -C "$ROOT_COMMIT_CHANGELOG_ROOT" config user.email checks@example.invalid
git -C "$ROOT_COMMIT_CHANGELOG_ROOT" config user.name checks
git -C "$ROOT_COMMIT_CHANGELOG_ROOT" add .
git -C "$ROOT_COMMIT_CHANGELOG_ROOT" commit --quiet -m only
expect_diagnostic 0 "product-diff coverage SKIP (no comparable Git base)" \
  "a root commit without a comparison target skips product-diff coverage" \
  python3 "$ROOT_COMMIT_CHANGELOG_ROOT/scripts/release-invariants.py" changelog

printf '\n== frontmatter completeness\n'
MODEL_ROOT=$WORK/model-fixture
mkdir -p "$MODEL_ROOT/scripts" "$MODEL_ROOT/agents"
cp "$ROOT/scripts/lint-frontmatter.py" "$MODEL_ROOT/scripts/lint-frontmatter.py"
printf '%s\n' \
  '---' \
  'name: probe' \
  'description: Regression probe.' \
  'model: claude-not-real' \
  '---' \
  >"$MODEL_ROOT/agents/probe.md"
expect_diagnostic 1 "is not a documented model alias or a version-bearing claude-* model ID" \
  "a nonexistent Claude model is rejected" \
  python3 "$MODEL_ROOT/scripts/lint-frontmatter.py"

for model in \
  claude-fable-5 \
  claude-mythos-5 \
  claude-mythos-preview \
  'claude-opus-5[1m]' \
  claude-3-5-sonnet-latest \
  claude-sonnet-4-5@20250929 \
  claude-opus-4-5@20251101 \
  claude-haiku-4-5@20251001 \
  claude-opus-4-1@20250805 \
  best \
  fable \
  'opus[1m]'; do
  printf '%s\n' \
    '---' \
    'name: probe' \
    'description: Regression probe.' \
    "model: $model" \
    '---' \
    >"$MODEL_ROOT/agents/probe.md"
  expect_diagnostic 0 "ok   agents/probe.md (agent)" \
    "documented model $model is accepted" \
    python3 "$MODEL_ROOT/scripts/lint-frontmatter.py"
done

EMPTY_ROOT=$WORK/empty-frontmatter-fixture
mkdir -p "$EMPTY_ROOT/scripts"
cp "$ROOT/scripts/lint-frontmatter.py" "$EMPTY_ROOT/scripts/lint-frontmatter.py"
expect_diagnostic 1 "no agent or skill frontmatter targets found" \
  "an empty frontmatter target surface fails closed" \
  python3 "$EMPTY_ROOT/scripts/lint-frontmatter.py"

printf '\n== security tripwires\n'
expect_silent_exit 1 \
  "the AST tripwire catches getattr access to os.system" \
  tripwire 'getattr(os, "system")("id")'
expect_silent_exit 1 \
  "the AST tripwire catches subscripted builtins eval" \
  tripwire '__builtins__["eval"]("p")'
expect_silent_exit 1 \
  "the AST tripwire catches an aliased eval" \
  tripwire 'run = eval; run("p")'
expect_silent_exit 1 \
  "the AST tripwire fails closed on a nonliteral os getattr" \
  tripwire 'name = "system"
getattr(os, name)("id")'
expect_silent_exit 1 \
  "the AST tripwire fails closed on a nonliteral os subscript" \
  tripwire 'key = "system"
os[key]("id")'
expect_silent_exit 1 \
  "the AST tripwire fails closed on a computed os getattr name" \
  tripwire 'getattr(os, "sys" + "tem")("id")'
expect_silent_exit 1 \
  "the AST tripwire fails closed on a nonliteral builtins getattr" \
  tripwire 'name = "compile"
getattr(builtins, name)("p", "x", "exec")'
expect_silent_exit 1 \
  "the AST tripwire catches importlib submodules" \
  tripwire 'import importlib.util
spec = importlib.util.spec_from_file_location("m", p)'
expect_silent_exit 1 \
  "the AST tripwire catches importlib from-imports" \
  tripwire 'from importlib import util'
expect_silent_exit 1 \
  "the AST tripwire catches runpy imports" \
  tripwire 'import runpy'
expect_silent_exit 1 \
  "the AST tripwire retains unresolved dotted eval coverage" \
  tripwire 'handler.eval("code")'
expect_silent_exit 1 \
  "the AST tripwire retains unresolved dotted exec coverage" \
  tripwire 'handler.exec("code")'
expect_silent_exit 1 \
  "the AST tripwire retains unresolved dotted import coverage" \
  tripwire 'plugin.__import__("os")'
expect_silent_exit 1 \
  "the AST tripwire resolves sys.modules dispatch" \
  tripwire 'import sys
sys.modules["os"].system("id")'
expect_silent_exit 1 \
  "the AST tripwire resolves an imported sys alias" \
  tripwire 'import sys as registry
registry.modules["os"].system("id")'
expect_silent_exit 1 \
  "the AST tripwire resolves an imported builtins alias" \
  tripwire 'import builtins as runtime
runtime.compile("p", "<s>", "exec")'
expect_silent_exit 1 \
  "the AST tripwire catches globals dispatch" \
  tripwire 'globals()["eval"]("p")'
expect_silent_exit 1 \
  "the AST tripwire retains direct os execution coverage" \
  tripwire 'os.system("id")'
expect_silent_exit 1 \
  "the AST tripwire retains os exec-family coverage" \
  tripwire 'os.execv(path, argv)'
expect_silent_exit 1 \
  "the AST tripwire retains os spawn-family coverage" \
  tripwire 'os.spawnv(mode, path, argv)'
expect_silent_exit 1 \
  "the AST tripwire retains os posix-spawn coverage" \
  tripwire 'os.posix_spawn(path, argv, env)'
expect_silent_exit 1 \
  "the AST tripwire retains os popen coverage" \
  tripwire 'os.popen("id")'
expect_silent_exit 1 \
  "the AST tripwire catches builtins.compile" \
  tripwire 'builtins.compile("p", "x", "exec")'
expect_silent_exit 1 \
  "the AST tripwire retains bare compile coverage" \
  tripwire 'compile("p", "x", "exec")'
expect_silent_exit 1 \
  "the AST tripwire retains bare exec coverage" \
  tripwire 'exec("p")'
expect_silent_exit 1 \
  "the AST tripwire retains bare import coverage" \
  tripwire '__import__("os")'
expect_silent_exit 1 \
  "the AST tripwire catches a dangerous from-import alias" \
  tripwire 'from builtins import eval as run
run("p")'
expect_silent_exit 1 \
  "the AST tripwire catches a dangerous os from-import alias" \
  tripwire 'from os import system as run
run("id")'
expect_silent_exit 1 \
  "the AST tripwire catches an imported module alias" \
  tripwire 'import os as process
process.system("id")'
expect_silent_exit 1 \
  "the AST tripwire catches an assigned module alias" \
  tripwire 'process = os
process.system("id")'
expect_silent_exit 1 \
  "the AST tripwire catches a tuple-unpacked callable alias" \
  tripwire 'run, safe = (eval, print)
run("p")'
expect_silent_exit 1 \
  "the AST tripwire resolves reverse-ordered callable alias chains" \
  tripwire 'second = first
first = eval
second("p")'
expect_silent_exit 0 \
  "the AST tripwire allows re.compile" \
  tripwire 're.compile("p")'
expect_silent_exit 0 \
  "the AST tripwire analyzes executed calls rather than inert text" \
  tripwire 'PAYLOAD = "os.system(id)"'
expect_silent_exit 0 \
  "a self-referential module alias terminates cleanly" \
  timed_tripwire 'os = os.path'
expect_silent_exit 2 \
  "unparseable Python is not reported as clean" \
  tripwire 'def broken(:
os.system("id")'
expect_silent_exit 2 \
  "a null byte is reported as unparseable rather than dangerous" \
  null_byte_tripwire
expect_diagnostic 2 "dynamic-eval check failed:" \
  "non-UTF-8 input is not reported as clean" \
  invalid_utf8_tripwire
expect_silent_exit 0 \
  "the isolation regression distinguishes the launcher from a de-isolated mutant" \
  isolation_mutation_check
expect_silent_exit 0 \
  "the security assertion names the specific os dispatch scope it checks" \
  sh -c 'grep -Fq "os process-dispatch surface" "$1" && ! grep -Fq "Python or process call surface" "$1"' \
  sh "$ROOT/tests/security.sh"

printf '\nChecks summary: %s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
