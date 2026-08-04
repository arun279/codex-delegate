#!/bin/bash
# Shared temporary-directory setup for the release gate and shell suites.

CODEX_DELEGATE_TEST_TMP_WORK=
CODEX_DELEGATE_TEST_TMP_PARENT=
CODEX_DELEGATE_TEST_TMP_LOCAL=0

test_temp_create() { # repository-root label
  local root=$1 label=$2 base physical

  CODEX_DELEGATE_TEST_TMP_WORK=
  CODEX_DELEGATE_TEST_TMP_PARENT=
  CODEX_DELEGATE_TEST_TMP_LOCAL=0
  if [ -n "${TMPDIR:-}" ]; then
    base=${TMPDIR%/}
  else
    base=$root/.tmp
    CODEX_DELEGATE_TEST_TMP_PARENT=$base
    CODEX_DELEGATE_TEST_TMP_LOCAL=1
    if [ -L "$base" ]; then
      printf 'test temp root must not be a symlink: %s\n' "$base" >&2
      return 1
    fi
    mkdir -p -- "$base" || return 1
    physical=$(cd -- "$base" && pwd -P) || {
      test_temp_cleanup
      return 1
    }
    if [ "$physical" != "$base" ]; then
      printf 'test temp root must be physical: %s\n' "$base" >&2
      test_temp_cleanup
      return 1
    fi
    chmod 700 "$base" || {
      test_temp_cleanup
      return 1
    }
    base=$physical
  fi

  CODEX_DELEGATE_TEST_TMP_WORK=$(mktemp -d "${base%/}/codex-delegate-$label.XXXXXX") || {
    test_temp_cleanup
    return 1
  }
  physical=$(cd -- "$CODEX_DELEGATE_TEST_TMP_WORK" && pwd -P) || {
    test_temp_cleanup
    return 1
  }
  CODEX_DELEGATE_TEST_TMP_WORK=$physical
  if [ "$CODEX_DELEGATE_TEST_TMP_LOCAL" -eq 1 ]; then
    export TMPDIR=$CODEX_DELEGATE_TEST_TMP_WORK
  fi
}

test_temp_cleanup() {
  if [ -n "$CODEX_DELEGATE_TEST_TMP_WORK" ]; then
    rm -rf -- "$CODEX_DELEGATE_TEST_TMP_WORK"
    CODEX_DELEGATE_TEST_TMP_WORK=
  fi
  if [ "$CODEX_DELEGATE_TEST_TMP_LOCAL" -eq 1 ] &&
    [ -n "$CODEX_DELEGATE_TEST_TMP_PARENT" ]; then
    rmdir -- "$CODEX_DELEGATE_TEST_TMP_PARENT" 2>/dev/null || true
  fi
}

test_temp_install_traps() {
  trap test_temp_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
