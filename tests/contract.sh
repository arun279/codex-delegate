#!/bin/bash
# Deterministic contract checks for the runner, routing docs, hooks, and release wiring.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${CODEX_DELEGATE_TEST_BIN:-$ROOT/bin/codex-delegate}
WORKFLOW_LINT=$ROOT/hooks/guard-workflow.py
SKILL=$ROOT/skills/routing/SKILL.md
RUNNER=$ROOT/agents/runner.md
STATUS_REF=$ROOT/skills/routing/reference/status-and-trust.md
README=$ROOT/README.md
SECURITY=$ROOT/SECURITY.md
UNINSTALL=$ROOT/commands/uninstall.md
HOOKS=$ROOT/hooks/hooks.json
PREFLIGHT=$ROOT/hooks/preflight.sh
GATE=$ROOT/scripts/gate.sh
GATE_RED_MANIFEST=$ROOT/tests/red-fixtures/gate-steps.tsv
GATE_RED_EXEMPTIONS=$ROOT/tests/red-fixtures/gate-exemptions.tsv
STUB=$ROOT/tests/stub/codex
PLUGIN_LIFECYCLE=$ROOT/tests/plugin-lifecycle.sh
SMART_HTTP=$ROOT/tests/plugin-lifecycle-smarthttp.py
CI=$ROOT/.github/workflows/ci.yml
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" contract || exit 2
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
test_temp_install_traps

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

workflow_inline_() {
  WORKFLOW_OUT=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Workflow","tool_input":{"script":sys.argv[1]}}))' "$1" |
    python3 "$WORKFLOW_LINT")
  WORKFLOW_RC=$?
}
workflow_denies_() {
  [ "$WORKFLOW_RC" = 0 ] && printf '%s\n' "$WORKFLOW_OUT" | grep -q '"permissionDecision": "deny"'
}
workflow_allows_() { [ "$WORKFLOW_RC" = 0 ] && [ -z "$WORKFLOW_OUT" ]; }
entrypoint_surface_mutation_check() {
  local scratch=$WORK/codex-delegate-audit
  sed '/^def main() -> int:$/a\
    if sys.argv[1] == "audit":\
        return 0' "$BIN" >"$scratch" || return
  python3 "$ROOT/tests/entrypoints_check.py" "$BIN" >/dev/null &&
    ! python3 "$ROOT/tests/entrypoints_check.py" "$scratch" >/dev/null 2>&1
}

extract_shell_function_() {
  sed -n "/^$2() {\$/,/^}\$/p" "$1"
}

shell_function_probe_() {
  local source=$1 function=$2 probe=$3
  {
    printf '%s\n' '#!/bin/bash' 'set -uo pipefail'
    extract_shell_function_ "$source" "$function"
    printf '%s\n' "$function"
  } >"$probe"
}

suite_counted_fail_() {
  local suite=$1 name probe output rc
  name=${suite##*/}
  probe=$WORK/red-suite-${name%.sh}.sh
  output=$WORK/red-suite-${name%.sh}.out
  {
    printf '%s\n' '#!/bin/bash' 'set -uo pipefail' 'PASS=0' 'FAIL=0'
    extract_shell_function_ "$ROOT/$suite" bad
    printf '%s\n' ': >"$1"' 'bad "known-bad fixture" "$1"' 'exit $((FAIL > 0))'
  } >"$probe" || return
  bash "$probe" "$WORK/red-suite-empty" >"$output" 2>&1
  rc=$?
  [ "$rc" -eq 1 ] && grep -Fq 'FAIL known-bad fixture' "$output" &&
    grep -Fxq 'exit $((FAIL > 0))' "$ROOT/$suite"
}

demo_matches_command_() {
  local demo=$1 command=$2
  case "$demo" in
    suite:*) [ "$command" = "bash ${demo#suite:}" ] ;;
    npm-pack) [ "$command" = "bash tests/npm-pack-check.sh" ] ||
      [ "$command" = "python3 scripts/npm-pack-check.py" ] ;;
    corpus) [ "$command" = "python3 tests/corpus/replay.py" ] ;;
    determinism) [ "$command" = "bash tests/determinism.sh" ] ;;
    timeout) [[ "$command" = "perl -e "* ]] ;;
    repository-push) [ "$command" = "bash -c repository_push_invariants" ] ;;
    privacy) [ "$command" = "python3 scripts/privacy-scan.py --tracked-only" ] ;;
    manifests) [ "$command" = "python3 scripts/release-invariants.py manifests" ] ;;
    versions) [ "$command" = "python3 scripts/release-invariants.py versions" ] ;;
    changelog) [ "$command" = "python3 scripts/release-invariants.py changelog" ] ;;
    publication-copy) [ "$command" = "python3 scripts/release-invariants.py publication-copy" ] ;;
    release-versions) [ "$command" = "bash -c release_version_invariants" ] ;;
    frontmatter) [ "$command" = "python3 scripts/lint-frontmatter.py" ] ;;
    claim-check) [ "$command" = "python3 scripts/claim-check.py" ] ;;
    runner-protocol) [ "$command" = "python3 scripts/runner-protocol-check.py" ] ;;
    *) return 1 ;;
  esac
}

