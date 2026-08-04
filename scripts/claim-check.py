#!/usr/bin/env python3
"""Check that documentation matches the reduced launcher surface."""

from __future__ import annotations

import ast
import json
import re
from pathlib import Path
from typing import cast

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "bin" / "codex-delegate"
RUNNER = ROOT / "agents" / "runner.md"
DOCS = [
    ROOT / "README.md",
    RUNNER,
    ROOT / "skills" / "routing" / "SKILL.md",
    ROOT / "skills" / "routing" / "reference" / "prompting.md",
    ROOT / "skills" / "routing" / "reference" / "status-and-trust.md",
    ROOT / "SECURITY.md",
    ROOT / "PRIVACY.md",
    ROOT / "commands" / "uninstall.md",
]
BASH_CEILING_S = 600
# Measured on the harness: a Bash call given no explicit timeout is killed at this, and only a
# call that reaches the ceiling above is handed off alive. The turn budget must survive a runner
# that forgets the timeout, because a pinned agent definition cannot pin a per-call parameter.
BASH_DEFAULT_TIMEOUT_S = 120
# Launcher time outside its own deadline: the 15s catalog subprocess plus the signal ladder.
LAUNCHER_OVERHEAD_S = 60
# The launcher call turn, then the report call and the reply that returns it.
FIXED_TURNS = 3
STATUS_SEPARATOR = "--- STATUS ---"
RETIRED_FLAGS = {"--mode", "--base", "--commit", "--uncommitted", "--lane"}
RETIRED_COMMANDS = {"start", "wait", "status", "reap"}
RETIRED_STATUS = {
    "verdict_exit_code",
    "phase",
    "network_posture",
    "computer_use",
    "cleanup_scope",
    "observed_processes",
    "survivors",
    "metadata_tampered_fields",
    "catalog_degraded",
    "catalog_dropped_entries",
}


def python_source(shell: str) -> str:
    marker = "<<'PY'\n"
    if marker not in shell or not shell.endswith("\nPY\n"):
        raise ValueError("launcher Python heredoc was not found")
    return shell.split(marker, 1)[1][:-4]


def string_argument(call: ast.Call) -> str | None:
    if not call.args:
        return None
    first = call.args[0]
    return first.value if isinstance(first, ast.Constant) and isinstance(first.value, str) else None


def launcher_surface(source: str) -> tuple[set[str], set[str], set[str], dict[str, int]]:
    tree = ast.parse(source)
    flags: set[str] = set()
    commands: set[str] = set()
    status_fields: set[str] = set()
    exits: dict[str, int] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            value = string_argument(node)
            if node.func.attr == "add_argument" and value and value.startswith("--"):
                flags.add(value)
            if node.func.attr == "add_parser" and value:
                commands.add(value)
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "EXIT" for target in node.targets
        ):
            raw = cast(object, ast.literal_eval(node.value))
            if not isinstance(raw, dict):
                raise ValueError("EXIT is not a dictionary")
            exits = {
                key: item
                for key, item in raw.items()
                if isinstance(key, str) and isinstance(item, int) and not isinstance(item, bool)
            }
    for node in tree.body:
        if not isinstance(node, ast.FunctionDef) or node.name != "status_for":
            continue
        returns = [item for item in ast.walk(node) if isinstance(item, ast.Return)]
        if len(returns) != 1 or not isinstance(returns[0].value, ast.Dict):
            raise ValueError("status_for must have one literal dictionary return")
        for key in returns[0].value.keys:
            if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
                raise TypeError("status_for contains a dynamic field")
            status_fields.add(key.value)
    if not status_fields or not exits:
        raise ValueError("launcher status or exit surface was not found")
    return flags, commands, status_fields, exits


def launcher_constant(source: str, name: str) -> int:
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == name for target in node.targets
        ):
            value = cast(object, ast.literal_eval(node.value))
            if isinstance(value, int) and not isinstance(value, bool):
                return value
    raise ValueError(f"launcher constant {name} was not found")


