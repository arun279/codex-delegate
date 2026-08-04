#!/bin/sh
# SessionStart: name everything that stops codex-delegate from working, once, before anything
# fails halfway through a run.
#
# POSIX sh and no python on purpose. A python3 that resolves on PATH but will not start is one of
# the failures this reports, and a reporter written in the broken thing cannot report it.
#
# Silence is the healthy path. SessionStart stdout that is not valid JSON is appended to Claude's
# context verbatim, so anything printed here that is not a problem is a tax on every session. A
# problem goes out as one JSON object whose systemMessage the human reads instead. Exit is always
# 0: a preflight that blocks the session is worse than anything it can find.

problems=''

# Two filesystem paths get interpolated. A backslash or a double quote in either would produce
# JSON that the harness silently drops, taking the whole report with it.
esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Resolve symlinked ancestors so that a plugin loaded from, say, /tmp is not reported as a
# different binary from the /private/tmp path PATH hands back.
physical() {
  (cd -- "$(dirname -- "$1")" 2>/dev/null &&
    printf '%s/%s' "$(pwd -P)" "$(basename -- "$1")")
}

add() {
  [ -z "$problems" ] || problems="$problems"'\n\n'
  problems="$problems$1"
}

system=$(uname -s)
if [ "$system" != Darwin ]; then
  add "Not macOS: uname -s reports $(esc "$system"). The launcher deliberately supports macOS process-group behavior only. Disable this plugin here."
fi

# The URL and nothing else. OpenAI ships a standalone installer, npm and homebrew, and this
# script cannot tell which of them owns codex on the machine it is running on.
if ! command -v codex >/dev/null 2>&1; then
  add "codex is not on PATH, so no run can start. Install the Codex CLI from https://developers.openai.com/codex/cli/ and open a new session."
fi

if ! command -v python3 >/dev/null 2>&1; then
  add "python3 is not on PATH. The launcher, Bash guard, and Workflow guard all require it, so delegated runs cannot start safely."
elif ! python3 -c '' >/dev/null 2>&1; then
  add "python3 is at $(esc "$(command -v python3)") but will not run: python3 -c '' failed. On macOS /usr/bin/python3 can dispatch through xcode-select. Check that xcode-select -p names an installed toolchain, or run xcode-select --install. Until then the launcher and both guards are unavailable."
fi

shipped=$CLAUDE_PLUGIN_ROOT/bin/codex-delegate
found=$(command -v codex-delegate 2>/dev/null)
if [ -n "$found" ] && [ "$(physical "$found")" != "$(physical "$shipped")" ]; then
  add "Unsafe codex-delegate PATH mismatch. PATH resolves the bare name to $(esc "$found"), but this plugin ships $(esc "$shipped"). The permission hook will not approve or persist a rule for either name. Delete the other copy or invoke the shipped absolute path after checking it."
fi

[ -n "$problems" ] || exit 0

printf '{"systemMessage":"codex-delegate preflight:\\n\\n%s"}\n' "$problems"