gate_step_spelling_() {
  awk '
    /(^|[^[:alnum:]_])run_step([^[:alnum:]_]|$)/ {
      if ($0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /^[[:space:]]*run_step[(][)][[:space:]]*[{][[:space:]]*$/) next
      command=$0
      if ($0 ~ /^[[:space:]]*run_step "[^"$\\]+"[[:space:]]+[^[:space:]]/) {
        sub(/^[[:space:]]*run_step "[^"$\\]+"[[:space:]]+/, "", command)
        if (command !~ /(^|[^[:alnum:]_])run_step([^[:alnum:]_]|$)/) next
      }
      printf "falsifiability: noncanonical run_step spelling: line %d: %s\n", FNR, $0 > "/dev/stderr"
      invalid=1
    }
    END { exit invalid }
  ' "$1"
}

gate_inventory_() {
  local gate=$1 demos=${2:-$GATE_RED_MANIFEST}
  local step demo prefix reason command missing stale duplicate invalid=0
  gate_step_spelling_ "$gate" || return 1
  sed -n 's/^[[:space:]]*run_step "\([^"]*\)"[[:space:]]\{1,\}\(.*\)$/\1\	\2/p' "$gate" |
    sort >"$WORK/gate-steps.commands"
  cut -f1 "$WORK/gate-steps.commands" >"$WORK/gate-steps.actual"
  awk -F '\t' '
    NF != 2 || !$1 || !$2 { invalid=1 }
    { print $1 }
    END { exit invalid }
  ' "$demos" | sort >"$WORK/gate-steps.demonstrated" || {
    echo "falsifiability: invalid gate-step demonstration manifest" >&2
    return 1
  }
  awk -F '\t' '
    NF != 3 || !$1 || !$2 || $3 !~ /^falsifiable upstream: / { invalid=1 }
    { print $1 }
    END { exit invalid }
  ' "$GATE_RED_EXEMPTIONS" | sort >"$WORK/gate-steps.exempt" || {
    echo "falsifiability: invalid gate-step exemption list" >&2
    return 1
  }
  while IFS=$'\t' read -r step demo; do
    command=$(awk -F '\t' -v wanted="$step" '$1 == wanted { print $2 }' "$WORK/gate-steps.commands")
    if ! demo_matches_command_ "$demo" "$command"; then
      echo "falsifiability: demonstration does not match command: $step ($demo -> $command)" >&2
      invalid=1
    fi
  done <"$demos"
  while IFS=$'\t' read -r step prefix reason; do
    case "$prefix" in
      "claude plugin validate" | "run_tool ruff" | "run_tool mypy" | \
        "run_tool vulture" | "run_tool shellcheck" | "run_tool shfmt" | \
        "run_tool markdownlint" | "run_tool prettier" | "run_tool actionlint" | \
        "run_tool gitleaks" | "bash -n") ;;
      *)
        echo "falsifiability: exemption is not an upstream tool: $step ($prefix)" >&2
        invalid=1
        continue
        ;;
    esac
    command=$(awk -F '\t' -v wanted="$step" '$1 == wanted { print $2 }' "$WORK/gate-steps.commands")
    if [[ "$command" != "$prefix" && "$command" != "$prefix "* ]]; then
      echo "falsifiability: exempt command changed: $step ($command)" >&2
      invalid=1
    fi
  done <"$GATE_RED_EXEMPTIONS"
  cat "$WORK/gate-steps.demonstrated" "$WORK/gate-steps.exempt" |
    sort >"$WORK/gate-steps.covered"
  duplicate=$(uniq -d "$WORK/gate-steps.covered")
  missing=$(comm -23 "$WORK/gate-steps.actual" "$WORK/gate-steps.covered")
  stale=$(comm -13 "$WORK/gate-steps.actual" "$WORK/gate-steps.covered")
  if [ "$invalid" -ne 0 ] || [ -n "$duplicate" ] || [ -n "$missing" ] || [ -n "$stale" ]; then
    while IFS= read -r step; do
      [ -z "$step" ] || echo "falsifiability: duplicate classification: $step" >&2
    done <<<"$duplicate"
    while IFS= read -r step; do
      [ -z "$step" ] || echo "falsifiability: no red demonstration or exemption: $step" >&2
    done <<<"$missing"
    while IFS= read -r step; do
      [ -z "$step" ] || echo "falsifiability: stale classification: $step" >&2
    done <<<"$stale"
    return 1
  fi
}

