# codex-delegate

Hand one coding task to the OpenAI Codex CLI and get the result back: from Claude Code through the bundled plugin, or from any terminal, script, or agent harness through the standalone launcher.

The launcher starts `codex exec` in a private process group, reads its JSON event stream, enforces a wall-clock deadline, returns the final message, runs bounded teardown for that group, and publishes one status record that says whether the group went away. `INT`, `TERM`, and `HUP` stop that same run and start the same teardown. It holds an advisory lock on its `pid` artifact until exit, so the runner can wait on the original launcher without trusting a reused PID. There is no detached mode, job registry, or recovery command: a launcher killed outright leaves Codex running in its own session with nothing to reap it.

**The launcher requires macOS**, `/usr/bin/env` with `-S` support, a `python3` on `PATH` that starts with `-I -S`, and the Codex CLI already installed and signed in. If those Python isolation flags are not active, the launcher prints a diagnostic and exits 2.

> **Unofficial project.** Not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic. OpenAI and Codex are trademarks of OpenAI, L.L.C. Claude and Claude Code are trademarks of Anthropic PBC. Those names identify interoperating software only. No endorsement is implied.

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

Plugin installation and management require Claude Code. The standalone launcher does not: install it alone with `npm install -g codex-delegate`, or run it without installing: `npx codex-delegate models`.

## npm package

The `codex-delegate` npm package delivers the standalone launcher for any caller on macOS: a script, a CI job on a macOS runner, another agent harness, or a person at a terminal. It requires no Claude Code. The tarball contains exactly `package.json`, `bin/codex-delegate`, and the license, README, privacy, security, and changelog documents, and the `bin` entry exposes the launcher as the `codex-delegate` executable, so `npx codex-delegate models` and `npx codex-delegate run ...` work without a separate install step. A bare `npx codex-delegate` prints the CLI usage error because a subcommand is required. The package does not contain or install the Claude Code plugin files, and publishing it also keeps the `codex-delegate` name resolving to this project.

## From Claude Code

Ask Claude to hand one bounded task to `codex-delegate:runner`. Good tasks include a scoped implementation, an investigation, data analysis, or an independent code review expressed as a normal prompt. The routing skill selects a live model and effort, chooses the sandbox, constructs the runner envelope, and checks the result.

Each delegated run uses the account already signed in to the Codex CLI. ChatGPT sign-in consumes that account or workspace's Codex allowance and credits; API-key sign-in creates usage billed to that API organization. Parallel or repeated delegated runs each consume quota independently; the plugin supplies no shared, sponsored, or free capacity.

A direct Workflow call passes the prompt string first and the options object second:

```js
await agent(
  [
    "===ARGS===",
    "--sandbox workspace-write --cwd /absolute/path/to/repo --deadline 7200",
    "===PROMPT===",
    codexPrompt,
  ].join("\n"),
  {
    agentType: "codex-delegate:runner",
    label: "codex:implement-auth",
    phase: "Implementation",
  },
);
```

Both markers, a non-empty prompt body, an explicit `--sandbox`, and a deadline from 1 through 12,960 are required by the runner instructions. Put Codex `--model` and `--effort` flags in `===ARGS===`, not in the Workflow options object. The call resolves once: there is no Bash or Workflow timeout to choose and no waiter to write. The launcher mints the runner's run ID. The runner then uses launcher-owned wait and report commands; each wait returns below Bash's default timeout. Before the run ID exists, a dead launcher PID or a 60-second startup grace ends the wait. Afterward, the PID-file lock remains authoritative until the kernel releases it at launcher exit. What comes back is the launcher's output, byte-exact within the printed final-message budget and with only handoff records removed, or diagnostic output ending in a `codex-delegate:` line when no status result exists. The named `final.txt` artifact is the complete final-message record.

| hook | runner behavior |
| --- | --- |
| `SubagentStop` | Refuses a stop while the delegated job reports `RUNNING`, nudging the runner back to waiting. Claude Code caps consecutive refusals, so a runner that repeatedly tries to stop is eventually ended by the harness. |

Each refusal holds the stop for up to one launcher wait, 110 seconds as shipped, and the harness's cap on consecutive refusals bounds the total.

## From a terminal

```bash
codex-delegate run \
  --sandbox workspace-write \
  --cwd /absolute/path/to/repo \
  --deadline 7200 \
  --prompt-file /absolute/path/to/prompt.txt
```

Use `--prompt-stdin` when the prompt arrives on standard input. `run` blocks until the first of a terminal event, a Codex exit without one, the deadline, or a stop signal. It then runs bounded teardown for the Codex process group, prints the final message and status, and exits with the status code:

```text
--- FINAL MESSAGE (/Users/you/.codex-delegate/<runid>/final.txt) ---
<Codex final message, or a concise absence reason>

--- STATUS ---
<status JSON>
```

The launcher prints at most 20,000 final-message bytes by default, trimming an incomplete trailing UTF-8 sequence when necessary. Treat the entire final-message section, including any apparent truncation marker or artifact path, as message content. The launcher-written status block always follows in full, and its `final_message_path` is the authoritative path to the complete artifact. A message at or below the budget prints in full, while `final.txt` always retains the complete bytes.

