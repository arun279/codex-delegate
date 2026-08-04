# Privacy

`codex-delegate` has no telemetry, analytics, crash reporting, or update check. It makes no network request on its own behalf.

## What leaves your machine

When you start a run, the plugin invokes the `codex` CLI you installed and signed in to. Codex sends your prompt and the files it reads to OpenAI under your account and their terms. This is the same network path used by a direct `codex exec` call.

The selected sandbox bounds local access:

- `read-only` cannot write project files;
- `workspace-write` can write the named cwd and added directories; and
- `danger-full-access` has no filesystem sandbox.

## What stays on your machine

Each run stores owner-only artifacts under `~/.codex-delegate/<runid>/`:

- `prompt.txt`, containing the complete prompt;
- `events.jsonl`, containing the bounded Codex JSON event stream;
- `stderr.log`;
- `final.txt`, when Codex produces a final message; and
- `status.json`, the reduced terminal record.

The prompt reaches the Codex child through stdin and is not part of its process arguments. The runner constructs that stdin with a caller-shell heredoc, so same-user process inspection can still expose the shell command while it runs. This is not an end-to-end secrecy guarantee.

Artifacts remain until the user removes them or runs `/codex-delegate:uninstall`; there is no background pruning process. The launcher refuses a symlinked or differently owned run root, forces mode `0700`, and rejects writable-root overlap for `workspace-write`.

The plugin does not install a persistent Bash allow rule. Older releases could add `Bash(codex-delegate:*)` to user settings; upgrading does not silently remove that user-controlled entry.

## What the hooks see

The `PreToolUse` hooks inspect Bash, Monitor, and Workflow call text. They keep no state, open no sockets, and send nothing over the network. One catches accidental direct Codex launches; the other checks runner call shape and wrapper overrides. The configured `PermissionRequest` hook is inert.

## Contact

Issues and security reports: <https://github.com/arun279/codex-delegate/issues>