gate_inventory_mutation_check_() {
  local unlisted=$WORK/gate-unlisted.sh noncanonical=$WORK/gate-noncanonical.sh
  local command_changed=$WORK/gate-command-changed.sh spelling
  local invalid_demos=$WORK/gate-invalid-demos.tsv remapped=$WORK/gate-remapped.tsv
  local output=$WORK/gate-inventory-mutants.out
  cp "$GATE" "$unlisted" || return
  printf '\nrun_step "unlisted fixture" true\n' >>"$unlisted"
  gate_inventory_ "$unlisted" >"$output" 2>&1
  [ "$?" -eq 1 ] &&
    grep -Fxq 'falsifiability: no red demonstration or exemption: unlisted fixture' "$output" || return
  while IFS= read -r spelling; do
    cp "$GATE" "$noncanonical" || return
    printf '%s\n' "$spelling" >>"$noncanonical"
    gate_inventory_ "$noncanonical" >"$output" 2>&1
    [ "$?" -eq 1 ] &&
      grep -Fq 'falsifiability: noncanonical run_step spelling:' "$output" &&
      grep -Fq "$spelling" "$output" || return
  done <<'SPELLINGS'
run_step 'sneaky step' true
true; run_step "sneaky step" true
SNEAKY=sneaky; run_step "$SNEAKY" true
SPELLINGS
  sed 's|run_step "ruff check" run_tool ruff check .*|run_step "ruff check" bash tests/checks.sh|' \
    "$GATE" >"$command_changed" || return
  gate_inventory_ "$command_changed" >"$output" 2>&1
  [ "$?" -eq 1 ] &&
    grep -Fq 'falsifiability: exempt command changed: ruff check (bash tests/checks.sh)' "$output" || return
  cp "$GATE_RED_MANIFEST" "$invalid_demos" || return
  printf '%s\n' 'malformed fixture' >>"$invalid_demos"
  gate_inventory_ "$GATE" "$invalid_demos" >"$output" 2>&1
  [ "$?" -eq 1 ] &&
    grep -Fxq 'falsifiability: invalid gate-step demonstration manifest' "$output" || return
  awk -F '\t' 'BEGIN { OFS=FS } $1 == "privacy scan" { $2="npm-pack" } { print }' \
    "$GATE_RED_MANIFEST" >"$remapped" || return
  gate_inventory_ "$GATE" "$remapped" >"$output" 2>&1
  [ "$?" -eq 1 ] &&
    grep -Fxq 'falsifiability: demonstration does not match command: privacy scan (npm-pack -> python3 scripts/privacy-scan.py --tracked-only)' "$output"
}

npm_pack_red_() {
  local output=$WORK/red-npm-pack.out
  bash "$ROOT/tests/npm-pack-check.sh" >"$output" 2>&1 &&
    grep -Fxq 'npm pack guard fixture: PASS (changed packed set rejected)' "$output"
}

corpus_red_() {
  python3 "$ROOT/tests/corpus/replay.py" --guard "$ROOT/tests/red-fixtures/allow-guard.py" \
    >"$WORK/red-corpus.out" 2>&1
  local rc=$?
  [ "$rc" -eq 1 ] && grep -Eq 'corpus replay: [0-9]+/[0-9]+ real commands correct' "$WORK/red-corpus.out"
}

repository_push_red_() {
  local root=$WORK/red-repository-push output=$WORK/red-repository-push.out rc
  mkdir -p "$root/bin" || return
  cat >"$root/bin/git" <<'SH'
#!/bin/sh
case "$1" in
  init | push) exit 0 ;;
  rev-parse) printf '%s\n' local-head ;;
  --git-dir=*) printf '%s\n' remote-head ;;
  *) exit 2 ;;
esac
SH
  chmod 700 "$root/bin/git" || return
  shell_function_probe_ "$GATE" repository_push_invariants "$root/probe.sh" || return
  TMPDIR=$root PATH=$root/bin:/usr/bin:/bin bash "$root/probe.sh" >"$output" 2>&1
  rc=$?
  [ "$rc" -eq 1 ] && grep -Fxq 'release gate: pushed remote-head, expected local-head' "$output"
}

privacy_red_() {
  printf '/%s/%s/project\n' Users red-fixture-owner >"$WORK/private-input"
  python3 "$ROOT/scripts/privacy-scan.py" --path "$WORK/private-input" >"$WORK/red-privacy.out" 2>&1
  local rc=$?
  [ "$rc" -eq 1 ] && grep -Fq 'macos-home-path' "$WORK/red-privacy.out"
}

release_invariant_root_() {
  local root=$1
  mkdir -p "$root/scripts" "$root/.claude-plugin" || return
  cp "$ROOT/scripts/release-invariants.py" "$root/scripts/" || return
  cp "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json" "$root/.claude-plugin/" || return
  cp "$ROOT/package.json" "$root/" || return
}

manifest_red_() {
  local root=$WORK/red-manifests
  release_invariant_root_ "$root" || return
  python3 -c 'import json,sys; p=sys.argv[1]; value=json.load(open(p)); value["description"]=""; json.dump(value,open(p,"w"))' \
    "$root/.claude-plugin/plugin.json"
  (cd "$root" && python3 scripts/release-invariants.py manifests) >"$WORK/red-manifests.out" 2>&1
  [ "$?" -eq 1 ] && grep -Fq 'description omits' "$WORK/red-manifests.out"
}

versions_red_() {
  local root=$WORK/red-versions
  release_invariant_root_ "$root" || return
  python3 -c 'import json,sys; p=sys.argv[1]; value=json.load(open(p)); value["version"]="9.9.9"; json.dump(value,open(p,"w"))' \
    "$root/package.json"
  (cd "$root" && python3 scripts/release-invariants.py versions) >"$WORK/red-versions.out" 2>&1
  [ "$?" -eq 1 ] && grep -Fq 'does not match plugin.json version' "$WORK/red-versions.out"
}

changelog_red_() {
  local root=$WORK/red-changelog
  mkdir -p "$root/scripts" || return
  cp "$ROOT/scripts/release-invariants.py" "$root/scripts/" || return
  printf '%s\n' '# Changelog' '## [Unreleased]' 'unstructured fixture' >"$root/CHANGELOG.md"
  (cd "$root" && python3 scripts/release-invariants.py changelog) >"$WORK/red-changelog.out" 2>&1
  [ "$?" -eq 1 ] && grep -Fq 'has unstructured release-note content' "$WORK/red-changelog.out"
}