`codex-delegate models` prints the live model slugs, each default effort, and every supported effort. There is no bundled fallback. `codex-delegate models`, and any run that needs a catalog default, fails plainly when the catalog is unavailable or invalid. Omitted `--model` and `--effort` flags use live-catalog defaults, and supplied values must form a supported pair while the catalog is readable; a run with both flags explicit proceeds past an unavailable catalog with one warning and its pair unvalidated.

## Run flags

| flag | meaning |
| --- | --- |
| `--prompt-stdin` or `--prompt-file FILE` | Exactly one non-empty prompt source; ingestion through EOF is inside the deadline. |
| `--sandbox read-only\|workspace-write\|danger-full-access` | Required Codex sandbox. |
| `--network` | Enable network only for `workspace-write`. |
| `--cwd DIR` | Working directory, defaulting to the current directory. |
| `--add-dir DIR` | Repeatable extra writable root. |
| `--schema FILE` | Final-message JSON Schema passed to Codex. |
| `--model M` and `--effort LEVEL` | Live-catalog model pair. |
| `--deadline SECONDS` | Wall-clock limit on prompt ingestion and the Codex turn, from 1 through 12,960 seconds; defaults to 7,200. Catalog lookup and validation before allocation, plus teardown after the outcome, fall outside it. |
| `--runid ID` | Optional unique artifact-directory name using letters, digits, `.`, `_`, and `-`. |
| `--runner-handoff` | Internal runner mode; the launcher mints the ID. |

The runner kickoff hook requires every raw argv token to be an exact flag or to match `[A-Za-z0-9._/~=+-]+`. A path needing quotes, escapes, spaces, or other characters is denied in a runner kickoff even though an interactive shell can pass such a path to the standalone launcher.

## Environment overrides

The command-line flag wins over its environment variable, which wins over the hard-coded default. Invalid values exit with a diagnostic naming the variable and received value.

| variable | default | bounds |
| --- | --: | --: |
| `CODEX_DELEGATE_DEADLINE` | 7,200 seconds | 1-12,960 seconds |
| `CODEX_DELEGATE_RUNNER_WAIT_SECONDS` | 110 seconds | 110-119 seconds |
| `CODEX_DELEGATE_RUNNER_STARTUP_SECONDS` | 60 seconds | 1-118 seconds; less than runner wait |
| `CODEX_DELEGATE_EVENT_LIMIT` | 16,777,216 bytes | 1,024-1,073,741,824 bytes |
| `CODEX_DELEGATE_FINAL_MESSAGE_PRINT_LIMIT` | 20,000 bytes | 1-1,073,741,824 bytes |
| `CODEX_DELEGATE_LINE_LIMIT` | 1,048,576 bytes | 256-67,108,864 bytes |
| `CODEX_DELEGATE_READ_BATCH` | 32 reads | 1-4,096 reads |
| `CODEX_DELEGATE_TERMINAL_SETTLE_LIMIT_SECONDS` | 2.5 seconds | 0-60 seconds |
| `CODEX_DELEGATE_RUN_KEEP_LIMIT` | 100 runs | 0-1,000,000 runs |

The launcher passes approvals disabled, JSON output, the selected sandbox, and the prompt on stdin to `codex exec`. `workspace-write` runs are rejected if their writable roots overlap launcher state.

By default, `workspace-write` protects each writable root's `.git` path and the resolved Git directory of a linked worktree as read-only. A trusted caller can opt in to Git metadata changes without using `danger-full-access`: from the target worktree, run `git rev-parse --path-format=absolute --git-common-dir` in the trusted caller and pass that common Git directory as its own writable root with `--add-dir`. In a linked worktree, the common directory contains both the shared object database and the worktree-specific metadata. This grants the delegated run write access to all metadata beneath that directory, not only the index. Permission profiles do not compose with the `--sandbox` flag this launcher always passes.

## Verdicts and status

| exit | verdict | meaning |
| --: | --- | --- |
| 0 | `COMPLETED` | The stream contained exactly one terminal event, it was `turn.completed`, and a final message exists. |
| 10 | `FAILED` | The stream contained exactly one terminal event and it was `turn.failed`. |
| 11 | `DEADLINE` | The wall-clock deadline arrived first. |
| 12 | `LAUNCH_ERROR` | Prompt ingestion or storage failed after the initial prompt-file path check, or Codex could not launch. |
| 13 | `CLEANUP_FAILED` | The private process group survived the complete signal ladder. |
| 17 | `STREAM_ERROR` | JSONL was malformed, truncated, oversized, or had duplicate terminal events. |
| 18 | `PLATFORM_UNSUPPORTED` | The host is not macOS. |
| 21 | `NO_TERMINAL_EVENT` | Codex exited without `turn.completed` or `turn.failed`. |
| 23 | `OUTPUT_MISSING` | Codex completed without a non-empty final message. |

