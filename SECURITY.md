# Security

## Reporting

Open a GitHub security advisory at <https://github.com/arun279/codex-delegate/security/advisories/new>, or an issue if the finding is not sensitive. There is no bounty.

## What this plugin is trusted with

It starts Codex on your machine with a sandbox you choose for each run. Its hooks read every Bash, Monitor, and Workflow call's text. Those are broad powers, so the boundaries are explicit.

## Stated limits

**The Bash guard stops accidents, not adversaries.** Shell is too expressive for a text classifier to be a security boundary. The corpus pins known command shapes, but an adversarial caller that can construct arbitrary shell already has the authority the hook is trying to mediate.

**Launcher state is separated from `workspace-write`.** The run root, cwd, and added writable roots are canonicalized. The launcher refuses any overlap in either direction and disables Codex's implicit temp and config-defined writable roots for that invocation. The run root is owner-only and may not be a symlink or traverse a swappable non-sticky ancestor.

**Git metadata is protected by default, with an explicit narrow opt-in.** Codex protects `.git` and a linked worktree's resolved Git directory beneath an existing writable root. A trusted caller can opt in by running `git rev-parse --path-format=absolute --git-common-dir` from the target worktree and passing that common Git directory as a separate writable root with `--add-dir`; that gives the delegated run write access to its shared objects and worktree metadata. The launcher always passes `--sandbox`, which does not compose with permission profiles.

**`danger-full-access` can alter local evidence.** Codex runs as the same user and can reach the run directory, final message, event file, and status path. The launcher writes status only after cleanup and derives the terminal event from bytes it consumed directly, but this is not attestation against a same-user process. Treat status from this sandbox as operational output.

**Process cleanup owns one private process group.** Codex and ordinary descendants inherit that group. On terminal event, deadline, HUP, INT, or TERM, the launcher sends INT, TERM, and then KILL as needed, waiting a short bounded grace after each for the group to disappear; a group still present after the whole ladder is reported as `CLEANUP_FAILED`. A descendant that deliberately creates another process group or session is outside this boundary, and so is every Codex process still running when the launcher is itself killed with KILL, because cleanup runs in the launcher. There is no PID ledger, historical reaper, or claim of system-wide orphan detection.

**Requested model identity is not service attestation.** The launcher validates the requested model and effort against Codex's live catalog. It cannot prove which model the service ultimately used.

## Design rule

Every check reads bytes written by something. A check over model-writable data is a diagnostic, not a security boundary. New checks must name who writes their input and what happens when it lies.
