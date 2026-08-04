#!/bin/bash
# One release-readiness answer. Continue through failures so the summary is complete.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT" || exit 2

NAMES=()
RESULTS=()
CODES=()
FAILED=0
GATE_STEP_TIMEOUT_S=${GATE_STEP_TIMEOUT_S:-120}
GATE_SUITE_TIMEOUT_S=${GATE_SUITE_TIMEOUT_S:-600}
GATE_SIGNAL_GRACE_S=${GATE_SIGNAL_GRACE_S:-2}

record() {
  NAMES+=("$1")
  RESULTS+=("$2")
  CODES+=("$3")
}

run_bounded() { # seconds name command...
  local seconds=$1 name=$2
  shift 2
  perl -MPOSIX=:sys_wait_h -MTime::HiRes=time,sleep -e '
    my ($limit, $grace, $name, @command) = @ARGV;
    for ($limit, $grace) { /^\d+(?:\.\d+)?$/ && $_ > 0 or exit 2 }
    my $child = fork();
    defined $child or exit 125;
    if (!$child) {
      POSIX::setpgid(0, 0) == 0 or exit 125;
      exec {$command[0]} @command or exit 127;
    }
    sub code { my $raw = shift; return ($raw & 127) ? 128 + ($raw & 127) : ($raw >> 8) & 255 }
    my $until = time() + $limit;
    while (time() < $until) {
      my $done = waitpid($child, WNOHANG);
      exit code($?) if $done == $child;
      sleep 0.05;
    }
    print STDERR "release gate: TIMEOUT: $name exceeded ${limit}s\n";
    for my $signal (qw(INT TERM KILL)) {
      kill $signal, -$child;
      my $signal_until = time() + ($signal eq "KILL" ? 0.5 : $grace);
      while (time() < $signal_until) {
        my $done = waitpid($child, WNOHANG);
        exit 124 if $done == $child;
        sleep 0.05;
      }
    }
    exit 124;
  ' "$seconds" "$GATE_SIGNAL_GRACE_S" "$name" "$@"
}

run_step() {
  local name=$1 rc limit=$GATE_STEP_TIMEOUT_S
  shift
  printf '\n==> %s\n' "$name"
  case "$name" in *suite | "corpus replay" | determinism) limit=$GATE_SUITE_TIMEOUT_S ;; esac
  if [ "${1:-}" = run_tool ]; then
    shift
    if command -v "$1" >/dev/null 2>&1; then
      run_bounded "$limit" "$name" "$@"
    else
      missing_tool "$1"
    fi
  else
    run_bounded "$limit" "$name" "$@"
  fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "<== PASS: $name (exit $rc)"
    record "$name" PASS "$rc"
  else
    echo "<== FAIL: $name (exit $rc)"
    record "$name" FAIL "$rc"
    FAILED=1
  fi
}

missing_tool() {
  echo "release gate: required tool '$1' is missing from PATH" >&2
  return 127
}

if [ "${1:-}" = --timeout-self-test ]; then
  GATE_STEP_TIMEOUT_S=1
  GATE_SIGNAL_GRACE_S=0.1
  run_step "deliberate hanging step" perl -e 'if ($ENV{GATE_TIMEOUT_PID_FILE}) { open my $f, ">", $ENV{GATE_TIMEOUT_PID_FILE} or exit 125; print $f "$$\n"; close $f } $SIG{INT}=$SIG{TERM}="IGNORE"; sleep 30'
else
  run_step "contract suite" bash tests/contract.sh
  run_step "security suite" bash tests/security.sh
  run_step "run suite" bash tests/run.sh
  run_step "lifecycle suite" bash tests/lifecycle.sh
  run_step "corpus replay" python3 tests/corpus/replay.py
  run_step "determinism" bash tests/determinism.sh

  if command -v claude >/dev/null 2>&1; then
    run_step "Claude marketplace validation" claude plugin validate . --strict
    run_step "Claude plugin validation" claude plugin validate ./.claude-plugin/plugin.json --strict
  else
    printf '\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    echo "!! SKIPPED CLAUDE VALIDATION: 'claude' CLI is absent from PATH !!"
    echo "!! BOTH strict plugin validations were NOT run.                  !!"
    printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    record "Claude marketplace validation" SKIP "SKIP (claude missing)"
    record "Claude plugin validation" SKIP "SKIP (claude missing)"
  fi

  run_step "ruff check" run_tool ruff check .
  run_step "ruff format" run_tool ruff format --check .
  run_step "ruff security" run_tool ruff check --select S .
  run_step "mypy strict" run_tool mypy --strict hooks/*.py scripts/*.py tests/*.py tests/corpus/*.py
  run_step "Python dead code" run_tool vulture hooks scripts tests --min-confidence 80
  run_step "POSIX preflight shellcheck" run_tool shellcheck --shell=sh --severity=warning hooks/preflight.sh
  run_step "Bash shellcheck" run_tool shellcheck --severity=error bin/codex-delegate scripts/*.sh tests/*.sh
  run_step "shell format" run_tool shfmt -d -i 2 -ci bin/codex-delegate hooks/preflight.sh scripts tests
  run_step "shell syntax" bash -n hooks/preflight.sh bin/codex-delegate scripts/*.sh tests/*.sh
  run_step "Markdown lint" run_tool markdownlint '**/*.md'
  run_step "document format" run_tool prettier --check '**/*.{md,json,yml,yaml}'
  run_step "GitHub workflow lint" run_tool actionlint
  run_step "secret scan" run_tool gitleaks detect --source . --no-banner --redact
  run_step "privacy scan" python3 scripts/privacy-scan.py
  run_step "embedded Python" python3 scripts/embedded-python-check.py
  run_step "frontmatter lint" python3 scripts/lint-frontmatter.py
  run_step "documentation claim check" python3 scripts/claim-check.py
fi

printf '\n================ RELEASE GATE SUMMARY ================\n'
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  printf '%-38s %-5s exit=%s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${CODES[$i]}"
  i=$((i + 1))
done
if [ "$FAILED" -ne 0 ]; then
  echo "RELEASE GATE: FAIL"
  exit 1
fi
echo "RELEASE GATE: PASS"
