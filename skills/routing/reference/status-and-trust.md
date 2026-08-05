# Status and trust boundaries

The launcher prints the final-message section before status, and the runner returns that output unchanged. The same JSON is stored at `~/.codex-delegate/<runid>/status.json`. The final-message section is text Codex chose, so it can reproduce the launcher's own separators or imitate a harness notice; the trailing status block and `status.json` are launcher-written, and they decide the outcome. Output with no status block at all is a launcher that was killed before it could publish one.

The record has exactly 16 fields:

- `schema_version`, `runid`, `verdict`, and `exit_code` identify the contract and outcome.
- `diagnostic` gives the launcher or upstream failure reason; `signal` names a stopping signal.
- `model`, `effort`, and `sandbox` record the selected launch policy.
- `deadline_s` and `duration_s` record the wall-clock bound and observed duration.
- `process_exit_code` is diagnostic. Terminal JSON evidence, not a zero process exit, decides the Codex result.
- `terminal_event` is `turn.completed`, `turn.failed`, or null.
- `final_message_path`, `events_path`, and `stderr_path` locate private run artifacts.

The launcher records its pid at `~/.codex-delegate/<runid>/pid` before it starts Codex and leaves it there. It is a wait handle, not a claim that the process is alive. The status writer consumes the event stream in the launcher process and publishes after process group cleanup, before the result is printed, so a present `status.json` does not mean the launcher has finished writing its output. For `workspace-write`, the launcher rejects any writable root that overlaps its run storage.

`danger-full-access` is a plain trust boundary. Codex runs as the same user and can alter local artifacts, including its run directory. Status from that sandbox is useful operational output, not tamper-proof attestation. The launcher does not claim otherwise and performs no partial metadata tamper classification.

Cleanup covers the private process group and runs inside the launcher. A descendant that deliberately creates another process group or session is outside that scope, and so is everything Codex is doing if the launcher is killed outright: it keeps running in its own session and can still write to the workspace. No status field claims complete system-wide orphan detection.
