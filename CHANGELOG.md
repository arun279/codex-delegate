# Changelog

<!-- markdownlint-disable MD024 -->

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Entries describe the shipped product surface a plugin or launcher user would notice, not the development machinery that produced it. A change stays under Unreleased until the release that ships it.

## [Unreleased]

## [0.2.1] - 2026-08-16

### Changed

- Described the launcher as one tool with two delivery channels: the Claude Code plugin wraps it, and the npm package delivers the terminal CLI to any macOS caller with no Claude Code required.
  <!-- evidence: README.md :: delivers the standalone launcher for any caller -->

## [0.2.0] - 2026-08-16

### Added

- Added graceful runner stop protection: a `SubagentStop` hook refuses a stop while the delegated job reports `RUNNING`, returning the runner to waiting. The harness caps consecutive refusals, so a runner that keeps trying to stop is eventually ended.
  <!-- evidence: tests/checks.sh :: a RUNNING launcher blocks the runner stop with the corrective wait instruction -->
- Added ownership-proven retention that keeps the newest 100 inactive runs while never automatically removing live or unproven directories.
  <!-- evidence: tests/run.sh :: limit zero silently preserves every unproven directory and directory symlink -->
- Added bounded environment overrides for launcher timing and buffering tunables, with command-line deadline precedence.
  <!-- evidence: tests/run.sh :: the deadline flag wins over its environment variable -->

- Added a non-blocking session-start check that warns when the installed Codex CLI is below the minimum verified version.
  <!-- evidence: tests/checks.sh :: a Codex CLI below the verified floor produces a warning -->

- Added private process-group isolation for each Codex turn.
  <!-- evidence: bin/codex-delegate :: start_new_session=True -->
- Added terminal-event capture that ends a process which does not exit by itself.
  <!-- evidence: tests/lifecycle.sh :: first terminal event wins even when Codex does not exit -->
- Added a bounded deadline and cleanup ladder for the inherited Codex process group.
  <!-- evidence: tests/lifecycle.sh :: deadline kills the complete inherited process group -->
- Added a reduced 17-field status record, including Codex CLI-reported token usage when available.
  <!-- evidence: tests/run.sh :: Codex CLI usage counters pass through unchanged -->

### Changed

- Simplified launcher and hook internals with identical observable behavior: the same verdicts, diagnostics, exit codes, and status fields.
  <!-- evidence: tests/runner-handoff.sh :: "$name report is the launcher output without handoff records" -->
- Capped the printed final-message section at a bounded, configurable byte budget while preserving complete artifacts and the full status block.
  <!-- evidence: tests/run.sh :: an over-budget final message prints the bounded head and exact omission marker -->
- Reformatted the source to a 150-column line length with no behavioural change.
  <!-- evidence: bin/codex-delegate :: "MIN_DEADLINE": FixedNumber(1, "The minimum deadline stays fixed because the public runner contract promises it."), -->

- Clarified delegated account usage, release prerequisites, runner timing, and shipped hook behavior.
  <!-- evidence: skills/routing/SKILL.md :: The plugin supplies no shared or sponsored capacity. -->
- Split concise package and marketplace listing cards from the complete disclosures in the documentation.
  <!-- evidence: .claude-plugin/plugin.json :: Codex CLI delegation. PreToolUse hooks read every Bash -->
- Reworked the PATH-mismatch banner to give proportional guidance for either intended installation.
  <!-- evidence: hooks/preflight.sh :: If you intend to use the separate copy instead, disable this plugin. -->
- Required the launcher to start with `python3 -I -S`, preventing caller-controlled Python import paths and site initialization.
  <!-- evidence: tests/security.sh :: #!/usr/bin/env -S python3 -I -S -->
- Disclosed that every delegated run spends the signed-in user's ChatGPT Codex allowance or API-billed usage.
  <!-- evidence: PRIVACY.md :: Every parallel, repeated, or retried delegated run consumes usage independently. -->
- Documented the default `workspace-write` protection for Git directories and the narrower `--add-dir` opt-in that lets a trusted caller allow Git metadata changes.
  <!-- evidence: README.md :: pass that common Git directory as its own writable root with -->
- Corrected the shipped hook, terminal-event, teardown and runner-validation claims to match what the code actually enforces.
  <!-- evidence: README.md :: runs bounded teardown for that group, and publishes one status record -->
- Moved run-ID generation out of the model and into the launcher, and replaced the inline wait and report with bounded launcher commands.
  <!-- evidence: agents/runner.md :: makes the launcher mint the run ID -->

### Fixed

- Allowed fully explicit model-effort runs to continue with a warning when the live model catalog is unavailable.
  <!-- evidence: tests/run.sh :: an explicit pair proceeds with one warning when the catalog is unavailable -->
- Ended a pre-run-ID wait on a dead recorded launcher or a bounded startup grace, instead of on elapsed time.
  <!-- evidence: bin/codex-delegate :: def runner_wait(output_path: str, tunables: ResolvedTunables) -->
- Enforced the deadline during prompt ingestion and while Codex keeps stdout productive, where it previously did neither.
  <!-- evidence: bin/codex-delegate :: class PromptDeadline -->
- Kept draining Codex stdout through the full bounded post-terminal settlement, so a late native final-output document is still collected.
  <!-- evidence: tests/run.sh :: a native document arriving one second after the terminal event is collected -->
- Validated the initial prompt-file path before allocating a run or publishing a status record.
  <!-- evidence: tests/run.sh :: a missing prompt file fails validation before allocating a run -->
- Coupled the documented prompt-file validation exit to the launcher's actual return path.
  <!-- evidence: README.md :: path validation exits 2 -->

### Security

- Denied the `codex e` exec alias and the standalone `codex exec-server` service as direct Codex launches, with the alias keeping `exec`'s approval-prompt exception.
  <!-- evidence: tests/checks.sh :: the exec alias starts a turn and is denied -->
- Added a fail-closed validator for the documented runner kickoff shell shape and flag allowlist, with raw argv tokens restricted to letters, digits, `.`, `_`, `/`, `~`, `=`, `+`, and `-`. Parsed commands stay allowed when the inspected executable positions and code sinks contain no runner invocation. The launcher remains authoritative for flag value semantics.
  <!-- evidence: tests/checks.sh :: a runner kickoff in a trap handler is denied -->
- Rejected `workspace-write` runs whose writable roots overlap the owner-only run store.
  <!-- evidence: tests/run.sh :: workspace-write cannot overlap launcher control state -->

[Unreleased]: https://github.com/arun279/codex-delegate/compare/v0.2.1...main
[0.2.1]: https://github.com/arun279/codex-delegate/releases/tag/v0.2.1
[0.2.0]: https://github.com/arun279/codex-delegate/releases/tag/v0.2.0
