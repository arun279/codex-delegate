# Privacy

`codex-delegate` has no telemetry, analytics, crash reporting, or update check. It makes no network request on its own behalf.

## What leaves your machine

When you start a run, the plugin invokes the `codex` CLI you installed and signed in to. Codex sends your prompt and the files it reads to OpenAI under your account and their terms. This is the same network path used by a direct `codex exec` call.

The run also spends that signed-in account's quota. ChatGPT sign-in consumes the account or workspace's Codex allowance and credits; API-key sign-in creates usage billed to that API organization. Every parallel, repeated, or retried delegated run consumes usage independently. `codex-delegate` does not provide a separate quota, sponsor the request, or combine multiple runs into one charge.

The selected sandbox bounds local access:

- `read-only` cannot write project files;
- `workspace-write` can write the named cwd and added directories, while Codex's sandbox by its own default keeps their nested `.git`, `.agents`, and `.codex` paths read-only; an explicitly added Git directory is a separate writable root; and
- `danger-full-access` has no filesystem sandbox.

## What stays on your machine

Each run stores owner-only artifacts under `~/.codex-delegate/<runid>/`:

- `.codex-delegate-run`, the ownership marker used for retention;
- `pid`, the launcher's process id and advisory-lock wait handle;
- `prompt.txt`, containing the complete prompt;
- `events.jsonl`, containing the bounded Codex JSON event stream;
- `stderr.log`;
- `final.txt`, when Codex produces a final message; and
- `status.json`, the reduced terminal record.

The prompt reaches the Codex child through stdin and is not part of its process arguments. The runner constructs that stdin with a caller-shell heredoc, so same-user process inspection can still expose the shell command while it runs. This is not an end-to-end secrecy guarantee.

After a run reaches terminal status, the launcher retains the newest 100 (the `CODEX_DELEGATE_RUN_KEEP_LIMIT` default) inactive directories with a proven ownership marker and removes older proven runs, oldest marker mtime first. It never automatically removes a live run, an unmarked directory, a directory with a wrong, symlinked, non-regular, or foreign-owned marker, the run root itself, or anything outside that root. Pruning is best-effort and never changes a run result. There is no background pruning process; the user can still remove all artifacts or run `/codex-delegate:uninstall`. A launcher-created run root carries the standard `CACHEDIR.TAG` for backup tools. The launcher refuses a symlinked or differently owned run root, forces mode `0700`, and rejects writable-root overlap for `workspace-write`.

The plugin does not install a persistent Bash allow rule. Older releases could add `Bash(codex-delegate:*)` to user settings; upgrading does not silently remove that user-controlled entry.

## What the hooks see

The `PreToolUse` hooks inspect Bash, Monitor, and Workflow call text. They keep no state, open no sockets, and send nothing over the network. They deny statically recognizable direct Codex launches, empty runner prompts, and wrapper overrides; they do not validate dynamic envelope semantics. The configured `PermissionRequest` hook is inert. The `SubagentStop` hook reads the runner subagent's transcript locally and invokes the launcher's wait command; nothing it reads or invokes leaves the machine. The `SessionStart` hook inspects the platform, the required binaries, and `PATH` locally and sends nothing anywhere.

## Contact

Issues and security reports: <https://github.com/arun279/codex-delegate/issues>
