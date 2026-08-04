# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version in `.claude-plugin/plugin.json` is authoritative.

## [Unreleased]

### Added

- Recorded the launcher pid in the run directory, so a caller blocked past the harness's Bash ceiling can wait on the process instead of a clock.
- Added `scripts/runner-protocol-check.py` to the release gate. It executes the Bash `agents/runner.md` prescribes: three earlier wait prescriptions shipped without ever being run.

### Fixed

- Took the final message from the event stream the launcher already parses, so a message Codex emitted before cleanup terminated it is no longer discarded and reported as `OUTPUT_MISSING`.
- Held the runner alive across the harness's 600 second Bash ceiling, so a job the harness backgrounded is no longer destroyed and reported to the caller as progress.
- Ended that wait on the launcher process rather than on elapsed time, so a job that finishes early is returned at once and a launcher killed without publishing status is reported as a death instead of an empty success.
- Started the launcher as a background Bash call. A foreground call is handed off alive only for some command shapes, and measurably kills the launcher otherwise: a bare command reached the ceiling and was backgrounded, while the same command behind a variable assignment was killed at 600s and left `verdict STOPPED, exit_code 143`. Backgrounding also puts the wait on the path every run takes rather than only runs past ten minutes.
- Sized `maxTurns` so a wait call that loses its 600,000 ms timeout and dies at the 120 second default still cannot exhaust the budget before the deadline a run can reach.

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

[Unreleased]: https://github.com/arun279/codex-delegate/compare/codex-delegate--v0.1.1...HEAD
[0.1.1]: https://github.com/arun279/codex-delegate/releases/tag/codex-delegate--v0.1.1
