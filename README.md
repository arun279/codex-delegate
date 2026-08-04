# codex-delegate

Hand one coding task from Claude Code to the OpenAI Codex CLI and get the result back in one
blocking call.

The launcher starts `codex exec` in a private process group, reads its JSON event stream, enforces a
wall-clock deadline, returns the final message, publishes one status record, and cleans up the group
before it exits. `INT`, `TERM`, and `HUP` stop that same foreground run. There is no detached job,
polling protocol, or recovery command.

**Requires macOS**, Python 3, and the Codex CLI already installed and signed in.

> **Unofficial project.** Not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic.
> OpenAI and Codex are trademarks of OpenAI, L.L.C. Claude and Claude Code are trademarks of
> Anthropic PBC. Those names identify interoperating software only. No endorsement is implied.

## Install

In Claude Code:

```text
/plugin marketplace add https://github.com/arun279/codex-delegate.git
/plugin install codex-delegate@arun279-plugins
```

Then restart Claude Code, or run `/reload-plugins`.

The terminal equivalents are:

```bash
claude plugin marketplace add https://github.com/arun279/codex-delegate.git
claude plugin install codex-delegate@arun279-plugins
```

Update an existing installation with:

```bash
claude plugin update codex-delegate@arun279-plugins
```

Restart Claude Code after updating so its cached skill and agent definitions refresh.

## From Claude Code

Ask Claude to hand one bounded task to `codex-delegate:runner`. Good tasks include a scoped
implementation, an investigation, data analysis, or an independent code review expressed as a
normal prompt. The routing skill selects a live model and effort, chooses the sandbox, constructs
the runner envelope, and checks the result.

A direct Workflow call passes the prompt string first and the options object second:

```js
await agent(
  [
    '===ARGS===',
    '--sandbox workspace-write --cwd /absolute/path/to/repo --deadline 7200',
    '===PROMPT===',
    codexPrompt,
  ].join('\n'),
  {
    agentType: 'codex-delegate:runner',
    label: 'codex:implement-auth',
    phase: 'Implementation',
  },
);
```

Both markers, a non-empty prompt body, an explicit `--sandbox`, and a deadline from 1 through 12,960
are required by the runner. Put Codex `--model` and `--effort` flags in `===ARGS===`, not in the
Workflow options object. The runner gives its Bash call the 600,000 ms tool maximum. A longer job is
backgrounded by the harness rather than killed, and its eventual result returns to the same runner;
the launcher's own deadline continues to apply, so no polling or retry is needed.

## From a terminal

```bash
codex-delegate run \
  --sandbox workspace-write \
  --cwd /absolute/path/to/repo \
  --deadline 7200 \
  --prompt-file /absolute/path/to/prompt.txt
```

Use `--prompt-stdin` when the prompt arrives on standard input. `run` blocks until a terminal event,
deadline, or stop signal. It then tears down the Codex process group, prints the final message and
status, and exits with the status code:

```text
--- FINAL MESSAGE (/Users/you/.codex-delegate/<runid>/final.txt) ---
<Codex final message, or a concise absence reason>

--- STATUS ---
<status JSON>
```

`codex-delegate models` prints the live model slugs, each default effort, and every supported
effort. There is no bundled fallback. An unavailable or invalid catalog fails plainly. Omitted
`--model` and `--effort` flags use live-catalog defaults; supplied values must form a supported pair.

## Run flags

| flag | meaning |
|---|---|
| `--prompt-stdin` or `--prompt-file FILE` | Exactly one non-empty prompt source. |
| `--sandbox read-only\|workspace-write\|danger-full-access` | Required Codex sandbox. |
| `--network` | Enable network only for `workspace-write`. |
| `--cwd DIR` | Working directory, defaulting to the current directory. |
| `--add-dir DIR` | Repeatable extra writable root. |
| `--schema FILE` | Final-message JSON Schema passed to Codex. |
| `--model M` and `--effort LEVEL` | Live-catalog model pair. |
| `--deadline SECONDS` | Wall-clock limit, from 1 through 12,960 seconds; defaults to 7,200. |
| `--runid ID` | Optional unique artifact-directory name using letters, digits, `.`, `_`, and `-`. |

