# Prompt construction

Make the task self-contained. Include the absolute repository path, the concrete goal, files or areas in scope, constraints, acceptance criteria, required checks, and the exact report expected. Do not rely on hidden conversation context.

Use a normal exec prompt for independent review. Ask for findings with severity, file and line, supporting reasoning, and a final summary. The launcher does not provide a separate review harness.

Require commands whose exit status matters to run separately and capture it immediately with `<cmd>; echo "EXIT=$?"`. A pipeline reports its last process unless the job deliberately checks `pipefail`.

The runner waits on the launcher for you, however long the job takes, so the call resolves once, with the launcher's output or with one `codex-delegate:` line reporting a launcher killed before it could write any. Do not write a waiter, a poller, or a retry around it: the run belongs to the runner, and a second caller reaching into it can only cut the job short or trust text Codex wrote. If the launcher receives HUP, INT, or TERM, it stops the private Codex process group, writes `STOPPED` status, and exits with 128 plus the signal number.

When Codex reports incomplete work, make a new, smaller call with a new run id. There is no resume or historical-process control surface.
