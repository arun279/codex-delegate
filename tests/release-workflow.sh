#!/bin/bash
# Behavioral checks for the irreversible release workflow steps.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
WORKFLOW=${RELEASE_WORKFLOW:-$ROOT/.github/workflows/release.yml}
. "$ROOT/scripts/test-temp.sh"
test_temp_create "$ROOT" release-workflow || {
  echo "release-workflow: temporary directory creation failed" >&2
  exit 2
}
WORK=$CODEX_DELEGATE_TEST_TMP_WORK
test_temp_install_traps
mkdir -p "$WORK/bin" || exit 2

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

extract_step() { # step-name output-path
  awk -v target="$1" '
    $0 == "      - name: " target { found=1; next }
    found && /^      - / { exit }
    found && /^        run: \|/ { body=1; next }
    body && /^          / { sub(/^          /, ""); print; next }
    body && /^[[:space:]]*$/ { print ""; next }
    body { exit }
    END { if (!body) exit 1 }
  ' "$WORKFLOW" >"$2"
}

cat >"$WORK/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ "${1:-} ${2:-}" != "run list" ]; then
  echo "unexpected gh call: $*" >&2
  exit 64
fi
case "$CI_SCENARIO" in
  success) printf '%s\tcompleted\tsuccess\n' "$GITHUB_SHA" ;;
  failure) printf '%s\tcompleted\tfailure\n' "$GITHUB_SHA" ;;
  pending) printf '%s\tin_progress\t\n' "$GITHUB_SHA" ;;
  missing) ;;
  *) echo "unknown CI_SCENARIO: $CI_SCENARIO" >&2; exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

cat >"$WORK/bin/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$GIT_CALLS"
if [ "${1:-}" != ls-remote ]; then
  echo "unexpected git call: $*" >&2
  exit 64
fi
tag_ref="refs/tags/${PLUGIN_TAG}"
case "$TAG_SCENARIO" in
  matching)
    printf '%s\t%s\n' "$GITHUB_SHA" "$tag_ref"
    ;;
  annotated-matching)
    printf '%s\t%s\n' 1111111111111111111111111111111111111111 "$tag_ref"
    printf '%s\t%s^{}\n' "$GITHUB_SHA" "$tag_ref"
    ;;
  mismatched)
    printf '%s\t%s\n' 2222222222222222222222222222222222222222 "$tag_ref"
    ;;
  missing-then-matching)
    if [ -e "$TAG_CREATED" ]; then
      printf '%s\t%s\n' "$GITHUB_SHA" "$tag_ref"
    else
      exit 2
    fi
    ;;
  transport-error)
    exit 128
    ;;
  *)
    echo "unknown TAG_SCENARIO: $TAG_SCENARIO" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$WORK/bin/git"

cat >"$WORK/bin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$CLAUDE_CALLS"
touch "$TAG_CREATED"
EOF
chmod +x "$WORK/bin/claude"

export PATH=$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin
export GH_CALLS=$WORK/gh.calls
export GIT_CALLS=$WORK/git.calls
export CLAUDE_CALLS=$WORK/claude.calls
export TAG_CREATED=$WORK/tag-created
export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export PLUGIN_TAG=codex-delegate--v1.2.3

printf '\n== successful-CI release precondition\n'
check 'grep -Eq "^[[:space:]]+actions: read[[:space:]]*$" "$WORKFLOW"' \
  "the release token can read Actions results"
