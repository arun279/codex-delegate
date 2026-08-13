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

smart_http_bind_probe_() {
  SMART_HTTP_BIND_FAILURE=$1 python3 - "$SMART_HTTP" "$WORK/bind.port" <<'PY'
import errno
import importlib.util
import os
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("plugin_lifecycle_smarthttp", path)
if spec is None or spec.loader is None:
    raise RuntimeError("could not load smart-HTTP helper")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class ForcedBindFailure:
    def __init__(self, *_args: object, **_kwargs: object) -> None:
        if os.environ["SMART_HTTP_BIND_FAILURE"] == "sandbox":
            raise PermissionError(errno.EPERM, "Operation not permitted")
        raise OSError(errno.EADDRINUSE, "Address already in use")


module.GitHTTPServer = ForcedBindFailure
sys.argv = [path, ".", sys.argv[2]]
raise SystemExit(module.main())
PY
}

tunable_classification_check() {
  python3 - "$1" <<'PY'
import ast
import sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())

def assigned(name):
    for statement in tree.body:
        if isinstance(statement, ast.Assign):
            if any(isinstance(target, ast.Name) and target.id == name for target in statement.targets):
                return statement.value
    raise SystemExit(f"missing classification declaration: {name}")

def dictionary_keys(name):
    value = assigned(name)
    if not isinstance(value, ast.Dict):
        raise SystemExit(f"{name} is not a literal table")
    return {key.value for key in value.keys if isinstance(key, ast.Constant) and isinstance(key.value, str)}

def numeric_expression(node):
    if isinstance(node, ast.Constant):
        return type(node.value) in (int, float)
    if isinstance(node, ast.UnaryOp):
        return isinstance(node.op, (ast.UAdd, ast.USub)) and numeric_expression(node.operand)
    if isinstance(node, ast.BinOp):
        return numeric_expression(node.left) and numeric_expression(node.right)
    return False

tunables = dictionary_keys("TUNABLES")
fixed = dictionary_keys("DELIBERATELY_FIXED")
required = {
    "DEADLINE", "RUNNER_WAIT_SECONDS", "RUNNER_STARTUP_SECONDS", "EVENT_LIMIT",
    "LINE_LIMIT", "READ_BATCH", "TERMINAL_SETTLE_LIMIT_SECONDS",
}
if not required <= tunables:
    raise SystemExit(f"operational tunables missing from TUNABLES: {sorted(required - tunables)}")

numeric_constants = set()
for statement in tree.body:
    if isinstance(statement, ast.Assign) and numeric_expression(statement.value):
        numeric_constants.update(
            target.id for target in statement.targets
            if isinstance(target, ast.Name) and target.id.isupper()
        )
    if (
        isinstance(statement, ast.AnnAssign)
        and isinstance(statement.target, ast.Name)
        and statement.target.id.isupper()
        and statement.value is not None
        and numeric_expression(statement.value)
    ):
        numeric_constants.add(statement.target.id)
unclassified = numeric_constants - tunables - fixed
if unclassified:
    raise SystemExit(f"unclassified numeric constants: {sorted(unclassified)}")

specs = assigned("TUNABLES")
assert isinstance(specs, ast.Dict)
configured_environment = set()
for key, value in zip(specs.keys, specs.values):
    if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
        raise SystemExit("TUNABLES has a non-literal name")
    if not isinstance(value, ast.Call) or not value.args or not isinstance(value.args[0], ast.Constant):
        raise SystemExit(f"{key.value} has no literal environment variable")
    environment = value.args[0].value
    if environment != f"CODEX_DELEGATE_{key.value}":
        raise SystemExit(f"{key.value} breaks the environment naming convention")
    configured_environment.add(environment)

non_tunable = assigned("NON_TUNABLE_ENVIRONMENT")
if not isinstance(non_tunable, (ast.Tuple, ast.List)):
    raise SystemExit("NON_TUNABLE_ENVIRONMENT is not a literal list")
accounted_environment = configured_environment | {
    item.value for item in non_tunable.elts
    if isinstance(item, ast.Constant) and isinstance(item.value, str)
}
used_environment = set()
for node in ast.walk(tree):
    if not isinstance(node, ast.Call) or not node.args:
        continue
    function = node.func
    if not isinstance(function, ast.Attribute) or function.attr != "get":
        continue
    owner = function.value
    if not (
        isinstance(owner, ast.Attribute) and owner.attr == "environ"
        and isinstance(owner.value, ast.Name) and owner.value.id == "os"
    ):
        continue
    argument = node.args[0]
    if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
        used_environment.add(argument.value)
unaccounted_environment = {
    name for name in used_environment
    if name.startswith("CODEX_DELEGATE_") and name not in accounted_environment
}
if unaccounted_environment:
    raise SystemExit(f"unaccounted CODEX_DELEGATE environment hooks: {sorted(unaccounted_environment)}")
PY
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
