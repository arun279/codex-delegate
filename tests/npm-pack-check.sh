#!/bin/bash
# Exercise the unexpected-file failure path in the npm archive guard.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" npm-pack-check || exit 2
FIXTURE=$CODEX_DELEGATE_TEST_TMP_WORK/fixture
test_temp_install_traps

mkdir -p "$FIXTURE/bin" "$FIXTURE/scripts" || exit 2
cp "$ROOT/scripts/npm-pack-check.py" "$FIXTURE/scripts/" || exit 2
for file in CHANGELOG.md LICENSE PRIVACY.md README.md SECURITY.md; do
  printf 'fixture\n' >"$FIXTURE/$file" || exit 2
done
printf '#!/bin/sh\n' >"$FIXTURE/bin/codex-delegate" || exit 2
printf '%s\n' \
  '{' \
  '  "name": "npm-pack-check-fixture",' \
  '  "version": "1.0.0",' \
  '  "files": ["bin/codex-delegate", "CHANGELOG.md", "PRIVACY.md", "SECURITY.md"]' \
  '}' >"$FIXTURE/package.json" || exit 2

python3 "$FIXTURE/scripts/npm-pack-check.py" >"$FIXTURE/clean-stdout" 2>"$FIXTURE/clean-stderr"
RC=$?
if [ "$RC" -ne 0 ] || ! grep -Fq 'npm-pack-check: PASS (7 exact files)' "$FIXTURE/clean-stdout"; then
  printf 'npm pack guard fixture: checker baseline failed with exit %s\n' "$RC" >&2
  cat "$FIXTURE/clean-stdout" "$FIXTURE/clean-stderr" >&2
  exit 1
fi

printf 'unexpected fixture file\n' >"$FIXTURE/NOTICE" || exit 2
python3 -c 'import json,sys; path=sys.argv[1]; value=json.load(open(path)); value["files"].append("NOTICE"); json.dump(value,open(path,"w"))' \
  "$FIXTURE/package.json"
python3 "$FIXTURE/scripts/npm-pack-check.py" >"$FIXTURE/stdout" 2>"$FIXTURE/stderr"
RC=$?
if [ "$RC" -ne 1 ]; then
  printf 'npm pack guard fixture: expected exit 1, got %s\n' "$RC" >&2
  cat "$FIXTURE/stdout" "$FIXTURE/stderr" >&2
  exit 1
fi
if ! grep -Fq 'npm-pack-check: FAIL: expected ' "$FIXTURE/stderr"; then
  echo 'npm pack guard fixture: missing changed-set diagnostic' >&2
  cat "$FIXTURE/stderr" >&2
  exit 1
fi
echo 'npm pack guard fixture: PASS (changed packed set rejected)'
