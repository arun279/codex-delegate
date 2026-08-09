# Security

## Reporting

Open a GitHub security advisory at <https://github.com/arun279/codex-delegate/security/advisories/new>, or an issue if the finding is not sensitive. There is no bounty.

## What this plugin is trusted with

It starts Codex on your machine with a sandbox you choose for each run. Its hooks read every Bash, Monitor, and Workflow call's text. Those are broad powers, so the boundaries are explicit.

## Pre-release review record

A defensive source review ran on 2026-08-07 across the launcher, runner envelope, routing skill, hooks, local storage, process lifecycle, manifests, npm and marketplace payloads, CI, and release workflow. It traced each external command, writable path, credential boundary, downloaded executable, signal path, and shipped claim. Automated support included the security, lifecycle, corpus, determinism, secret, privacy, package-content, manifest, publication-copy, and repository-push checks. No exploit was built; the review used source inspection and bounded negative cases.

Each finding asks whether the control covers the defect class, not one spelling:

- **SR-01: blocker, runner command boundary.** The current runner asks a model to reproduce the argument envelope and inserts that line into a shell command. The two text guards do not establish that every shell spelling is rejected on ambiguity. A fix must make the prompt and arguments data rather than generated shell, or fail closed for the whole grammar; blocking one substitution or one quote form is insufficient.
- **SR-02: documented boundary, parent-death lifecycle.** Cleanup covers HUP, INT, TERM, deadlines, terminal events, and ordinary descendants in one process group. It cannot run after the launcher receives KILL, so the Codex session can survive without a status owner. This is the same explicitly documented limit described in the README and below, not a promise of orphan detection after uncatchable launcher death.
- **SR-03: major, dependency compatibility.** Every run depends on the currently documented `codex debug models` catalog, while no minimum compatible Codex CLI version is declared or exercised against the real CLI. A fix must verify the supported CLI range end to end; checking only that a `codex` executable exists is insufficient.
- **SR-04: major, publication payload.** Marketplace installation still uses the Git repository because no release asset exists yet. That preserves a working install path but delivers development files with the runtime. Narrow delivery must not become live until its artifact exists and its install and update lifecycle is covered. CI does verify downloaded ShellCheck archives by published SHA-256, and the gate exercises repository-local push configuration before publication.
- **SR-05: documented boundary, same-user tampering.** Canonical paths, ownership checks, restrictive modes, exclusive file creation, and writable-root overlap checks protect launcher state from `workspace-write`. They do not protect it from `danger-full-access` or another process running as the same user, so status remains operational output rather than attestation.
- **SR-06: closed here, account and data disclosure.** Shipped copy now says that prompts and files read go to OpenAI and that every delegated run spends the signed-in user's ChatGPT Codex allowance or API-billed usage. Parallel runs are separate usage; the plugin provides no quota of its own.

SR-01 remains a pre-release blocker; SR-03 and SR-04 remain open major findings. SR-02 and SR-05 are documented boundaries. This review is a record of what was examined and found, not a claim that the unresolved boundaries are safe.

## Stated limits

**The Bash guard stops accidents, not adversaries.** Shell is too expressive for a text classifier to be a security boundary. The corpus pins known command shapes, but an adversarial caller that can construct arbitrary shell already has the authority the hook is trying to mediate.

**Launcher state is separated from `workspace-write`.** The run root, cwd, and added writable roots are canonicalized. The launcher refuses any overlap in either direction and disables Codex's implicit temp and config-defined writable roots for that invocation. The run root is owner-only and may not be a symlink or traverse a swappable non-sticky ancestor.

**Git metadata is protected by default, with an explicit narrow opt-in.** Codex protects `.git` and a linked worktree's resolved Git directory beneath an existing writable root. A trusted caller can opt in by running `git rev-parse --path-format=absolute --git-common-dir` from the target worktree and passing that common Git directory as a separate writable root with `--add-dir`; that gives the delegated run write access to its shared objects and worktree metadata. The launcher always passes `--sandbox`, which does not compose with permission profiles.

**`danger-full-access` can alter local evidence.** Codex runs as the same user and can reach the run directory, final message, event file, and status path. The launcher writes status only after cleanup and derives the terminal event from bytes it consumed directly, but this is not attestation against a same-user process. Treat status from this sandbox as operational output.

**Process cleanup owns one private process group.** Codex and ordinary descendants inherit that group. On terminal event, deadline, HUP, INT, or TERM, the launcher sends INT, TERM, and then KILL as needed, waiting a short bounded grace after each for the group to disappear; a group still present after the whole ladder is reported as `CLEANUP_FAILED`. A descendant that deliberately creates another process group or session is outside this boundary, and so is every Codex process still running when the launcher is itself killed with KILL, because cleanup runs in the launcher. There is no PID ledger, historical reaper, or claim of system-wide orphan detection.

**Requested model identity is not service attestation.** The launcher validates the requested model and effort against Codex's live catalog. It cannot prove which model the service ultimately used.

## Design rule

Every check reads bytes written by something. A check over model-writable data is a diagnostic, not a security boundary. New checks must name who writes their input and what happens when it lies.
