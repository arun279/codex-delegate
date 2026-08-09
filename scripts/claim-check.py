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
HOOKS = ROOT / "hooks" / "hooks.json"
GUARD = ROOT / "hooks" / "guard-bash.py"
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
# Measured on the harness: a Bash call given no explicit timeout is killed at this. Every
# prescribed wait must return before it because a pinned agent cannot pin a per-call parameter.
BASH_DEFAULT_TIMEOUT_S = 120
MIN_RUNNER_WAIT_SECONDS = 110
# Launcher time outside its own deadline: the 15s catalog subprocess plus the signal ladder.
LAUNCHER_OVERHEAD_S = 60
# The launcher call turn, then the report call and the reply that returns it.
FIXED_TURNS = 3
TURN_MARGIN = 8
STATUS_SEPARATOR = "--- STATUS ---"
BASH_BLOCK = re.compile(r"^```bash\n.*?^```$", re.DOTALL | re.MULTILINE)
ONE_CALL = re.compile(r"\b(?:one|single)[ -](?:blocking|call)\b", re.IGNORECASE)
BLOCKS = re.compile(r"\bblock(?:s|ing|ed)\b", re.IGNORECASE)
DISPATCH = re.compile(r"\b(?:runner|caller|jobs?)\b|Claude Code", re.IGNORECASE)
SENTENCE = re.compile(r"[^.\n]+")
RETIRED_FLAGS = {"--mode", "--base", "--commit", "--uncommitted", "--lane"}
EXTERNAL_FLAGS = {"--git-common-dir", "--path-format", "--version"}
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


def exception_return(source: str, function: str, exception: str) -> int | str:
    tree = ast.parse(source)
    target = next(
        (node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == function),
        None,
    )
    if target is None:
        raise ValueError(f"launcher function {function} was not found")
    for handler in (node for node in ast.walk(target) if isinstance(node, ast.ExceptHandler)):
        if not isinstance(handler.type, ast.Name) or handler.type.id != exception:
            continue
        returns = [node for node in ast.walk(handler) if isinstance(node, ast.Return)]
        if len(returns) != 1 or returns[0].value is None:
            raise ValueError(f"{function}'s {exception} handler has no single return")
        value = returns[0].value
        if isinstance(value, ast.Constant) and isinstance(value.value, int):
            return value.value
        if (
            isinstance(value, ast.Subscript)
            and isinstance(value.value, ast.Name)
            and value.value.id == "EXIT"
            and isinstance(value.slice, ast.Constant)
            and isinstance(value.slice.value, str)
        ):
            return value.slice.value
        raise ValueError(f"{function}'s {exception} handler has a dynamic return")
    raise ValueError(f"{function} has no {exception} handler")


