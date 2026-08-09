# Changelog

<!-- markdownlint-disable MD024 -->

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

No version of this project has been published. The first release number remains an owner decision, so every entry below stays under Unreleased. Entries describe the shipped product surface a plugin or launcher user would notice, not the gate, check, and CI machinery that produced it.

## [Unreleased]

### Added

- Added private process-group isolation for each Codex turn.
  <!-- evidence: bin/codex-delegate :: start_new_session=True -->
- Added terminal-event capture that ends a process which does not exit by itself.
  <!-- evidence: tests/lifecycle.sh :: first terminal event wins even when Codex does not exit -->
- Added a bounded deadline and cleanup ladder for the inherited Codex process group.
  <!-- evidence: tests/lifecycle.sh :: deadline kills the complete inherited process group -->
- Added a reduced 16-field status record.
  <!-- evidence: tests/run.sh :: status has exactly the reduced 16-field schema -->

### Changed

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

- Ended a pre-run-ID wait on a dead recorded launcher or a bounded startup grace, instead of on elapsed time.
  <!-- evidence: bin/codex-delegate :: def runner_wait(output_path: str) -->
- Enforced the deadline during prompt ingestion and while Codex keeps stdout productive, where it previously did neither.
  <!-- evidence: bin/codex-delegate :: class PromptDeadline -->
- Kept draining Codex stdout through a bounded post-terminal settlement, so an intact native final-output document is no longer lost.
  <!-- evidence: tests/lifecycle.sh :: post-terminal settlement keeps draining -->
- Published a terminal status record for a prompt failure that happens after the run directory is allocated.
  <!-- evidence: tests/run.sh :: a missing prompt file records a terminal validation failure before Codex starts -->
- Coupled the documented prompt-file validation exit to the launcher's actual return path.
  <!-- evidence: README.md :: path validation exits 2 -->

### Security

- Rejected `workspace-write` runs whose writable roots overlap the owner-only run store.
  <!-- evidence: tests/run.sh :: workspace-write cannot overlap launcher control state -->

[Unreleased]: https://github.com/arun279/codex-delegate/commits/main
