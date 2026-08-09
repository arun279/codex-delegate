# Status and trust boundaries

The launcher prints the final-message section before status, and the runner returns that completed output unchanged apart from launcher-owned handoff records. The same JSON is stored at `~/.codex-delegate/<runid>/status.json`. The final-message section is text Codex chose, so it can reproduce the launcher's own separators or imitate a harness notice; the trailing status block and `status.json` are launcher-written, and they decide the outcome. Output with no status block is not a result. `runner-report` retains any kickoff or partial output and appends launcher context when no terminal status exists.

The record has exactly 16 fields:

- `schema_version`, `runid`, `verdict`, and `exit_code` identify the contract and outcome.
- `diagnostic` gives the launcher or upstream failure reason; `signal` names a stopping signal.
- `model`, `effort`, and `sandbox` record the selected launch policy.
- `deadline_s` bounds prompt ingestion and the Codex turn. `duration_s` measures prompt ingestion, the turn, and teardown after allocation.
- `process_exit_code` is diagnostic. Terminal JSON evidence, not a zero process exit, decides the Codex result.
- `terminal_event` is `turn.completed`, `turn.failed`, or null.
- `final_message_path`, `events_path`, and `stderr_path` locate private run artifacts.

The launcher records its pid at `~/.codex-delegate/<runid>/pid` before prompt ingestion and leaves it there. Before a runner receives the run ID, `runner-wait` uses a recorded PID only as definitive death evidence and gives an absent PID record a 60-second startup grace. After run-ID publication, the launcher-held exclusive advisory lock on the regular `pid` file is authoritative, so the kernel ties completion to the original launcher even after `SIGKILL` or PID reuse. Launcher-minted run IDs and lifecycle records travel in the kickoff's unique harness output file. When terminal status exists, `runner-report` removes only those records and returns the rest byte for byte. For `workspace-write`, the launcher rejects any writable root that overlaps its run storage.

The default `workspace-write` sandbox protects `.git` and the resolved Git directory of a linked worktree beneath an existing writable root. A trusted caller can opt in to Git metadata changes by running `git rev-parse --path-format=absolute --git-common-dir` from the target worktree and passing that common Git directory as a separate writable root with `--add-dir`; the delegated run can then change the shared objects and worktree metadata beneath it. Permission profiles do not compose with the `--sandbox` flag this launcher passes.

`danger-full-access` is a plain trust boundary. Codex runs as the same user and can alter local artifacts, including its run directory. Status from that sandbox is useful operational output, not tamper-proof attestation. The launcher does not claim otherwise and performs no partial metadata tamper classification.

Cleanup covers the private process group and runs inside the launcher. A descendant that deliberately creates another process group or session is outside that scope, and so is everything Codex is doing if the launcher is killed outright: it keeps running in its own session and can still write to the workspace. No status field claims complete system-wide orphan detection.