def prompt_exit_contract(source: str, readme: str, exits: dict[str, int]) -> list[str]:
    problems: list[str] = []
    source_exit = exception_return(source, "run", "PromptSourceError")
    staging_verdict = exception_return(source, "run", "UserError")
    if not isinstance(source_exit, int) or not isinstance(staging_verdict, str):
        return ["launcher prompt handlers do not expose fixed exit outcomes"]
    if staging_verdict not in exits:
        return [f"prompt staging returns unknown verdict {staging_verdict}"]
    source_claim = f"Initial `--prompt-file` path validation exits {source_exit}."
    staging_claim = (
        "Empty prompt input, stdin read failures, prompt storage failures, and Codex launch "
        f"errors are `{staging_verdict}` ({exits[staging_verdict]})."
    )
    for claim in (source_claim, staging_claim):
        if claim not in readme:
            problems.append(f"README prompt-exit claim does not match the launcher: {claim}")
    return problems


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
    blocks = BASH_BLOCK.findall(runner)
    if len(blocks) != 3:
        problems.append(f"the runner has {len(blocks)} Bash blocks, expected launch, wait, report")
        return problems
    if "--runner-handoff" not in blocks[0] or "--runid" in blocks[0]:
        problems.append("the launcher, rather than the runner model, must mint the run ID")
    if 'codex-delegate runner-wait "<OUTPUT_FILE>"' not in blocks[1]:
        problems.append("the runner does not use the launcher-owned runner-wait command")
    if 'codex-delegate runner-report "<OUTPUT_FILE>"' not in blocks[2]:
        problems.append("the runner does not use the launcher-owned runner-report command")
    turns = re.search(r"^maxTurns: *(\d+) *$", runner.split("---", 2)[1], re.MULTILINE)
    if turns is None:
        problems.append("the runner declares no maxTurns budget")
        return problems
    try:
        bound = launcher_constant(source, "RUNNER_WAIT_SECONDS")
    except ValueError:
        problems.append("launcher has no fixed RUNNER_WAIT_SECONDS bound")
        return problems
    if bound >= BASH_DEFAULT_TIMEOUT_S:
        problems.append(
            f"runner-wait can take {bound}s and reach the {BASH_DEFAULT_TIMEOUT_S}s default"
        )
    if bound < MIN_RUNNER_WAIT_SECONDS:
        problems.append(
            f"runner-wait's {bound}s bound is below the measured {MIN_RUNNER_WAIT_SECONDS}s "
            "turn-cost floor"
        )
    try:
        startup_bound = launcher_constant(source, "RUNNER_STARTUP_SECONDS")
    except ValueError:
        problems.append("launcher has no fixed pre-RUNID startup bound")
    else:
        if startup_bound >= bound:
            problems.append(
                f"pre-RUNID startup bound {startup_bound}s does not fit inside the {bound}s wait"
            )
    reachable = launcher_constant(source, "MAX_DEADLINE")
    declared = int(turns.group(1))
    required = turns_needed(reachable, bound) + TURN_MARGIN
    if declared <= required:
        problems.append(
            f"maxTurns {declared} cannot cover {reachable}s in {bound}s waits plus "
            f"{TURN_MARGIN} replacement turns with spare capacity; it must exceed {required}"
        )
    return problems


def dispatch_claims(runner: str, texts: dict[str, str]) -> list[str]:
    """Fail on shipped text that still describes dispatch from Claude Code as one blocking call.

    The runner starts the launcher in the background and then holds its turn on the launcher pid,
    a shape the wait contract above pins and scripts/runner-protocol-check.py executes. A direct
    `codex-delegate run` does still block, so this is not a ban on the word: an occurrence is a
    dispatch claim only when its own sentence also names the runner, the caller, a job, or Claude
    Code. "one call" is refused wherever it appears, including where a call site really does make
    one: it is the exact phrase that shipped false, and "resolves once" says the true thing without
    inviting the old reading. bin/codex-delegate is out of scope because it is the code these
    claims are measured against, and CHANGELOG.md because a changelog has to be able to name the
    shape a release left.
    """
    calls = len(BASH_BLOCK.findall(runner))
    problems: list[str] = []
    for label, text in texts.items():
        for sentence in SENTENCE.findall(text):
            claim = ONE_CALL.search(sentence) or (
                BLOCKS.search(sentence) if DISPATCH.search(sentence) else None
            )
            if claim is not None:
                problems.append(
                    f"{label} calls dispatch {claim.group(0)!r} in "
                    f"{' '.join(sentence.split())[:64]!r}, but the runner prescribes {calls} "
                    "Bash calls and waits on the launcher process"
                )
    return problems


def inline_tokens(text: str) -> set[str]:
    return set(re.findall(r"`([A-Za-z_][A-Za-z0-9_.-]*|--[a-z][a-z0-9-]*)`", text))


