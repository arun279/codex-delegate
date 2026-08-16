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
minimum_codex_version=0.146.1

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
else
  # A watchdog in plain sh: the probe runs in the background against a temp file and is killed
  # after its bound, so a hung codex cannot stall SessionStart and no extra runtime is required.
  codex_version_status=125
  codex_version_file=$(mktemp 2>/dev/null) || codex_version_file=''
  if [ -n "$codex_version_file" ]; then
    codex --version >"$codex_version_file" 2>/dev/null &
    codex_version_pid=$!
    codex_version_status=124
    codex_version_waited=0
    while [ "$codex_version_waited" -lt 20 ]; do
      if ! kill -0 "$codex_version_pid" 2>/dev/null; then
        wait "$codex_version_pid"
        codex_version_status=$?
        break
      fi
      sleep 0.1
      codex_version_waited=$((codex_version_waited + 1))
    done
    if [ "$codex_version_status" -eq 124 ]; then
      kill "$codex_version_pid" 2>/dev/null
      wait "$codex_version_pid" 2>/dev/null
    fi
    codex_version_output=$(cat "$codex_version_file" 2>/dev/null)
    rm -f "$codex_version_file"
  fi
  if [ "$codex_version_status" -ne 0 ]; then
    add "Note: codex --version did not answer successfully within the version probe bound; continuing preflight."
  else
    # A prerelease suffix (0.148.0-alpha.9) is a newer build, not an unrecognized one; the floor
    # comparison uses the base version.
    observed_codex_version=$(printf '%s\n' "$codex_version_output" | sed -n 's/^codex-cli \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\(-[0-9A-Za-z.-][0-9A-Za-z.-]*\)\{0,1\}$/\1/p')
    if [ -z "$observed_codex_version" ]; then
      add "Note: codex --version returned an unrecognized version; continuing preflight."
    elif awk -v observed="$observed_codex_version" -v required="$minimum_codex_version" 'BEGIN {
      split(observed, actual, ".")
      split(required, floor, ".")
      for (part = 1; part <= 3; part++) {
        if (actual[part] < floor[part]) exit 0
        if (actual[part] > floor[part]) exit 1
      }
      exit 1
    }'; then
      add "Warning: Codex CLI version $observed_codex_version is below the required minimum $minimum_codex_version."
    fi
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  add "python3 is not on PATH. The launcher, Bash guard, and Workflow guard all require it, so delegated runs cannot start safely."
elif ! python3 -c '' >/dev/null 2>&1; then
  add "python3 is at $(esc "$(command -v python3)") but will not run: python3 -c '' failed. On macOS /usr/bin/python3 can dispatch through xcode-select. Check that xcode-select -p names an installed toolchain, or run xcode-select --install. Until then the launcher and both guards are unavailable."
elif ! /usr/bin/env -S python3 -I -S -c 'import sys; raise SystemExit(not (sys.flags.isolated and sys.flags.no_site))' >/dev/null 2>&1; then
  add "The launcher cannot start through /usr/bin/env -S python3 -I -S. It requires /usr/bin/env with -S support and a python3 on PATH that honors both isolation flags."
fi

plugin_root=${CLAUDE_PLUGIN_ROOT:-}
if [ -z "$plugin_root" ]; then
  add "CLAUDE_PLUGIN_ROOT is empty, so the SessionStart hook cannot locate the shipped codex-delegate launcher. Reinstall or re-enable the plugin, then open a new session."
else
  shipped=$plugin_root/bin/codex-delegate
  # The interpreter line is probed verbatim above; -x covers its executable bit. SessionStart
  # deliberately avoids spawning the launcher, so only argument parsing is unexercised.
  if [ ! -f "$shipped" ] || [ ! -x "$shipped" ]; then
    add "The shipped codex-delegate launcher at $(esc "$shipped") is missing or not executable. Reinstall or re-enable the plugin, then open a new session."
  else
    # Claude injects plugin bin/ only into Bash-tool PATH, not this SessionStart hook. An absent
    # bare name is therefore healthy here. A present different name is inherited from the login
    # environment and would precede the later Bash-tool injection, so delegated runs would use it.
    found=$(command -v codex-delegate 2>/dev/null)
    if [ -n "$found" ] && [ "$(physical "$found")" != "$(physical "$shipped")" ]; then
      add "Unsafe codex-delegate PATH mismatch. PATH resolves the bare name to $(esc "$found"), but this plugin ships $(esc "$shipped"). Delegated runs would invoke the other copy. To use this plugin, uninstall that separate copy or put this plugin's bin directory first on the Bash tool's PATH. If you intend to use the separate copy instead, disable this plugin."
    fi
  fi
fi

[ -n "$problems" ] || exit 0

printf '{"systemMessage":"codex-delegate preflight:\\n\\n%s"}\n' "$problems"