def turns_needed(reachable: int, per_turn: int) -> int:
    return FIXED_TURNS + -(-(reachable + LAUNCHER_OVERHEAD_S) // per_turn)


def runner_wait_contract(source: str, runner: str) -> list[str]:
    """Check the shape and budget of the runner's wait, not that the prose instructs it.

    A regular expression cannot tell an instruction from an example of a bug, and it cannot run
    anything. scripts/runner-protocol-check.py executes these blocks; this pins the couplings
    that execution cannot see, above all the turn budget at a deadline no test will sit through.
    """
    problems: list[str] = []
    if source.count(STATUS_SEPARATOR) != 1:
        problems.append(f"the launcher no longer prints {STATUS_SEPARATOR!r} exactly once")
    if STATUS_SEPARATOR in runner:
        problems.append(
            f"the runner keys on {STATUS_SEPARATOR!r}, which Codex can put in its own final "
            "message and the launcher flushes ahead of the real status"
        )
    if not re.search(r"""record_pid\(os\.path\.join\(run_dir, "pid"\)\)""", source):
        problems.append(
            "the launcher no longer records its pid in the run directory, so the runner's wait "
            "has nothing to tie itself to"
        )
    root = re.search(
        r"""os\.environ\.get\("(?P<env>[A-Z_]+)", str\(Path\.home\(\) / "(?P<home>[^"]+)"\)\)""",
        source,
    )
    if root is None:
        problems.append("the launcher's run root is no longer a literal the runner can derive")
    else:
        env, default = root.group("env"), root.group("home")
        if f"${{{env}:-$HOME/{default}}}" not in runner:
            problems.append(
                f"the runner looks for the pid file outside {env} or $HOME/{default}, so it waits "
                "on a directory the launcher never writes"
            )
    loops = re.findall(r"^until (.+); do sleep (\d+); done$", runner, re.MULTILINE)
    turns = re.search(r"^maxTurns: *(\d+) *$", runner.split("---", 2)[1], re.MULTILINE)
    if not loops or turns is None:
        problems.append(
            "the runner declares no bounded wait loop and maxTurns, so its wait cannot be checked"
        )
        return problems
    bound = 0
    total = 0
    for condition, interval in loops:
        limit = re.search(r"-ge (\d+)", condition)
        if limit is None:
            problems.append(f"the wait loop on {condition!r} has no bound, so it never yields")
            return problems
        held = int(limit.group(1))
        total += held
        if int(interval) >= held:
            problems.append(
                f"a {interval}s sleep cannot step a {held}s wait, so the loop overshoots the "
                "bound it is supposed to hold"
            )
        if "kill -0" in condition and '"$D/pid"' in condition:
            bound = held
    if bound == 0:
        problems.append(
            "no wait loop ends on the launcher pid, so the wait outlives the job it waits on"
        )
        return problems
    if total >= BASH_CEILING_S:
        problems.append(
            f"the wait's bounds total {total}s and reach the {BASH_CEILING_S}s Bash ceiling, so "
            "the wait is itself handed off into a message the runner must not answer"
        )
    reachable = launcher_constant(source, "MAX_DEADLINE")
    declared = int(turns.group(1))
    healthy = turns_needed(reachable, bound)
    degraded = turns_needed(reachable, min(bound, BASH_DEFAULT_TIMEOUT_S))
    if declared < degraded:
        problems.append(
            f"maxTurns {declared} covers a {reachable}s run in {healthy} turns at the {bound}s "
            f"bound but needs {degraded} when a wait call is given no timeout and dies at "
            f"{BASH_DEFAULT_TIMEOUT_S}s, so the runner abandons the job it started"
        )
    return problems


def inline_tokens(text: str) -> set[str]:
    return set(re.findall(r"`([A-Za-z_][A-Za-z0-9_.-]*|--[a-z][a-z0-9-]*)`", text))


def main() -> int:
    shell = LAUNCHER.read_text(encoding="utf-8")
    source = python_source(shell)
    flags, commands, status_fields, exits = launcher_surface(source)
    documents = {path: path.read_text(encoding="utf-8") for path in DOCS}
    joined = "\n".join(documents.values())
    tokens = inline_tokens(joined)
    documented_flags = set(re.findall(r"--[a-z][a-z0-9-]*", joined)) - {"--version"}
    documented_status = status_fields & tokens
    problems = runner_wait_contract(source, documents[RUNNER])

    if commands != {"run", "models"}:
        problems.append(f"launcher commands are {sorted(commands)}, expected run and models")
    missing_flags = flags - documented_flags
    extra_flags = documented_flags - flags
    if missing_flags:
        problems.append(f"launcher flags missing from docs: {sorted(missing_flags)}")
    if extra_flags:
        problems.append(f"documented flags absent from launcher: {sorted(extra_flags)}")
    missing_status = status_fields - documented_status
    if missing_status:
        problems.append(f"status fields missing from docs: {sorted(missing_status)}")
    if len(status_fields) != 16:
        problems.append(f"launcher emits {len(status_fields)} status fields, expected 16")
    for flag in sorted(RETIRED_FLAGS):
        if flag in flags or f"`{flag}`" in joined:
            problems.append(f"retired flag remains: {flag}")
    for command in sorted(RETIRED_COMMANDS):
        if re.search(rf"\bcodex-delegate\s+{re.escape(command)}\b", joined):
            problems.append(f"retired subcommand remains documented: {command}")
    for field in sorted(RETIRED_STATUS):
        if f"`{field}`" in joined:
            problems.append(f"retired status field remains documented: {field}")
    for verdict in exits:
        if f"`{verdict}`" not in joined:
            problems.append(f"launcher verdict missing from docs: {verdict}")
    for required in ("`STOPPED`", "128 plus the signal number", "private process group"):
        if required not in joined:
            problems.append(f"stop contract missing from docs: {required}")

    package = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))
    plugin = json.loads((ROOT / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
    if package.get("description") != plugin.get("description"):
        problems.append("package and plugin descriptions differ")
    hooks = (ROOT / "hooks" / "hooks.json").read_text(encoding="utf-8")
    if "SessionEnd" in hooks or (ROOT / "hooks" / "session-end.py").exists():
        problems.append("background session-end cleanup remains installed")

    for problem in problems:
        print(f"claim-check: FAIL: {problem}")
    if problems:
        return 1
    print("claim-check: extractor self-test PASS (literal argparse and status dictionaries)")
    print(
        "claim-check: PASS: "
        f"{len(commands)} commands, {len(flags)} flags, {len(status_fields)} status fields, "
        f"and {len(exits)} fixed verdicts agree"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
