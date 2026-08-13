#!/bin/bash
# End-to-end launcher handoff, wait, and byte-exact report checks.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${CODEX_DELEGATE_TEST_BIN:-$ROOT/bin/codex-delegate}
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" runner-handoff || exit 2
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  test_temp_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$WORK/home" "$WORK/runs" "$WORK/job" || exit 2
printf 'runner handoff round trip\n' >"$WORK/prompt.txt"
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

handoff_case() {
  local name=$1 mode=$2 expected_rc=$3 expected_verdict=$4
  local kickoff=$WORK/$name.kickoff launcher rc runid rd wait_state=RUNNING waits=0
  STUB_MODE=$mode "$BIN" run --prompt-file "$WORK/prompt.txt" \
    --sandbox read-only --cwd "$WORK/job" --model stub-model-a --effort medium \
    --deadline 10 --runner-handoff >"$kickoff" 2>&1 &
  launcher=$!
  PIDS+=("$launcher")

  while [ "$wait_state" = RUNNING ] && [ "$waits" -lt 20 ]; do
    waits=$((waits + 1))
    "$BIN" runner-wait "$kickoff" >"$WORK/$name.wait" 2>"$WORK/$name.wait.err"
    wait_state=$(cat "$WORK/$name.wait")
  done
  wait "$launcher"
  rc=$?
  "$BIN" runner-report "$kickoff" >"$WORK/$name.report" 2>"$WORK/$name.report.err"
  python3 -c 'import re,sys; source=open(sys.argv[1],"rb"); lines=[]; pid=None; pid_offset=None; runid_offset=None; end_offsets=[]
while True:
 offset=source.tell(); line=source.readline()
 if not line: break
 lines.append((offset,line)); match=re.fullmatch(rb"CODEX_DELEGATE_LAUNCHER_PID=([1-9][0-9]*)\n",line)
 if pid is None and match is not None: pid=match.group(1); pid_offset=offset; continue
 match=re.fullmatch(rb"CODEX_DELEGATE_RUNID=runner-[0-9a-f]{32}\n",line)
 if pid is not None and runid_offset is None and match is not None: runid_offset=offset; continue
 match=re.fullmatch(rb"CODEX_DELEGATE_LAUNCHER_ENDED=([1-9][0-9]*)\n",line)
 if pid is not None and match is not None and match.group(1)==pid: end_offsets.append(offset)
skipped={item for item in (pid_offset,runid_offset) if item is not None}
if end_offsets: skipped.add(end_offsets[-1])
open(sys.argv[2],"wb").write(b"".join(line for offset,line in lines if offset not in skipped))' \
    "$kickoff" "$WORK/$name.expected"
  runid=$(sed -n 's/^CODEX_DELEGATE_RUNID=//p' "$kickoff" | head -n 1)
  rd=$WORK/runs/$runid

  check '[ "$rc" = "$expected_rc" ] &&
         [ "$wait_state" = ENDED ] && [ "$waits" -le 20 ]' \
    "$name waits through ENDED and exits $expected_rc"
  check 'cmp -s "$WORK/'"$name"'.expected" "$WORK/'"$name"'.report" &&
         [ ! -s "$WORK/'"$name"'.report.err" ]' \
    "$name report is the launcher output without handoff records"
  check 'python3 "$ROOT/tests/status_schema.py" --verdict "$expected_verdict" "$rd/status.json"' \
    "$name report has the expected verdict and exact 16-field schema"
}

printf '\n== runner handoff round trips\n'
handoff_case completed ok 0 COMPLETED
handoff_case failed fail 10 FAILED

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
