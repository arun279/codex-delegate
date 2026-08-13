#!/bin/bash
# Exercise the installed shape of a versioned plugin fetched from Git smart HTTP.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" plugin-lifecycle || {
  echo "plugin-lifecycle: temporary directory creation failed" >&2
  exit 2
}
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
SERVER_PID=
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
  fi
  test_temp_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

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
check() {
  if eval "$1"; then
    ok "$2"
  else
    bad "$2 [$1]"
  fi
}
wait_file() {
  # 500 x 0.02s allows ten nominal seconds: hosted runners start interpreters noticeably
  # slower than a developer machine, and the wait is on the port file, not on a request.
  local path=$1 attempt=0
  while [ ! -s "$path" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.02
  done
  [ -s "$path" ]
}
run_required() {
  "$@"
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "plugin-lifecycle: command failed with exit $status: $*" >&2
    exit 2
  fi
}
write_manifest() { # version marker
  local version=$1 marker=$2
  printf '%s\n' \
    '{' \
    '  "name": "lifecycle-probe",' \
    '  "version": "'"$version"'",' \
    '  "description": "Throwaway lifecycle probe"' \
    '}' >"$SOURCE/.claude-plugin/plugin.json"
  printf '%s\n' "$marker" >"$SOURCE/agents/probe.md"
  printf '%s\n' "$marker" >"$SOURCE/bin/probe-marker"
}
publish_source() {
  local message=$1 remote_head branch
  remote_head=$(git -C "$REMOTE/remote.git" symbolic-ref HEAD) || return
  branch=${remote_head#refs/heads/}
  [ "$remote_head" = "refs/heads/$branch" ] || return 1
  run_required git -C "$SOURCE" add .claude-plugin/plugin.json agents/probe.md bin/probe-marker
  run_required git -C "$SOURCE" commit -m "$message"
  run_required git -C "$SOURCE" push "$REMOTE/remote.git" "HEAD:$remote_head"
  run_required git -C "$REMOTE/remote.git" update-server-info
}
cache_dir() { # version
  find "$CLAUDE_CONFIG_DIR/plugins/cache" -type d -path "*/lifecycle-probe/$1" -print 2>/dev/null
}

command -v claude >/dev/null 2>&1 || {
  echo "plugin-lifecycle: required tool 'claude' is missing from PATH" >&2
  exit 127
}
command -v git >/dev/null 2>&1 || {
  echo "plugin-lifecycle: required tool 'git' is missing from PATH" >&2
  exit 127
}

SOURCE=$WORK/source
REMOTE=$WORK/remote
HOME=$WORK/home
CLAUDE_CONFIG_DIR=$WORK/home/.claude
export HOME CLAUDE_CONFIG_DIR
MARKET=lifecycle-probe-market
PLUGIN=lifecycle-probe@$MARKET
mkdir -p "$SOURCE/.claude-plugin" "$SOURCE/agents" "$SOURCE/bin" \
  "$SOURCE/node_modules" "$SOURCE/.mypy_cache" "$SOURCE/.tmp" "$REMOTE" "$HOME" || exit 2
printf '%s\n' \
  '{' \
  '  "name": "lifecycle-probe-market",' \
  '  "owner": {"name": "codex-delegate test"},' \
  '  "plugins": [' \
  '    {"name": "lifecycle-probe", "source": "./"}' \
  '  ]' \
  '}' >"$SOURCE/.claude-plugin/marketplace.json"
printf '%s\n' UNTRACKED_NODE_MODULE >"$SOURCE/node_modules/untracked"
printf '%s\n' UNTRACKED_MYPY_CACHE >"$SOURCE/.mypy_cache/untracked"
printf '%s\n' UNTRACKED_TMP >"$SOURCE/.tmp/untracked"
write_manifest 1.0.0 MARKER_V1

run_required git -C "$SOURCE" init -b main
run_required git -C "$SOURCE" config user.name codex-delegate-test
run_required git -C "$SOURCE" config user.email codex-delegate-test@example.invalid
run_required git -C "$SOURCE" add .claude-plugin agents bin
run_required git -C "$SOURCE" commit -m v1
run_required git clone --bare "$SOURCE" "$REMOTE/remote.git"
run_required git -C "$REMOTE/remote.git" symbolic-ref HEAD refs/heads/main
run_required git -C "$REMOTE/remote.git" update-server-info

PORT_FILE=$WORK/server.port
python3 "$ROOT/tests/plugin-lifecycle-smarthttp.py" "$REMOTE" "$PORT_FILE" \
  >"$WORK/server.out" 2>"$WORK/server.err" &
SERVER_PID=$!
wait_file "$PORT_FILE" || {
  cat "$WORK/server.err" >&2
  echo "plugin-lifecycle: smart-HTTP server did not publish its port" >&2
  exit 2
}
PORT=$(cat "$PORT_FILE")
REMOTE_URL=http://127.0.0.1:$PORT/remote.git

printf '\n== initial git-source install\n'
run_required claude plugin marketplace add "$REMOTE_URL" --scope user
run_required claude plugin install "$PLUGIN" --scope user
CACHE_V1=$(cache_dir 1.0.0)
check '[ -n "$CACHE_V1" ] && [ "$(printf "%s\n" "$CACHE_V1" | wc -l)" -eq 1 ]' \
  "install creates one versioned 1.0.0 cache"
check 'grep -Fq MARKER_V1 "$CACHE_V1/agents/probe.md" &&
       grep -Fq MARKER_V1 "$CACHE_V1/bin/probe-marker"' \
  "the installed agent and executable have the committed bytes"
check '[ ! -e "$CACHE_V1/node_modules" ] && [ ! -e "$CACHE_V1/.mypy_cache" ] &&
       [ ! -e "$CACHE_V1/.tmp" ]' \
  "the git-source cache excludes untracked working-tree artifacts"

printf '\n== changed commit without a version bump\n'
write_manifest 1.0.0 MARKER_V2_SAME_VERSION
publish_source same-version-change
run_required claude plugin marketplace update "$MARKET"
MARKET_CLONE=$CLAUDE_CONFIG_DIR/plugins/marketplaces/$MARKET
check 'grep -R -Fq MARKER_V2_SAME_VERSION "$MARKET_CLONE"' \
  "the marketplace clone receives the changed commit"
claude plugin update "$PLUGIN" --scope user >"$WORK/same-version.out" 2>&1
UPDATE_RC=$?
check '[ "$UPDATE_RC" -eq 0 ] && [ "$(printf "%s\n" "$(cache_dir 1.0.0)" | wc -l)" -eq 1 ] &&
       [ -z "$(cache_dir 1.0.1)" ]' \
  "an unchanged version creates no new versioned cache"
check 'grep -Fq MARKER_V1 "$CACHE_V1/agents/probe.md" &&
       ! grep -R -Fq MARKER_V2_SAME_VERSION "$CACHE_V1"' \
  "the installed cache remains on old bytes without a version bump"

printf '\n== changed commit with a version bump\n'
write_manifest 1.0.1 MARKER_V3_BUMPED
publish_source bumped-version-change
run_required claude plugin marketplace update "$MARKET"
check 'grep -R -Fq MARKER_V3_BUMPED "$MARKET_CLONE"' \
  "the marketplace clone receives the bumped commit"
claude plugin update "$PLUGIN" --scope user >"$WORK/bumped-version.out" 2>&1
UPDATE_RC=$?
CACHE_V2=$(cache_dir 1.0.1)
check '[ "$UPDATE_RC" -eq 0 ] && [ -n "$CACHE_V2" ]' \
  "a bumped version creates a new versioned cache"
check '[ -n "$CACHE_V2" ] && grep -Fq MARKER_V3_BUMPED "$CACHE_V2/agents/probe.md" &&
       grep -Fq MARKER_V3_BUMPED "$CACHE_V2/bin/probe-marker"' \
  "the 1.0.1 cache contains the bumped commit bytes"

printf '\n== teardown\n'
run_required claude plugin uninstall "$PLUGIN" --scope user
run_required claude plugin marketplace remove "$MARKET" --scope user
run_required claude plugin list --json >"$WORK/plugins-after.json"
run_required claude plugin marketplace list --json >"$WORK/markets-after.json"
check '! grep -Fq lifecycle-probe "$WORK/plugins-after.json"' \
  "uninstall removes the plugin from caller-visible state"
check '! grep -Fq "$MARKET" "$WORK/markets-after.json"' \
  "marketplace removal clears caller-visible state"
kill -TERM "$SERVER_PID" 2>/dev/null
KILL_RC=$?
STOPPED_SERVER_PID=$SERVER_PID
wait "$STOPPED_SERVER_PID" 2>/dev/null
WAIT_RC=$?
SERVER_PID=
check '[ "$KILL_RC" -eq 0 ] && [ "$WAIT_RC" -eq 143 ] &&
       ! kill -0 "$STOPPED_SERVER_PID" 2>/dev/null' \
  "smart-HTTP server reports signal termination and is stopped"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