publication_red_() {
  local root=$WORK/red-publication git_dir
  mkdir -p "$root" || return
  while IFS= read -r -d '' relative; do
    mkdir -p "$root/$(dirname "$relative")" || return
    cp "$ROOT/$relative" "$root/$relative" || return
  done < <(git -C "$ROOT" ls-files -z)
  printf 'known-bad publication copy \342\200\224 dash\n' >>"$root/PRIVACY.md" || return
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir) || return
  (cd "$root" && GIT_DIR=$git_dir GIT_WORK_TREE=$root \
    python3 scripts/release-invariants.py publication-copy) >"$WORK/red-publication.out" 2>&1
  [ "$?" -eq 1 ] &&
    grep -Eq '^FAIL PRIVACY.md:[0-9]+ contains typographic dash U\+2014$' "$WORK/red-publication.out" &&
    ! grep -Fq 'cannot be read as UTF-8' "$WORK/red-publication.out"
}

determinism_red_() {
  local root=$WORK/red-determinism output=$WORK/red-determinism.out rc
  python3 - "$root" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for number in (1, 2):
    runid = f"determinism-{number:02d}"
    run = root / "runs" / runid
    run.mkdir(parents=True)
    (run / "final.txt").write_text("STUB FINAL MESSAGE\n", encoding="utf-8")
    (run / "events.jsonl").write_text("", encoding="utf-8")
    (run / "stderr.log").write_text("", encoding="utf-8")
    (root / f"exit-{number}").write_text("0\n", encoding="utf-8")
    (root / f"output-{number}").write_text('STUB FINAL MESSAGE\n{"verdict": "COMPLETED"}\n', encoding="utf-8")
    status = {
        "schema_version": 1,
        "runid": runid,
        "verdict": "COMPLETED",
        "exit_code": 0,
        "diagnostic": None,
        "signal": None,
        "model": "stub-model-a",
        "effort": "high" if number == 2 else "medium",
        "sandbox": "read-only",
        "deadline_s": 60,
        "duration_s": 0,
        "process_exit_code": 0,
        "terminal_event": "turn.completed",
        "usage": {
            "input_tokens": 101,
            "cached_input_tokens": 80,
            "cache_write_input_tokens": 7,
            "output_tokens": 23,
            "reasoning_output_tokens": 5,
        },
        "final_message_path": str(run / "final.txt"),
        "events_path": str(run / "events.jsonl"),
        "stderr_path": str(run / "stderr.log"),
    }
    (root / f"status-{number}.json").write_text(json.dumps(status), encoding="utf-8")
PY
  python3 "$ROOT/tests/determinism_check.py" "$root" 2 >"$output" 2>&1
  rc=$?
  [ "$rc" -eq 1 ] &&
    grep -Fxq "FAIL run 2 effort is 'high', expected 'medium'" "$output" &&
    grep -Fxq 'FAIL run 2 changed a non-variable status field' "$output"
}

timeout_red_() {
  local output=$WORK/red-timeout.out rc
  GATE_TIMEOUT_PID_FILE=$WORK/red-timeout.pid bash "$GATE" --timeout-self-test >"$output" 2>&1
  rc=$?
  [ "$rc" -eq 1 ] &&
    grep -Fxq 'release gate: TIMEOUT: deliberate hanging step exceeded 1s' "$output" &&
    grep -Fxq '<== FAIL: deliberate hanging step (exit 124)' "$output" &&
    grep -Eq '^deliberate hanging step +FAIL +exit=124$' "$output" &&
    grep -Fxq 'RELEASE GATE: FAIL' "$output"
}

release_version_red_() {
  local probe=$WORK/red-release-version.sh output=$WORK/red-release-version.out
  shell_function_probe_ "$GATE" release_version_invariants "$probe" || return
  (cd "$ROOT" && TMPDIR=$WORK bash "$probe") >"$output" 2>&1 &&
    grep -Fq "tag 'definitely-not-a-release-tag' does not match plugin.json version" "$output"
}

frontmatter_red_() {
  local root=$WORK/red-frontmatter
  mkdir -p "$root/scripts" "$root/agents" || return
  cp "$ROOT/scripts/lint-frontmatter.py" "$root/scripts/" || return
  printf '%s\n' --- 'name: probe' 'description: red fixture' 'model: claude-not-real' --- >"$root/agents/probe.md"
  (cd "$root" && python3 scripts/lint-frontmatter.py) >"$WORK/red-frontmatter.out" 2>&1
  [ "$?" -eq 1 ] && grep -Fq 'is not a documented model alias' "$WORK/red-frontmatter.out"
}

