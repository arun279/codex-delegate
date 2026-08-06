# Changelog

<!-- markdownlint-disable MD024 -->

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version in `.claude-plugin/plugin.json` is authoritative.

## [Unreleased]

### Added

- Pinned both strict Claude manifest validations in the release gate and CI with a contract assertion.
- Pinned the launcher's isolated-startup preflight probe with a contract assertion.

### Changed

- Clarified the shared npm and plugin description with the exact launcher requirements, the plugin's broad hooks, and the npm tarball's launcher-only scope.
- Removed Lefthook pre-commit glob filters, since every command names its own repository inputs and the filters depended on an uninstalled matcher's semantics.

### Fixed

- Generated runner IDs in the launch shell and stripped their handoff header by content, so models cannot invent colliding IDs and header changes cannot leak into job output.
- Probed the launcher's exact `/usr/bin/env -S python3 -I -S` startup path during preflight, so unsupported environments report the failure before dispatch.

### Security

- Extended the dynamic-evaluation tripwire to cover dotted evaluation calls and `os` execution, shell, and process-spawn functions without flagging regular-expression compilation.

## [0.1.2] - 2026-08-05

### Added

- Recorded the launcher pid in the run directory, so a caller can wait on the process instead of a clock.
- Added `scripts/runner-protocol-check.py` to the release gate. It executes the Bash `agents/runner.md` prescribes: three earlier wait prescriptions shipped without ever being run.

### Security

- Replaced the shell launcher with a direct Python entry point that starts under `python3 -I -S`, so a module in the caller's working directory or on `PYTHONPATH` can no longer shadow a standard-library import the launcher makes. It now requires `/usr/bin/env` with `-S` support and a `python3` that honors `-I -S`; if those isolation flags are not active, the launcher prints a diagnostic and exits 2.

### Fixed

- Took the final message from the event stream the launcher already parses, so a message Codex emitted before cleanup terminated it is no longer discarded and reported as `OUTPUT_MISSING`.
- Held the runner alive across the harness's 600 second Bash ceiling, so a job the harness backgrounded is no longer destroyed and reported to the caller as progress.
- Ended that wait on the launcher process rather than on elapsed time, so a job that finishes early is returned at once and a launcher killed without publishing status is reported as a death instead of an empty success.
- Started the launcher as a background Bash call. A foreground call is handed off alive only for some command shapes, and measurably kills the launcher otherwise: a bare command reached the ceiling and was backgrounded, while the same command behind a variable assignment was killed at 600s and left `verdict STOPPED, exit_code 143`. Backgrounding also puts the wait on the path every run takes rather than only runs past ten minutes.
- Sized `maxTurns` so a wait call that loses its 600,000 ms timeout and dies at the 120 second default still cannot exhaust the budget before the deadline a run can reach.
- Corrected every shipped claim that dispatch from Claude Code is a single blocking call, including the published npm and marketplace copy, which no check had ever read. `scripts/claim-check.py` now reads that copy with the rest of the documentation and rejects the claim while the runner waits on the launcher. The npm, plugin, and marketplace descriptions are now one string the check requires all three to carry.
- Withdrew the promise that a run cannot outlive the agent that started it. Codex is started in its own session, so a launcher killed with `KILL` leaves it running: `tests/lifecycle.sh` now asserts that survival rather than quietly cleaning it up.
- Said what `--deadline` bounds. It starts when Codex starts, so a `--deadline 1` command measured 7 seconds of wall clock behind a 5 second catalog lookup, and the teardown ladder runs after it expires.
- Stopped describing process-group cleanup as unconditional. The ladder waits a bounded grace after each signal and reports `CLEANUP_FAILED` when the group is still there, which is why that verdict exists.
- Named the fourth thing that ends a direct `run`, which the README had left out: Codex exiting without a terminal event, which returns `NO_TERMINAL_EVENT` at once rather than waiting for the deadline.

## [0.1.1] - 2026-08-03

### Changed

- Reduced the public CLI to one blocking `run` command and the live `models` catalog.
- Made the foreground launcher own terminal-event detection, the wall-clock deadline, direct process-group cleanup, final-message output, and one 16-field status record.
- Required an explicit sandbox and a non-empty prompt for every run.
- Simplified catalog handling to live model listing, default selection, and exact pair validation.
- Kept prompt transport on stdin and owner-only run storage outside `workspace-write` roots.
- Kept the Bash and Workflow guards, inert permission hook, macOS preflight, corpus, privacy scan, deterministic suite, and release gates.

### Requirements and limits

- macOS only, with `codex` and Python 3 on `PATH`.
- Cleanup covers the private Codex process group. A descendant that creates another group or session is outside that boundary.
- `danger-full-access` status is operational output, not same-user tamper attestation.
- Requested model identity cannot attest which model the service ultimately used.

[Unreleased]: https://github.com/arun279/codex-delegate/compare/codex-delegate--v0.1.2...HEAD
[0.1.2]: https://github.com/arun279/codex-delegate/releases/tag/codex-delegate--v0.1.2
[0.1.1]: https://github.com/arun279/codex-delegate/releases/tag/codex-delegate--v0.1.1
