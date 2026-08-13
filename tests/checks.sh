#!/bin/bash
# Regression cases for release checks whose former green result proved too little.
# There is deliberately no embedded-Python line cap here: a cap that recognizes only some
# shell spellings of an embedded block passes files it never inspected, worse than no cap.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=$ROOT/bin/codex-delegate
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