claim_red_() {
  local root=$WORK/red-claim
  mkdir -p "$root/scripts" || return
  cp -R "$ROOT/agents" "$ROOT/bin" "$ROOT/commands" "$ROOT/hooks" "$ROOT/skills" \
    "$ROOT/.claude-plugin" "$root/" || return
  cp "$ROOT/README.md" "$ROOT/SECURITY.md" "$ROOT/PRIVACY.md" "$ROOT/package.json" "$root/" || return
  cp "$ROOT/scripts/claim-check.py" "$root/scripts/" || return
  grep -Fq 'commands.add_parser("models"' "$root/bin/codex-delegate" || return
  sed '/commands.add_parser("models"/d' "$root/bin/codex-delegate" >"$root/bin/codex-delegate.mutant" || return
  mv "$root/bin/codex-delegate.mutant" "$root/bin/codex-delegate" || return
  (cd "$root" && python3 scripts/claim-check.py) >"$WORK/red-claim.out" 2>&1
  [ "$?" -eq 1 ] && grep -Fq 'expected run and models' "$WORK/red-claim.out"
}

runner_protocol_red_() {
  local root=$WORK/red-runner-protocol
  mkdir -p "$root/scripts" "$root/agents" "$root/hooks" "$root/tests" || return
  cp "$ROOT/scripts/runner-protocol-check.py" "$root/scripts/" || return
  cp "$ROOT/agents/runner.md" "$root/agents/" || return
  cp "$ROOT/hooks/guard-bash.py" "$root/hooks/" || return
  cp -R "$ROOT/tests/stub" "$root/tests/" || return
  grep -Fq 'codex-delegate runner-report "<OUTPUT_FILE>"' "$root/agents/runner.md" || return
  sed 's/codex-delegate runner-report "<OUTPUT_FILE>"/true/' \
    "$root/agents/runner.md" >"$root/agents/runner.md.mutant" || return
  mv "$root/agents/runner.md.mutant" "$root/agents/runner.md" || return
  (cd "$root" && CODEX_DELEGATE_TEST_BIN="$ROOT/bin/codex-delegate" \
    python3 scripts/runner-protocol-check.py) >"$WORK/red-runner-protocol.out" 2>&1
  [ "$?" -eq 1 ] && grep -Fq 'runner report is not the one-line runner-report command' "$WORK/red-runner-protocol.out"
}

red_demo_() {
  case "$1" in
    suite:*) suite_counted_fail_ "${1#suite:}" ;;
    npm-pack) npm_pack_red_ ;;
    corpus) corpus_red_ ;;
    determinism) determinism_red_ ;;
    timeout) timeout_red_ ;;
    repository-push) repository_push_red_ ;;
    privacy) privacy_red_ ;;
    manifests) manifest_red_ ;;
    versions) versions_red_ ;;
    changelog) changelog_red_ ;;
    publication-copy) publication_red_ ;;
    release-versions) release_version_red_ ;;
    frontmatter) frontmatter_red_ ;;
    claim-check) claim_red_ ;;
    runner-protocol) runner_protocol_red_ ;;
    *)
      echo "falsifiability: unknown red demonstration: $1" >&2
      return 1
      ;;
  esac
}