CI_STEP=$WORK/ci-step.sh
if extract_step "Require successful CI" "$CI_STEP"; then
  : >"$GH_CALLS"
  CI_SCENARIO=failure bash -e "$CI_STEP" >"$WORK/ci-failure.out" 2>&1
  CI_RC=$?
  check '[ "$CI_RC" -ne 0 ]' "a failed CI run blocks release"

  CI_SCENARIO=pending bash -e "$CI_STEP" >"$WORK/ci-pending.out" 2>&1
  CI_RC=$?
  check '[ "$CI_RC" -ne 0 ]' "an incomplete CI run blocks release"

  CI_SCENARIO=missing bash -e "$CI_STEP" >"$WORK/ci-missing.out" 2>&1
  CI_RC=$?
  check '[ "$CI_RC" -ne 0 ]' "a missing CI run blocks release"

  CI_SCENARIO=success bash -e "$CI_STEP" >"$WORK/ci-success.out" 2>&1
  CI_RC=$?
  check '[ "$CI_RC" -eq 0 ]' "the completed successful CI run permits release"
  check 'grep -Fq -- "run list --workflow ci.yml --commit $GITHUB_SHA --event push --limit 1" "$GH_CALLS" &&
         grep -Fq -- "--json headSha,status,conclusion" "$GH_CALLS"' \
    "the query is scoped to the push CI run for GITHUB_SHA"
else
  bad "release has no successful-CI precondition"
fi

printf '\n== existing and newly-created tag identity\n'
TAG_STEP=$WORK/tag-step.sh
if extract_step "Create and push plugin tag" "$TAG_STEP"; then
  : >"$GIT_CALLS"
  : >"$CLAUDE_CALLS"
  TAG_SCENARIO=mismatched bash -e "$TAG_STEP" >"$WORK/tag-mismatch.out" 2>&1
  TAG_RC=$?
  check '[ "$TAG_RC" -ne 0 ]' "an existing tag on another commit blocks release"
  check '[ ! -s "$CLAUDE_CALLS" ]' "a mismatched existing tag is never rewritten"

  : >"$GIT_CALLS"
  TAG_SCENARIO=matching bash -e "$TAG_STEP" >"$WORK/tag-matching.out" 2>&1
  TAG_RC=$?
  check '[ "$TAG_RC" -eq 0 ] && [ ! -s "$CLAUDE_CALLS" ]' \
    "a matching lightweight tag is accepted without creation"

  : >"$GIT_CALLS"
  TAG_SCENARIO=annotated-matching bash -e "$TAG_STEP" >"$WORK/tag-annotated.out" 2>&1
  TAG_RC=$?
  check '[ "$TAG_RC" -eq 0 ]' "an annotated tag is compared by its peeled commit"

  : >"$GIT_CALLS"
  : >"$CLAUDE_CALLS"
  rm -f -- "$TAG_CREATED"
  TAG_SCENARIO=missing-then-matching bash -e "$TAG_STEP" >"$WORK/tag-created.out" 2>&1
  TAG_RC=$?
  check '[ "$TAG_RC" -eq 0 ] && [ "$(wc -l <"$GIT_CALLS")" -eq 2 ] &&
         grep -Fq "plugin tag --push ." "$CLAUDE_CALLS"' \
    "a newly-created tag is verified at the remote before release continues"

  : >"$GIT_CALLS"
  : >"$CLAUDE_CALLS"
  TAG_SCENARIO=transport-error bash -e "$TAG_STEP" >"$WORK/tag-transport.out" 2>&1
  TAG_RC=$?
  check '[ "$TAG_RC" -eq 128 ] && [ ! -s "$CLAUDE_CALLS" ]' \
    "a remote lookup error blocks release without creating a tag"
else
  bad "release has no plugin-tag step"
fi

printf '\n== irreversible-step ordering\n'
CI_LINE=$(grep -nF -- "- name: Require successful CI" "$WORKFLOW" | cut -d: -f1)
TAG_LINE=$(grep -nF -- "- name: Create and push plugin tag" "$WORKFLOW" | cut -d: -f1)
RELEASE_LINE=$(grep -nF -- "- name: Create GitHub release" "$WORKFLOW" | cut -d: -f1)
PUBLISH_LINE=$(grep -nF -- "- name: Publish npm package" "$WORKFLOW" | cut -d: -f1)
check '[ -n "$CI_LINE" ] && [ "$CI_LINE" -lt "$TAG_LINE" ] &&
       [ "$TAG_LINE" -lt "$RELEASE_LINE" ] && [ "$RELEASE_LINE" -lt "$PUBLISH_LINE" ]' \
  "CI is proven before tag, GitHub release, and npm publication"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
