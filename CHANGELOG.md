# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version in `.claude-plugin/plugin.json` is authoritative.

## [Unreleased]

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