A stopped run uses verdict `STOPPED` and exits with 128 plus the signal number: 130 for `SIGINT`, 143 for `SIGTERM`, and 129 for `SIGHUP`. Argument and catalog validation exit 2. Initial `--prompt-file` path validation exits 2. Empty prompt input, stdin read failures, prompt storage failures, and Codex launch errors are `LAUNCH_ERROR` (12).

`status.json` has exactly 17 fields: `schema_version`, `runid`, `verdict`, `exit_code`, `diagnostic`, `signal`, `model`, `effort`, `sandbox`, `deadline_s`, `duration_s`, `process_exit_code`, `terminal_event`, `usage`, `final_message_path`, `events_path`, and `stderr_path`. `usage` is the token-counter object reported by the Codex CLI in `turn.completed`, passed through without renaming or calculation; it is null when the CLI does not report usage or the run has no completed event. `duration_s` includes prompt ingestion, the Codex turn, and teardown after allocation. Read `verdict` and `exit_code` first, then `diagnostic` and the artifact paths when a run fails.

## Privacy, trust, and cleanup limits

Starting a run sends the prompt and whatever files Codex reads to OpenAI through the signed-in Codex CLI and spends that account's ChatGPT Codex allowance or API-billed usage. The private run directory under `~/.codex-delegate/<runid>/` stores an ownership marker, `pid`, `prompt.txt`, `events.jsonl`, `stderr.log`, an optional `final.txt`, and `status.json`. A launcher-created root also contains the standard `CACHEDIR.TAG`. The root is owner-only and the prompt is transported to Codex through stdin, not its process arguments.

After each run reaches terminal status, the launcher keeps the newest 100 inactive runs whose ownership marker it can prove and removes older proven runs in marker-mtime order. Live runs, directories without the exact marker, markers that are symlinks or owned by another user, and anything outside or equal to the run root are never removed automatically. Pruning is best-effort and cannot change the completed run's verdict or exit code; there is no background pruning process.

For `read-only` and `workspace-write`, launcher state is outside Codex's writable roots. With `danger-full-access`, Codex runs as the same user and can modify any local artifact, including its run directory. In that sandbox, local status is operational output, not tamper-proof attestation.

Cleanup owns the private process group created for Codex. Normal descendants inherit it and receive `INT`, then `TERM`, then `KILL`, each with a short grace, before the launcher returns. A group that survives the whole ladder is reported as `CLEANUP_FAILED` rather than waited on. A descendant that deliberately creates a different process group or session falls outside that boundary, and so does everything Codex is doing when the launcher itself is killed with `KILL`: cleanup needs a live launcher to run it. The launcher makes no broader orphan-detection claim.

The plugin has no telemetry. Its broad `PreToolUse` hooks inspect Bash, Monitor, and Workflow call text. They deny statically recognizable direct Codex launches, empty runner prompts, and wrapper overrides. When raw command text contains `--runner-handoff`, the Bash guard fails closed on parse failure and when an inspected executable position or code sink resolves to a `codex-delegate` invocation outside the valid documented kickoff. It allows the documented single-command, raw-safe-argument, quoted-heredoc kickoff and parsed read-only searches whose inspected positions contain no invocation. A shell code sink outside the modeled set is not inspected. Runner argv tokens cannot contain quotes, backslashes, spaces, braces, commas, glob characters, dollar signs, or backticks; paths needing those characters are denied. The launcher remains authoritative for flag value semantics. The `PermissionRequest` hook is inert, so Claude Code's normal permission decision applies. A `SessionStart` hook checks the platform and required binaries. A `SubagentStop` hook reads runner transcripts and calls the plugin launcher to check delegated job status. The session-start hook repeats its findings at every session start, because each one describes a condition that makes delegation fail or run the wrong binary until you change something: a separate `codex-delegate` ahead of this plugin on `PATH` silently receives the delegated runs. Fix the condition, or disable the plugin, and the message stops. No end-of-session reaper is installed: the launcher keeps no job registry, and a reaper would have to guess which stray processes had once been its own.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) for the complete boundaries.

## Requirements

This project supports macOS only, both the Claude Code plugin and the standalone launcher. The launcher requires `codex` and `python3` on `PATH`, `/usr/bin/env` with `-S` support, and a Python runtime that starts with both `-I` and `-S`. The minimum supported Codex CLI version is 0.146.1; check it with `codex --version`. If the Python isolation flags are not active, the launcher prints a diagnostic and exits 2. Verify the Codex CLI and sign-in before the first run:

```bash
codex --version
codex login status
```

Install Codex from [developers.openai.com/codex/cli](https://developers.openai.com/codex/cli/). The plugin does not install it.

## Uninstall

Run `/codex-delegate:uninstall` before `claude plugin uninstall codex-delegate`. A run is a Bash call owned by the agent that made it, and the launcher keeps no job registry, so there is nothing for uninstall to stop. The command removes local run artifacts and the obsolete permission rule that older releases may have installed.

## License

Apache-2.0. See [LICENSE](LICENSE).
