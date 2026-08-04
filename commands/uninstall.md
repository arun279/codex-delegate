---
name: uninstall
description: Remove codex-delegate run artifacts and its obsolete permission setting before uninstalling the plugin.
---

# Clean up codex-delegate before unregistering it

Jobs are blocking foreground calls, so there is no background lifecycle command to run.

Follow these steps exactly:

1. Ask the user to stop any currently running `codex-delegate:runner` task. Do not continue while a launcher Bash call is still shown as running.

2. Resolve `run_root=${CODEX_DELEGATE_HOME:-$HOME/.codex-delegate}` to an absolute physical path. Refuse if it is empty, relative, `/`, `$HOME`, a symlink, or owned by another user.

3. Show the resolved state directory and this plan:

   ```text
   remove only Bash(codex-delegate:*) from ~/.claude/settings.json if present
   remove the validated codex-delegate state directory
   list, but do not delete, Codex trust entries and matching Claude plugin caches
   print the final claude plugin uninstall command
   ```

   Ask for explicit confirmation before changing either settings or run artifacts.

4. If `~/.claude/settings.json` exists, require a regular non-symlink file containing valid UTF-8 JSON. Remove only exact string entries equal to `Bash(codex-delegate:*)` from the top-level `permissions.allow` array. Preserve every other value and the file mode, use an fsynced temporary file in the same directory, and replace atomically. If validation or replacement fails, stop without deleting run artifacts.

5. If the validated state directory exists, print its shell-quoted path and remove exactly that directory. Report that local prompts, event streams, stderr logs, final messages, and status records were deleted and are not recoverable through the plugin. If it does not exist, report it as already clean.

6. Print, but never delete or edit:
   - trusted project table headers and trust lines from `~/.codex/config.toml`; and
   - directories named `codex-delegate` below `~/.claude/plugins/cache`.

7. Finish by printing this command without running it:

   ```sh
   claude plugin uninstall codex-delegate
   ```
