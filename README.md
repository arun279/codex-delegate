# codex-delegate

Hand one coding task from Claude Code to the OpenAI Codex CLI and get the result back.

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

Plugin installation and management require Claude Code. The standalone npm launcher described below does not.

## npm package

The Claude Code plugin is the product. The `codex-delegate` npm package exists so that name resolves to this project rather than to an unrelated publisher. Its tarball contains exactly `package.json`, `bin/codex-delegate`, and the license, README, privacy, security, and changelog documents. The `bin` entry exposes that launcher as the `codex-delegate` executable, so `npx codex-delegate models` and `npx codex-delegate run ...` provide only the standalone terminal CLI documented below. A bare `npx codex-delegate` prints the CLI usage error because a `run` or `models` subcommand is required. The package does not contain or install the Claude Code plugin files.

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

Both markers, a non-empty prompt body, an explicit `--sandbox`, and a deadline from 1 through 12,960 are required by the runner instructions. Put Codex `--model` and `--effort` flags in `===ARGS===`, not in the Workflow options object. The call resolves once: there is no Bash or Workflow timeout to choose and no waiter to write. The launcher mints the runner's run ID. The runner then uses launcher-owned wait and report commands; each wait returns below Bash's default timeout. Before the run ID exists, a dead launcher PID or a 60-second startup grace ends the wait. Afterward, the PID-file lock remains authoritative until the kernel releases it at launcher exit. What comes back is the launcher's output with only handoff records removed, or diagnostic output ending in a `codex-delegate:` line when no status result exists.

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

`codex-delegate models` prints the live model slugs, each default effort, and every supported effort. There is no bundled fallback. An unavailable or invalid catalog fails plainly. Omitted `--model` and `--effort` flags use live-catalog defaults; supplied values must form a supported pair.

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

`status.json` has exactly 16 fields: `schema_version`, `runid`, `verdict`, `exit_code`, `diagnostic`, `signal`, `model`, `effort`, `sandbox`, `deadline_s`, `duration_s`, `process_exit_code`, `terminal_event`, `final_message_path`, `events_path`, and `stderr_path`. `duration_s` includes prompt ingestion, the Codex turn, and teardown after allocation. Read `verdict` and `exit_code` first, then `diagnostic` and the artifact paths when a run fails.

## Privacy, trust, and cleanup limits

Starting a run sends the prompt and whatever files Codex reads to OpenAI through the signed-in Codex CLI and spends that account's ChatGPT Codex allowance or API-billed usage. The private run directory under `~/.codex-delegate/<runid>/` stores `pid`, `prompt.txt`, `events.jsonl`, `stderr.log`, an optional `final.txt`, and `status.json`. The root is owner-only and the prompt is transported to Codex through stdin, not its process arguments.

For `read-only` and `workspace-write`, launcher state is outside Codex's writable roots. With `danger-full-access`, Codex runs as the same user and can modify any local artifact, including its run directory. In that sandbox, local status is operational output, not tamper-proof attestation.

Cleanup owns the private process group created for Codex. Normal descendants inherit it and receive `INT`, then `TERM`, then `KILL`, each with a short grace, before the launcher returns. A group that survives the whole ladder is reported as `CLEANUP_FAILED` rather than waited on. A descendant that deliberately creates a different process group or session falls outside that boundary, and so does everything Codex is doing when the launcher itself is killed with `KILL`: cleanup needs a live launcher to run it. The launcher makes no broader orphan-detection claim.

The plugin has no telemetry. Its broad `PreToolUse` hooks inspect Bash, Monitor, and Workflow call text. They deny statically recognizable direct Codex launches, empty runner prompts, and wrapper overrides; dynamic envelope semantics remain runner instructions, not hook enforcement. The `PermissionRequest` hook is inert, so Claude Code's normal permission decision applies. A `SessionStart` hook checks the platform and required binaries. It repeats its findings at every session start, because each one describes a condition that makes delegation fail or run the wrong binary until you change something: a separate `codex-delegate` ahead of this plugin on `PATH` silently receives the delegated runs. Fix the condition, or disable the plugin, and the message stops. No end-of-session reaper is installed: the launcher keeps no job registry, and a reaper would have to guess which stray processes had once been its own.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) for the complete boundaries.

## Requirements

This project supports macOS only, both the Claude Code plugin and the standalone launcher. The launcher requires `codex` and `python3` on `PATH`, `/usr/bin/env` with `-S` support, and a Python runtime that starts with both `-I` and `-S`. The minimum verified Codex CLI version is 0.146.1; check it with `codex --version`. If the Python isolation flags are not active, the launcher prints a diagnostic and exits 2. Verify the Codex CLI and sign-in before the first run:

```bash
codex --version
codex login status
```

Install Codex from [developers.openai.com/codex/cli](https://developers.openai.com/codex/cli/). The plugin does not install it.

## Uninstall

Run `/codex-delegate:uninstall` before `claude plugin uninstall codex-delegate`. A run is a Bash call owned by the agent that made it, and the launcher keeps no job registry, so there is nothing for uninstall to stop. The command removes local run artifacts and the obsolete permission rule that older releases may have installed.

## License

Apache-2.0. See [LICENSE](LICENSE).