red_demonstrations_() {
  local demo output rc failed=0
  while IFS= read -r demo; do
    output=$WORK/red-demo-${demo//\//_}.out
    red_demo_ "$demo" >"$output" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "falsifiability: red demonstration failed: $demo" >&2
      sed 's/^/  | /' "$output" >&2
      failed=1
    fi
  done < <(cut -f2 "$GATE_RED_MANIFEST" | sort -u)
  [ "$failed" -eq 0 ]
}

smart_http_bind_probe_() {
  SMART_HTTP_BIND_FAILURE=$1 python3 "$ROOT/tests/smart_http_bind_probe.py" "$SMART_HTTP" "$WORK/bind.port"
}

tunable_classification_check() {
  python3 "$ROOT/tests/tunable_classification_check.py" "$1"
}
printf '\n== Workflow call boundary\n'
workflow_inline_ "agent({agentType:'codex-delegate:runner',label:'codex:test',prompt:'work'})"
check 'workflow_denies_ && printf "%s" "$WORKFLOW_OUT" | grep -Fq "agent(prompt: string, opts?:"' \
  "object-form agent call is denied with the real signature"
workflow_inline_ "agent(['===ARGS===','--sandbox workspace-write --cwd /abs/path --deadline 7200','===PROMPT===','work'].join('\\n'),{agentType:'codex-delegate:runner',label:'codex:test',phase:'Test'})"
check 'workflow_allows_' "prompt-first runner call is allowed"
workflow_inline_ "agent('',{agentType:'codex-delegate:runner',label:'codex:test'})"
check 'workflow_denies_' "empty runner prompt is denied"
workflow_inline_ "agent(undefined,{agentType:'codex-delegate:runner',label:'codex:test'})"
check 'workflow_denies_' "missing runner prompt is denied"
workflow_inline_ "agent('not an envelope',{agentType:'codex-delegate:runner',label:'codex:test'})"
check 'workflow_allows_' "dynamic envelope semantics are not claimed as hook enforcement"
workflow_inline_ "agent('work',{agentType:'codex-delegate:runner',label:'codex:test',model:'sonnet',effort:'high'})"
check 'workflow_denies_' "call-site wrapper model and effort are denied"
workflow_inline_ "agent('',{agentType:'another:runner',label:'other:test'})"
check 'workflow_allows_' "another agent type remains outside this policy"

printf '\n== smart-HTTP bind classification\n'
SMART_HTTP_OUT=$(smart_http_bind_probe_ sandbox 2>&1)
SMART_HTTP_RC=$?
check '[ "$SMART_HTTP_RC" -eq 77 ] &&
       printf "%s\n" "$SMART_HTTP_OUT" | grep -Fq "SKIP: sandbox denies loopback bind"' \
  "sandbox-denied loopback bind is SKIP"
SMART_HTTP_OUT=$(smart_http_bind_probe_ occupied 2>&1)
SMART_HTTP_RC=$?
check '[ "$SMART_HTTP_RC" -ne 0 ] && [ "$SMART_HTTP_RC" -ne 77 ] &&
       ! printf "%s\n" "$SMART_HTTP_OUT" | grep -Fq "SKIP:"' \
  "non-sandbox loopback bind error is FAIL"

printf '\n== documented runner contract\n'
awk '
  /^```js[[:space:]]*$/ { inside=1; next }
  inside && /^```[[:space:]]*$/ { inside=0; print ""; next }
  inside { print }
' "$SKILL" >"$WORK/js-blocks.txt"
check '[ -s "$WORK/js-blocks.txt" ] && grep -q "await agent(" "$WORK/js-blocks.txt"' \
  "routing skill includes executable Workflow syntax"
check 'perl -0ne '"'"'exit 1 if /agent\s*\(\s*\{/s'"'"' "$WORK/js-blocks.txt"' \
  "no JavaScript example puts an object in the prompt slot"
check 'grep -q "===ARGS===" "$RUNNER" && grep -q "===PROMPT===" "$RUNNER" &&
       grep -q "non-empty" "$RUNNER" && grep -q "1 through 12,960" "$RUNNER" &&
       grep -q -- "no .--runid." "$RUNNER"' \
  "runner validates its complete envelope before Bash"
check '[ "$(grep -c "^codex-delegate run " "$RUNNER")" = 1 ] &&
       [ "$(grep -c "^codex-delegate runner-wait" "$RUNNER")" = 1 ] &&
       [ "$(grep -c "^codex-delegate runner-report" "$RUNNER")" = 1 ] &&
       ! grep -q "codex-delegate start\|codex-delegate wait\|codex-delegate status\|codex-delegate reap" "$RUNNER"' \
  "runner has exactly one launcher operation"
check 'entrypoint_surface_mutation_check' \
  "launcher exposes only the four entry points and rejects a direct audit mutation"
check 'tunable_classification_check "$BIN"' \
  "every numeric constant and CODEX_DELEGATE environment hook is classified"
sed '/^PROGRAM = /a\
UNCLASSIFIED_CONSTANT: int = 7' "$BIN" >"$WORK/unclassified-launcher"
check '! tunable_classification_check "$WORK/unclassified-launcher" >/dev/null 2>&1' \
  "the tunable classification check rejects a planted constant"
check 'grep -Fq '\''"slug":"stub-model-a"'\'' "$STUB" &&
       grep -Fq '\''"slug":"stub-model-b"'\'' "$STUB" &&
       grep -Fq '\''"slug":"stub-model-c"'\'' "$STUB" &&
       legacy_models_absent=true
       for slug in "gpt-5.6-"sol "gpt-5.6-"terra "codex-auto-"review; do
         grep -RFq --exclude=real-commands.json "$slug" "$ROOT/tests" && legacy_models_absent=false
       done
       $legacy_models_absent' \
  "offline tests use only obviously synthetic model catalog slugs"
check 'grep -q "Environment variables do not override" "$SKILL" &&
       ! grep -q "CODEX_DELEGATE_MODEL\|CODEX_DELEGATE_EFFORT\|bundled" "$SKILL"' \
  "skill documents only live-catalog selection"

printf '\n== reduced surface documentation\n'
DOCS="$README $SKILL $STATUS_REF $SECURITY $UNINSTALL"
check '! grep -Eq -- "--mode([^l]|$)|--base([^[:alnum:]-]|$)|--commit([^[:alnum:]-]|$)|--uncommitted([^[:alnum:]-]|$)|--lane([^[:alnum:]-]|$)" $DOCS' \
  "retired flags are absent from user documentation"
check '! grep -Eq "codex-delegate (start|wait|status|reap)" $DOCS' \
  "retired subcommands are absent from user documentation"
check '! grep -Eq "metadata_tampered|observed_pid_birth_ledger|survivors|terminal\.json|sentinel|catalog_degraded" $DOCS' \
  "retired status and attribution fields are absent"
check 'grep -q "exactly 17 fields" "$README" && grep -q "exactly 17 fields" "$STATUS_REF" &&
       grep -q "all 17 fields" "$SKILL"' \
  "README, status reference, and routing skill agree on schema size"
check 'GIT_DOCS_OK=1
       for doc in "$README" "$SECURITY" "$SKILL" "$STATUS_REF"; do
         grep -q -- "--add-dir" "$doc" && grep -q "Git metadata" "$doc" &&
           grep -q "opt in" "$doc" || GIT_DOCS_OK=0
       done
       [ "$GIT_DOCS_OK" = 1 ] &&
       GIT_COMMON_OK=1
       for doc in "$README" "$SECURITY" "$SKILL" "$STATUS_REF"; do
         grep -Fq "git rev-parse --path-format=absolute --git-common-dir" "$doc" ||
           GIT_COMMON_OK=0
       done
       [ "$GIT_COMMON_OK" = 1 ] &&
       grep -q "linked worktree" "$README" && grep -q "linked worktree" "$SKILL" &&
       grep -q "do not compose" "$README" && grep -q "do not compose" "$SKILL" &&
       ! grep -Fq "cannot stage or commit" "$README" &&
       ! grep -Fq "does not include Git metadata" "$SECURITY" &&
       ! grep -Fq "cannot stage, commit, branch, or stash" "$SKILL"' \
  "workspace-write names Git's common directory for the narrow opt-in"
check 'grep -Fq "Initial \`--prompt-file\` path validation exits 2." "$README" &&
       grep -Fq "Empty prompt input, stdin read failures, prompt storage failures, and Codex launch errors are \`LAUNCH_ERROR\` (12)." "$README"' \
  "README predicts every prompt-source failure class"
check 'grep -q "resolves once" "$README" && grep -q "resolves once" "$SKILL"' \
  "both entry points still tell a Workflow author the call resolves once"
check 'grep -q "different process group or session" "$README" &&
       grep -q "creates another process" "$SECURITY" && grep -q "group or session" "$SECURITY"' \
  "process-group cleanup limit is stated plainly"
check 'grep -q "danger-full-access" "$STATUS_REF" && grep -q "tamper-proof attestation" "$STATUS_REF"' \
  "status reference states the same-user trust boundary"
check 'grep -q "background lifecycle command" "$UNINSTALL" &&
       ! grep -q "reap\|supervisor.pid\|survivors.txt" "$UNINSTALL"' \
  "uninstall stays cleanup only, with no job lifecycle surface of its own"

printf '\n== hooks and release wiring\n'
check 'python3 -c '"'"'import json,sys; json.load(open(sys.argv[1]))'"'"' "$HOOKS" &&
       ! grep -q "SessionEnd\|session-end" "$HOOKS" && [ ! -e "$ROOT/hooks/session-end.py" ]' \
  "hook manifest installs no background end-of-session process"
check 'python3 -c '"'"'
import json, sys
manifest = json.load(open(sys.argv[1]))
entry = manifest["hooks"]["SubagentStop"]
raise SystemExit(entry != [{"hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/subagent-stop.py", "args": [], "timeout": 180}]}])
'"'"' "$HOOKS"' \
  "SubagentStop runs the isolated runner guard with its explicit 180-second timeout"