def main() -> int:
    source = LAUNCHER.read_text(encoding="utf-8")
    flags, commands, status_fields, exits = launcher_surface(source)
    documents = {path: path.read_text(encoding="utf-8") for path in DOCS}
    package = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))
    plugin = json.loads((ROOT / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
    market = json.loads((ROOT / ".claude-plugin" / "marketplace.json").read_text(encoding="utf-8"))
    hooks = HOOKS.read_text(encoding="utf-8")
    # Published copy is the first thing a stranger reads and was the last thing anything read.
    entries = [str(item.get("description")) for item in market.get("plugins", [])]
    listings = {
        "package.json": str(package.get("description")),
        ".claude-plugin/plugin.json": str(plugin.get("description")),
        ".claude-plugin/marketplace.json": "\n".join([str(market.get("description")), *entries]),
    }
    joined = "\n".join([*documents.values(), *listings.values()])
    tokens = inline_tokens(joined)
    documented_flags = set(re.findall(r"--[a-z][a-z0-9-]*", joined)) - EXTERNAL_FLAGS
    documented_status = status_fields & tokens
    problems = runner_wait_contract(source, documents[RUNNER])
    problems += dispatch_claims(
        documents[RUNNER],
        {
            **{str(path.relative_to(ROOT)): text for path, text in documents.items()},
            **listings,
            "hooks/hooks.json": hooks,
            "hooks/guard-bash.py": GUARD.read_text(encoding="utf-8"),
        },
    )

    if commands != {"run", "models"}:
        problems.append(f"launcher commands are {sorted(commands)}, expected run and models")
    internal_commands = set(re.findall(r'sys\.argv\[1:2\] == \["(runner-[a-z-]+)"\]', source))
    if internal_commands != {"runner-wait", "runner-report"}:
        problems.append(
            f"internal commands are {sorted(internal_commands)}, expected runner-wait/report"
        )
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

    published = {listings["package.json"], listings[".claude-plugin/plugin.json"], *entries}
    if len(published) != 1:
        problems.append(
            f"the npm, plugin, and marketplace descriptions are {len(published)} different "
            "strings, so correcting the product only corrects some of them"
        )
    readme = documents[ROOT / "README.md"]
    skill = documents[ROOT / "skills" / "routing" / "SKILL.md"]
    security = documents[ROOT / "SECURITY.md"]
    status_reference = documents[ROOT / "skills" / "routing" / "reference" / "status-and-trust.md"]
    privacy = documents[ROOT / "PRIVACY.md"]
    git_docs = {
        "README.md": readme,
        "SECURITY.md": security,
        "skills/routing/SKILL.md": skill,
        "skills/routing/reference/status-and-trust.md": status_reference,
    }
    git_common_command = "git rev-parse --path-format=absolute --git-common-dir"
    for label, text in git_docs.items():
        if not all(term in text for term in ("`--add-dir`", "Git metadata", "opt in")):
            problems.append(f"{label} does not document the explicit --add-dir Git-metadata opt-in")
        if git_common_command not in text:
            problems.append(f"{label} does not name Git's absolute common-directory command")
    false_git_claims = (
        "cannot stage or commit",
        "does not include Git metadata",
        "cannot stage, commit, branch, or stash",
        "Git metadata changes therefore belong in the trusted caller",
    )
    for claim in false_git_claims:
        if claim in "\n".join(git_docs.values()):
            problems.append(f"sandbox documentation retains blanket false claim {claim!r}")
    if not all(term in readme and term in skill for term in ("`.git`", "linked worktree")):
        problems.append("README and routing skill omit default Git-metadata protection")
    if "do not compose" not in readme or "do not compose" not in skill:
        problems.append("sandbox documentation omits the permission-profile incompatibility")
    problems += prompt_exit_contract(source, readme, exits)
    if "runner rejects an absent or invalid value before Bash starts" in skill:
        problems.append("routing skill claims model instructions are deterministic validation")
    if "statically recognizable" not in readme or "statically recognizable" not in privacy:
        problems.append("hook documentation overstates malformed-call enforcement")
    for path in (ROOT / "README.md", ROOT / "skills" / "routing" / "SKILL.md"):
        if "exactly one terminal event" not in documents[path]:
            problems.append(
                f"{path.relative_to(ROOT)} omits duplicate-terminal STREAM_ERROR semantics"
            )
    if any("tears that group down" in item for item in published) or not all(
        "CLEANUP_FAILED" in item for item in published
    ):
        problems.append("published descriptions claim teardown is unconditional")
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