The launcher passes approvals disabled, JSON output, the selected sandbox, and the prompt on stdin
to `codex exec`. `workspace-write` runs are rejected if their writable roots overlap launcher state.

## Verdicts and status

| exit | verdict | meaning |
|---:|---|---|
| 0 | `COMPLETED` | First terminal event was `turn.completed` and a final message exists. |
| 10 | `FAILED` | First terminal event was `turn.failed`. |
| 11 | `DEADLINE` | The wall-clock deadline arrived first. |
| 12 | `LAUNCH_ERROR` | Codex could not be launched. |
| 13 | `CLEANUP_FAILED` | The private process group survived the complete signal ladder. |
| 17 | `STREAM_ERROR` | JSONL was malformed, truncated, oversized, or had duplicate terminal events. |
| 18 | `PLATFORM_UNSUPPORTED` | The host is not macOS. |
| 21 | `NO_TERMINAL_EVENT` | Codex exited without `turn.completed` or `turn.failed`. |
| 23 | `OUTPUT_MISSING` | Codex completed without a non-empty final message. |

A stopped run uses verdict `STOPPED` and exits with 128 plus the signal number: 130 for `SIGINT`,
143 for `SIGTERM`, and 129 for `SIGHUP`. Exit 2 is argument, catalog, or pre-launch validation failure.

`status.json` has exactly 16 fields: `schema_version`, `runid`, `verdict`, `exit_code`, `diagnostic`,
`signal`, `model`, `effort`, `sandbox`, `deadline_s`, `duration_s`, `process_exit_code`,
`terminal_event`, `final_message_path`, `events_path`, and `stderr_path`. Read `verdict` and
`exit_code` first, then `diagnostic` and the artifact paths when a run fails.

## Privacy, trust, and cleanup limits

Starting a run sends the prompt and whatever files Codex reads to OpenAI through the signed-in
Codex CLI. The private run directory under `~/.codex-delegate/<runid>/` stores `prompt.txt`,
`events.jsonl`, `stderr.log`, an optional `final.txt`, and `status.json`. The root is owner-only and
the prompt is transported to Codex through stdin, not its process arguments.

For `read-only` and `workspace-write`, launcher state is outside Codex's writable roots. With
`danger-full-access`, Codex runs as the same user and can modify any local artifact, including its
run directory. In that sandbox, local status is operational output, not tamper-proof attestation.

Cleanup owns the private process group created for Codex. Normal descendants inherit it and receive
`INT`, then `TERM`, then `KILL` before the launcher returns. A descendant that deliberately creates
a different process group or session falls outside that boundary. The launcher makes no broader
orphan-detection claim.

The plugin has no telemetry. Its broad `PreToolUse` hooks inspect Bash, Monitor, and Workflow call
text to prevent an accidental direct Codex launch and malformed runner calls. The
`PermissionRequest` hook is inert, so Claude Code's normal permission decision applies. A
`SessionStart` hook checks the platform and required binaries. No end-of-session reaper is installed
because runs are foreground and blocking.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) for the complete boundaries.

## Requirements

The project deliberately supports macOS only. It requires `codex` and a working `python3` on
`PATH`. Verify the CLI and sign-in before the first run:

```bash
codex --version
codex login status
```

Install Codex from [developers.openai.com/codex/cli](https://developers.openai.com/codex/cli/).
The plugin does not install it.

## Uninstall

Run `/codex-delegate:uninstall` before `claude plugin uninstall codex-delegate`. Because jobs are
blocking foreground calls, uninstall has no background run to reap. The command removes local run
artifacts and the obsolete permission rule that older releases may have installed.

## License

Apache-2.0. See [LICENSE](LICENSE).
