#!/usr/bin/env python3
"""Execute the Bash agents/runner.md prescribes, so an instruction that cannot run cannot ship.

Three wait prescriptions shipped without ever being executed: one that never ended when the
launcher died, one built on a `sleep` the harness blocks, and one that timed a clock instead of
the job. A regular expression over the runner proves a string is present. It cannot prove the
command parses, survives this plugin's own Bash guard, or ends when the launcher ends. This runs
them against a real process and checks exactly those three things.
"""

from __future__ import annotations

import importlib.util
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import ModuleType
from typing import cast

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "agents" / "runner.md"
GUARD = ROOT / "hooks" / "guard-bash.py"
BLOCK = re.compile(r"^```bash\n(.*?)^```$", re.DOTALL | re.MULTILINE)
PLACEHOLDER = re.compile(r"<[A-Z_]+>")
BOUND = re.compile(r"-ge (\d+)")
RUNID = "runner-0123456789abcdef"
DELIMITER = "CODEX_DELEGATE_PROMPT_" + "0123456789abcdef" * 2
# A launcher that is already dead must be seen as dead within this, whatever the wait's own bound.
DEATH_BUDGET_S = 15.0


def blocks() -> list[str]:
    found = cast("list[str]", BLOCK.findall(RUNNER.read_text(encoding="utf-8")))
    if len(found) != 3:
        raise SystemExit(
            f"runner-protocol: {RUNNER.name} must hold the launcher, wait, and report blocks "
            f"in that order, found {len(found)} bash blocks"
        )
    return found


def fill(block: str, label: str, values: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(0)
        if name not in values:
            raise SystemExit(
                f"runner-protocol: FAIL: the {label} block uses {name}, which it is not allowed "
                "to know, so this check cannot execute what the runner prescribes"
            )
        return values[name]

    return PLACEHOLDER.sub(replace, block)


def bash(script: str, env: dict[str, str], timeout: float) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603  # Runs the checked-in runner prescription without a shell.
        ["/bin/bash", "-c", script],
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )


def parses(script: str, work: Path, name: str) -> bool:
    path = work / name
    path.write_text(script, encoding="utf-8")
    checked = subprocess.run(  # noqa: S603  # Syntax-only bash on a file this check just wrote.
        ["/bin/bash", "-n", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    return checked.returncode == 0


def guard() -> ModuleType:
    spec = importlib.util.spec_from_file_location("guard_bash", GUARD)
    if spec is None or spec.loader is None:
        raise SystemExit(f"runner-protocol: cannot load {GUARD}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def hurry(block: str) -> str:
    """Shrink only the bound that holds a live launcher, leaving the startup grace alone."""
    lines = (BOUND.sub("-ge 1", line) if "kill -0" in line else line for line in block.splitlines())
    return "\n".join(lines) + "\n"


def check_wait(block: str, env: dict[str, str], run_dir: Path) -> list[str]:
    problems: list[str] = []
    pid_path = run_dir / "pid"
    fast = hurry(block)

    # The launcher records its pid a moment after the background call returns. Until then it is
    # starting, not finished, and reading it as finished returns an empty file as the result.
    child = subprocess.Popen(["/bin/sleep", "120"])  # noqa: S603  # Stands in for a live launcher.
    late = f"sleep 2; printf '%s\\n' {child.pid} > {shlex.quote(str(pid_path))}"
    writer = subprocess.Popen(["/bin/bash", "-c", late])  # noqa: S603  # Records that pid late.
    try:
        starting = bash(fast, env, 90).stdout.strip()
        if starting != "RUNNING":
            problems.append(
                f"a launcher that has not recorded its pid yet makes the wait print {starting!r}, "
                "so a job that started normally is reported as one that produced nothing"
            )
        alive = bash(fast, env, 60).stdout.strip()
        if alive != "RUNNING":
            problems.append(
                f"a live launcher makes the wait print {alive!r}, so the runner cannot tell "
                "waiting from finished"
            )
    except subprocess.TimeoutExpired:
        problems.append("the wait ignores its own bound, so it never yields the turn back")
        return problems
    finally:
        writer.wait()
        child.kill()
        child.wait()

    started = time.monotonic()
    try:
        ended = bash(block, env, DEATH_BUDGET_S).stdout.strip()
    except subprocess.TimeoutExpired:
        problems.append(
            f"the wait was still running {DEATH_BUDGET_S}s after the launcher died, so it is "
            "timing a clock rather than the job"
        )
        return problems
    if ended != "ENDED":
        problems.append(f"a dead launcher makes the wait print {ended!r} rather than 'ENDED'")
    if time.monotonic() - started > DEATH_BUDGET_S:
        problems.append("the wait outlived the launcher it is waiting on")

    pid_path.unlink()
    try:
        missing = bash(BOUND.sub("-ge 1", block), env, DEATH_BUDGET_S).stdout.strip()
    except subprocess.TimeoutExpired:
        problems.append("the wait never ends when the launcher recorded no pid at all")
        return problems
    if missing != "ENDED":
        problems.append(f"a launcher that never recorded a pid makes the wait print {missing!r}")
    return problems


def check_report(block: str, env: dict[str, str], run_dir: Path, work: Path) -> list[str]:
    problems: list[str] = []
    output = work / "job.out"
    filled = fill(block, "report", {"<RUNID>": RUNID, "<OUTPUT_FILE>": str(output)})
    payload = "\n--- FINAL MESSAGE (/x/final.txt) ---\nbody\n\n--- STATUS ---\n{}\n"
    output.write_text(payload, encoding="utf-8")
    verbatim = bash(filled, env, 30).stdout
    if verbatim != payload:
        problems.append("the report call does not return the launcher output byte for byte")

    output.write_text("", encoding="utf-8")
    silent = bash(filled, env, 30).stdout
    if not silent.strip():
        problems.append(
            "a launcher killed before it reported returns nothing, which a caller reads as an "
            "empty but successful result"
        )
    elif str(run_dir) not in silent:
        problems.append("the silent-death report does not name the run directory")
    return problems


def main() -> int:
    launcher, wait, report = blocks()
    problems: list[str] = []
    with tempfile.TemporaryDirectory() as raw:
        work = Path(raw)
        home = work / "home"
        run_root = work / "runs"
        run_dir = run_root / RUNID
        run_dir.mkdir(parents=True)
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(home),
            "CODEX_DELEGATE_HOME": str(run_root),
        }
        filled = {
            "launcher": fill(
                launcher,
                "launcher",
                {
                    "<RUNID>": RUNID,
                    "<ARGS>": "--sandbox read-only --deadline 60",
                    "<PROMPT>": "a prompt body",
                    "<DELIMITER>": DELIMITER,
                },
            ),
            # The wait may not know the output file: reading it is what Codex can forge.
            "wait": fill(wait, "wait", {"<RUNID>": RUNID}),
            "report": fill(
                report, "report", {"<RUNID>": RUNID, "<OUTPUT_FILE>": str(work / "job.out")}
            ),
        }
        starts_codex = guard().starts_codex
        for name, script in filled.items():
            if not parses(script, work, f"{name}.sh"):
                problems.append(f"the {name} block is not valid bash")
            if starts_codex(script):
                problems.append(f"this plugin's own Bash guard denies the {name} block")
        if not problems:
            problems.extend(check_wait(filled["wait"], env, run_dir))
            problems.extend(check_report(report, env, run_dir, work))

    for problem in problems:
        print(f"runner-protocol: FAIL: {problem}")
    if problems:
        return 1
    print("runner-protocol: PASS: 3 prescribed blocks parse, pass the guard, and end with the job")
    return 0


if __name__ == "__main__":
    sys.exit(main())
