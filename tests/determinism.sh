#!/bin/bash
# Repeat one offline job and reject unexplained status drift.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=$ROOT/bin/codex-delegate
N=${DETERMINISM_RUNS:-${1:-5}}
case "$N" in ''|*[!0-9]*) echo "determinism: run count must be an integer >= 2" >&2; exit 2 ;; esac
[ "$N" -ge 2 ] || { echo "determinism: run count must be >= 2" >&2; exit 2; }

TMP_BASE=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${TMP_BASE%/}/codex-delegate-determinism.XXXXXX") || exit 2
WORK=$(cd -- "$WORK" && pwd -P) || exit 2
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP
mkdir -p "$WORK/home" "$WORK/runs" "$WORK/job" || exit 2
printf 'Perform the same deterministic offline stub job.\n' >"$WORK/prompt.txt"
export HOME=$WORK/home
export CODEX_DELEGATE_HOME=$WORK/runs
export PATH=$ROOT/tests/stub:/usr/bin:/bin:/usr/sbin:/sbin

i=1
while [ "$i" -le "$N" ]; do
  runid=$(printf 'determinism-%02d' "$i")
  STUB_MODE=ok "$BIN" run --prompt-file "$WORK/prompt.txt" --sandbox read-only \
    --cwd "$WORK/job" --model gpt-5.6-sol --effort medium --deadline 60 \
    --runid "$runid" >"$WORK/output-$i" 2>"$WORK/error-$i"
  rc=$?
  printf '%s\n' "$rc" >"$WORK/exit-$i"
  [ -f "$WORK/runs/$runid/status.json" ] || {
    echo "determinism: run $i did not publish status.json" >&2
    exit 1
  }
  cp "$WORK/runs/$runid/status.json" "$WORK/status-$i.json"
  echo "determinism: run $i exit=$rc"
  i=$((i + 1))
done

python3 "$ROOT/tests/determinism_check.py" "$WORK" "$N"
