---
name: routing
description: Route bounded coding, investigation, analysis, and independent review tasks to Codex CLI with a live-catalog model and effort.
---

# Codex

Use `codex-delegate:runner` to send exactly one bounded job to Codex. Decide whether to delegate, choose the Codex model and effort, supply a self-contained prompt, and judge the result. The runner owns the launcher call and the wait on it. Never run `codex exec` directly.

## Route the work

Send Codex:

- bulk or mechanical implementation against a clear specification;
- independent code review expressed as a normal task prompt;
- bounded investigation or data analysis that would consume substantial context; and
- a focused reproduction or test-writing task with objective acceptance criteria.

Keep work here when taste drives the result, the check is quicker to do directly, or the task cannot be stated without hidden conversational context. Split unrelated substantial changes into separate calls.

## Choose model and effort

Run `codex-delegate models` for live model slugs, defaults, and supported effort levels. The command has no fallback catalog, so failure means model selection is unavailable and the job must not start.

- Use a lower-cost visible model and lower-half effort for deterministic edits or narrow facts.
- Use a higher-priority general model and middle or upper effort for cross-component changes, ambiguous debugging, or substantive review.
- Use upper-half effort when a miss is expensive, such as concurrency, architecture, security, or a destructive migration.
- Prefer a purpose-built review model when the live catalog offers one.

Name both `--model` and `--effort` when selection must be explicit. If either is omitted, the live catalog supplies that default. Environment variables do not override the pair.

## Make the call exactly this way

The Workflow signature is `agent(prompt: string, opts?: {label?, phase?, schema?, model?, effort?, isolation?, agentType?})`. The prompt string is argument one and the options object is argument two.

```js
await agent(
  [
    "===ARGS===",
    "--sandbox workspace-write --cwd /abs/path --deadline 7200 --model <slug> --effort <level>",
    "===PROMPT===",
    promptBody,
  ].join("\n"),
  {
    agentType: "codex-delegate:runner",
    label: "codex:short-purpose",
    phase: "PhaseName",
  },
);
```

- Keep the `codex:` label prefix.
- Never pass `model:`, `effort:`, or `tools:` in `agent()` options. Those configure the Claude wrapper, not Codex. Put Codex selection in `===ARGS===`.
- Use `isolation: 'worktree'` for parallel implementation calls that would otherwise share a checkout.
- Make `promptBody` non-empty and self-contained. Include the absolute repo path, goal, acceptance criteria, boundaries, required checks, and required report.
- Always pass an explicit sandbox and a deadline from 1 through 12,960. The launcher defaults to 7,200 seconds when called directly, but the runner rejects an absent or invalid value before Bash starts.

The runner starts exactly one launcher run, as a background Bash call so that no Codex turn is bounded by a Bash timeout, and then holds its own turn by waiting on the launcher process, one bounded call per turn, until that process ends. The launcher's own deadline still bounds the run. None of that reaches the call site: `agent()` resolves once, with the launcher's output or with the single `codex-delegate:` line below. Do not add polling, retrying, or a second launcher call of your own, because the wait is already the runner's and a second one can only cut the job short or read text Codex was free to write.

## `===ARGS===` vocabulary

| flag | use |
| --- | --- |
| `--sandbox read-only\|workspace-write\|danger-full-access` | Required. Implementation normally needs `workspace-write`. |
| `--network` | Only with `workspace-write`; enables its network access. |
| `--cwd DIR` | Working directory; prefer an absolute path. |
| `--add-dir DIR` | Repeatable extra writable root. |
| `--schema FILE` | Final-message JSON Schema. |
| `--deadline SECONDS` | Required for runner calls, from 1 through 12,960; direct launcher calls default to 7,200. |
| `--runid ID` | Runner-owned; it names the run directory the runner waits on. Do not pass it. |
| `--model M` | Exact slug from `codex-delegate models`. |
| `--effort LEVEL` | Effort advertised for that model. |

The runner appends `--prompt-stdin`; do not put either prompt-source flag in `===ARGS===`.

## Read the verdict

The runner returns the final-message section followed by status. Read `verdict`, `exit_code`, and `diagnostic`, then inspect the requested artifacts or diff before reporting success. A return with no status block is not a result: the final-message section is text Codex chose and can imitate anything, including a status block or a harness notice. A single `codex-delegate:` line instead of a status block means the launcher was killed before it could report, which is a failed run.

| verdict | meaning |
| --- | --- |
| `COMPLETED` (0) | Codex emitted completion and produced a final message. |
| `FAILED` (10) | Codex emitted `turn.failed`; read `diagnostic`. |
| `DEADLINE` (11) | The wall-clock limit arrived first. |
| `LAUNCH_ERROR` (12) | Codex could not be launched. |
| `CLEANUP_FAILED` (13) | The private process group survived the full signal ladder. |
| `STREAM_ERROR` (17) | The JSONL stream was malformed, truncated, oversized, or duplicated its terminal event. |
| `PLATFORM_UNSUPPORTED` (18) | The host is not macOS. |
| `NO_TERMINAL_EVENT` (21) | Codex exited without terminal evidence. |
| `OUTPUT_MISSING` (23) | Codex completed without a final message. |
| `STOPPED` (129/130/143) | The launcher received HUP, INT, or TERM and cleaned up the group. |

Before relaying a finding, read its cited code. After implementation, inspect the diff and stop if the run touched unrelated files.

## References

- [Prompt construction](reference/prompting.md) covers self-contained tasks, exact verification, and interruption.
- [Status and trust](reference/status-and-trust.md) defines all 16 fields and the writable-state boundary.