check 'python3 -c '"'"'
import json, os, sys
root, manifest_path = sys.argv[1:]
manifest = json.load(open(manifest_path))
commands = (
    hook["command"]
    for entries in manifest["hooks"].values()
    for entry in entries
    for hook in entry["hooks"]
    if hook["type"] == "command"
)
paths = [command.replace("${CLAUDE_PLUGIN_ROOT}", root) for command in commands]
raise SystemExit(not paths or any(not os.path.isfile(path) or not os.access(path, os.X_OK) for path in paths))
'"'"' "$ROOT" "$HOOKS"' \
  "every hook command resolves to a shipped executable file"
check '! grep -q "command -v perl\|computer-use\|session-end" "$PREFLIGHT"' \
  "preflight checks only current runtime dependencies"
check 'grep -Fq "/usr/bin/env -S python3 -I -S -c" "$PREFLIGHT" &&
       grep -Fq "sys.flags.isolated and sys.flags.no_site" "$PREFLIGHT"' \
  "preflight retains the launcher exact isolated-startup probe"
check 'hooks_isolated=true
       for hook_path in "$ROOT"/hooks/*.py; do
         [ "$(sed -n "1p" "$hook_path")" = "#!/usr/bin/env -S python3 -I -S" ] || hooks_isolated=false
         # Asserting the line is not asserting the interpreter starts. An earlier check in this repository
         # read a string and never ran the thing, so this executes each hook through its own shebang
         # and requires it to answer.
         printf %s "{}" | "$hook_path" >/dev/null 2>&1 || hooks_isolated=false
       done
       $hooks_isolated' \
  "every Python hook starts, through its own shebang, under the launcher's isolated interpreter"
check 'grep -Fq '"'"'CLAUDE_CONFIG_DIR=$WORK/home/.claude'"'"' "$PLUGIN_LIFECYCLE" &&
       grep -Fq '"'"'find "$CLAUDE_CONFIG_DIR/plugins/cache"'"'"' "$PLUGIN_LIFECYCLE" &&
       grep -Fq '"'"'MARKET_CLONE=$CLAUDE_CONFIG_DIR/plugins/marketplaces/$MARKET'"'"' "$PLUGIN_LIFECYCLE"' \
  "plugin lifecycle isolates every Claude config and cache path"
check '! grep -Fq "already at the latest version" "$PLUGIN_LIFECYCLE" &&
       ! grep -Fq "updated from 1.0.0 to 1.0.1" "$PLUGIN_LIFECYCLE"' \
  "plugin lifecycle asserts cache state instead of Claude prose"
check 'grep -Fq '\''bash "$ROOT/tests/checks.sh"'\'' "$ROOT/tests/security.sh"' \
  "security suite retains the focused checks invocation"
check 'grep -q "run_step .*contract suite.*tests/contract.sh" "$GATE" &&
       grep -q "run_step .*npm pack guard suite.*tests/npm-pack-check.sh" "$GATE" &&
       grep -q "run_step .*security suite.*tests/security.sh" "$GATE" &&
       grep -q "run_step .*run suite.*tests/run.sh" "$GATE" &&
       grep -q "run_step .*lifecycle suite.*tests/lifecycle.sh" "$GATE" &&
       grep -q "run_step .*runner handoff suite.*tests/runner-handoff.sh" "$GATE" &&
       grep -q "run_step .*release workflow suite.*tests/release-workflow.sh" "$GATE" &&
       grep -q "run_step .*plugin install lifecycle.*tests/plugin-lifecycle.sh" "$GATE" &&
       grep -q "run_step .*corpus replay" "$GATE" && grep -q "run_step .*determinism" "$GATE" &&
       grep -q "run_step .*npm package contents.*scripts/npm-pack-check.py" "$GATE"' \
  "release gate retains every required suite, corpus, and determinism check"
check 'gate_release_steps=true
       for step in "repository push" "changelog evidence" "publication copy"; do
         grep -Fq "run_step \"$step\"" "$GATE" || gate_release_steps=false
       done
       $gate_release_steps' \
  "release gate retains repository push, changelog evidence, and publication copy by name"
check 'gate_analysis=true
       # The gate is the only place these run. Losing one silently removes a whole
       # class of check while every suite stays green.
       for step in "ruff check" "ruff format" "ruff security" "mypy strict" \
         "Python dead code" "POSIX preflight shellcheck" "Bash shellcheck" \
         "shell format" "shell syntax" "Markdown lint" "document format" \
         "GitHub workflow lint" "secret scan" "frontmatter lint" \
         "documentation claim check"; do
         grep -Fq "run_step \"$step\"" "$GATE" || gate_analysis=false
       done
       $gate_analysis' \
  "release gate retains every static-analysis step"
check 'python3 "$ROOT/tests/ci_gate_check.py" "$CI"' \
  "the release-gate job itself runs on a macOS runner"
check 'grep -Eq '"'"'^[[:space:]]*run_step "[^"]+" claude plugin validate \. --strict[[:space:]]*$'"'"' "$GATE" &&
       grep -Eq '"'"'^[[:space:]]*run_step "[^"]+" claude plugin validate \./\.claude-plugin/plugin\.json --strict[[:space:]]*$'"'"' "$GATE" &&
       grep -Fq '"'"'record "plugin install lifecycle" SKIP "SKIP (claude missing)"'"'"' "$GATE" &&
       grep -Eq '"'"'^[[:space:]]*- run: claude plugin validate \. --strict[[:space:]]*$'"'"' "$CI" &&
       grep -Eq '"'"'^[[:space:]]*- run: claude plugin validate \./\.claude-plugin/plugin\.json --strict[[:space:]]*$'"'"' "$CI"' \
  "gate and CI retain marketplace and component strict validation"
check 'grep -Fq '"'"'if [ "$name" = "plugin install lifecycle" ] && [ "$rc" -eq 77 ]'"'"' "$GATE" &&
       grep -Fq '"'"'RELEASE GATE: PASS with $SANDBOX_SKIPPED sandbox-skipped steps'"'"' "$GATE" &&
       grep -Fq '"'"'if [ "$SERVER_RC" -eq 77 ]'"'"' "$PLUGIN_LIFECYCLE"' \
  "gate renders only the lifecycle sandbox signal as a counted SKIP"
check 'grep -Fq '"'"'done < <(git ls-files -z -- '"'"'"'"'"'*.py'"'"'"'"'"' bin/codex-delegate pyproject.toml)'"'"' "$GATE" &&
       grep -Fq '"'"'run_step "ruff check" run_tool ruff check "${TRACKED_RUFF_FILES[@]}"'"'"' "$GATE" &&
       grep -Fq '"'"'run_step "ruff format" run_tool ruff format --check "${TRACKED_RUFF_FILES[@]}"'"'"' "$GATE" &&
       grep -Fq '"'"'run_step "ruff security" run_tool ruff check --select S "${TRACKED_RUFF_FILES[@]}"'"'"' "$GATE"' \
  "ruff scans receive every tracked Ruff target and no untracked files"
check 'grep -Fq '"'"'run_step "privacy scan" python3 scripts/privacy-scan.py --tracked-only'"'"' "$GATE" &&
       grep -Fq '"'"'arguments = ["ls-files", "--cached", "-z"]'"'"' "$ROOT/scripts/privacy-scan.py" &&
       grep -Fq '"'"'historical = historical_targets(ROOT)'"'"' "$ROOT/scripts/privacy-scan.py" &&
       grep -Fq '"'"'references = reference_targets(ROOT)'"'"' "$ROOT/scripts/privacy-scan.py"' \
  "privacy gate scans tracked working-tree files, history, and refs"
check '[ -f "$ROOT/hooks/guard-bash.py" ] && [ -d "$ROOT/tests/corpus" ] &&
       [ -f "$ROOT/scripts/privacy-scan.py" ] && [ -f "$ROOT/scripts/npm-pack-check.py" ] &&
       [ -f "$ROOT/scripts/gate.sh" ]' \
  "guard, corpus, privacy scanner, and release gate remain present"

printf '\n== gate falsifiability\n'
check 'gate_inventory_ "$GATE" && gate_inventory_mutation_check_' \
  "every release gate step has a red demonstration or a command-bound named upstream exemption"
check 'suite_counted_fail_ tests/checks.sh && red_demonstrations_' \
  "every bespoke gate checker and nested shell harness demonstrates a red path"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
