#!/bin/bash
# Deterministic contract checks for the runner, routing docs, hooks, and release wiring.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
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
PLUGIN_LIFECYCLE=$ROOT/tests/plugin-lifecycle.sh
LEFTHOOK=$ROOT/lefthook.yml
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
check 'grep -q "exactly 16 fields" "$README" && grep -q "exactly 16 fields" "$STATUS_REF"' \
  "README and status reference agree on schema size"
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
check '! grep -q "command -v perl\|computer-use\|session-end" "$PREFLIGHT"' \
  "preflight checks only current runtime dependencies"
check 'grep -Fq "/usr/bin/env -S python3 -I -S -c" "$PREFLIGHT" &&
       grep -Fq "sys.flags.isolated and sys.flags.no_site" "$PREFLIGHT"' \
  "preflight retains the launcher exact isolated-startup probe"
check 'hooks_isolated=true
       for hook in guard-bash.py guard-workflow.py permission-allow.py; do
         [ "$(sed -n "1p" "$ROOT/hooks/$hook")" = "#!/usr/bin/env -S python3 -I -S" ] || hooks_isolated=false
         # Asserting the line is not asserting the interpreter starts. An earlier check in this repository
         # read a string and never ran the thing, so this executes each hook through its own shebang
         # and requires it to answer.
         printf %s "{}" | "$ROOT/hooks/$hook" >/dev/null 2>&1 || hooks_isolated=false
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
check 'grep -q "run_step .*contract suite.*tests/contract.sh" "$GATE" &&
       grep -q "run_step .*npm pack guard suite.*tests/npm-pack-check.sh" "$GATE" &&
       grep -q "run_step .*security suite.*tests/security.sh" "$GATE" &&
       grep -q "run_step .*run suite.*tests/run.sh" "$GATE" &&
       grep -q "run_step .*lifecycle suite.*tests/lifecycle.sh" "$GATE" &&
       grep -q "run_step .*release workflow suite.*tests/release-workflow.sh" "$GATE" &&
       grep -q "run_step .*plugin install lifecycle.*tests/plugin-lifecycle.sh" "$GATE" &&
       grep -q "run_step .*corpus replay" "$GATE" && grep -q "run_step .*determinism" "$GATE" &&
       grep -q "run_step .*npm package contents.*scripts/npm-pack-check.py" "$GATE"' \
  "release gate retains every required suite, corpus, and determinism check"
check 'grep -q "run: bash scripts/gate.sh" "$LEFTHOOK"' \
  "lefthook reaches the release gate"
check '! grep -Eq '"'"'^[[:space:]]*glob(_matcher)?:'"'"' "$LEFTHOOK"' \
  "lefthook pre-commit commands do not depend on unverified glob semantics"
check 'grep -q "runs-on: macos-latest" "$CI" && grep -q "run: bash scripts/gate.sh" "$CI"' \
  "macOS CI reaches the release gate"
check 'grep -Eq '"'"'^[[:space:]]*run_step "[^"]+" claude plugin validate \. --strict[[:space:]]*$'"'"' "$GATE" &&
       grep -Eq '"'"'^[[:space:]]*run_step "[^"]+" claude plugin validate \./\.claude-plugin/plugin\.json --strict[[:space:]]*$'"'"' "$GATE" &&
       grep -Fq '"'"'record "plugin install lifecycle" SKIP "SKIP (claude missing)"'"'"' "$GATE" &&
       grep -Eq '"'"'^[[:space:]]*- run: claude plugin validate \. --strict[[:space:]]*$'"'"' "$CI" &&
       grep -Eq '"'"'^[[:space:]]*- run: claude plugin validate \./\.claude-plugin/plugin\.json --strict[[:space:]]*$'"'"' "$CI"' \
  "gate and CI retain marketplace and component strict validation"
check '[ -f "$ROOT/hooks/guard-bash.py" ] && [ -d "$ROOT/tests/corpus" ] &&
       [ -f "$ROOT/scripts/privacy-scan.py" ] && [ -f "$ROOT/scripts/npm-pack-check.py" ] &&
       [ -f "$ROOT/scripts/gate.sh" ]' \
  "guard, corpus, privacy scanner, and release gate remain present"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
