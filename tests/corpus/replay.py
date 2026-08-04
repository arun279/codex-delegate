#!/usr/bin/env python3
"""Run the frozen Bash-command corpus as a portable, offline release gate.

The committed ``real-commands.json`` fixture is the gate. Its commands are sanitized
representations of real shell shapes, and the default command needs only this checkout
and Python's standard library.

``--rescan`` is explicitly a MAINTAINER-ONLY discovery tool. It reads local Claude Code
transcripts to find denied shapes that are absent from the frozen fixture; CI and normal
contributors neither need nor should have transcript history.

Exit 0 when every case matches, 1 for guard mismatches, and 2 for an invalid or unsafe
fixture or an unusable guard. Any mismatch is a release blocker: a denied launch that is
allowed escapes supervision, while an allowed command that is denied blocks normal work.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "real-commands.json"
GUARD = HERE.parent.parent / "hooks" / "guard-bash.py"
PRIVACY_SCANNER = HERE.parent.parent / "scripts" / "privacy-scan.py"

ExpectedVerdict = Literal["allow", "deny"]
ActualVerdict = Literal["allow", "deny", "error"]


@dataclass(frozen=True)
class ReplayCase:
    command: str
    expect: ExpectedVerdict
    source: str | None


@dataclass(frozen=True)
class Decision:
    verdict: ActualVerdict
    detail: str | None = None


def check_fixture_privacy(path: Path) -> str | None:
    """Apply the repository's single-sourced privacy policy to the fixture."""
    try:
        process = subprocess.run(  # noqa: S603  # Runs the fixed scanner with this interpreter.
            [sys.executable, str(PRIVACY_SCANNER), "--path", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        return str(error)
    if process.returncode == 0:
        return None
    return process.stdout.strip() or process.stderr.strip() or "scanner gave no diagnostic"


def load_cases(path: Path) -> list[ReplayCase]:
    """Load and validate the public fixture schema."""
    text = path.read_text(encoding="utf-8")
    privacy_error = check_fixture_privacy(path)
    if privacy_error is not None:
        raise ValueError(f"fixture privacy gate failed:\n{privacy_error}")

    raw: object = json.loads(text)
    if not isinstance(raw, list):
        # ValueError is part of the fixture-error contract caught by both entry points.
        raise ValueError("fixture root must be a JSON array")  # noqa: TRY004

    cases: list[ReplayCase] = []
    for index, row in enumerate(raw, start=1):
        if not isinstance(row, dict):
            # Keep every invalid fixture shape on the same handled error path.
            raise ValueError(f"case {index}: expected an object")  # noqa: TRY004
        command = row.get("command")
        expect = row.get("expect")
        source = row.get("source")
        if not isinstance(command, str) or not command:
            raise ValueError(f"case {index}: command must be a non-empty string")
        if expect not in ("allow", "deny"):
            raise ValueError(f"case {index}: expect must be 'allow' or 'deny'")
        if source is not None and not isinstance(source, str):
            raise ValueError(f"case {index}: source must be a string when present")
        cases.append(ReplayCase(command, expect, source))

    if not cases:
        raise ValueError("fixture must contain at least one case")
    return cases


def decide(guard: Path, command: str) -> Decision:
    """Ask the hook for its verdict without executing the recorded command."""
    payload = {"tool_name": "Bash", "tool_input": {"command": command}}
    try:
        process = subprocess.run(  # noqa: S603  # Runs the explicitly selected local guard without a shell.
            [sys.executable, str(guard)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        return Decision("error", str(error))

    if process.returncode != 0:
        detail = process.stderr.strip() or process.stdout.strip() or "no output"
        return Decision("error", f"guard exited {process.returncode}: {detail}")
    if not process.stdout.strip():
        return Decision("allow")

    try:
        output: object = json.loads(process.stdout)
    except json.JSONDecodeError as error:
        return Decision("error", f"guard emitted invalid JSON: {error}")
    if not isinstance(output, dict):
        return Decision("error", "guard output was not a JSON object")
    hook_output = output.get("hookSpecificOutput")
    if not isinstance(hook_output, dict):
        return Decision("error", "guard output omitted hookSpecificOutput")
    if hook_output.get("permissionDecision") == "deny":
        return Decision("deny")
    return Decision("error", "guard output had no deny decision")


def transcript_commands(transcript_dir: Path) -> set[str]:
    """MAINTAINER ONLY: recover unique Bash commands from local transcripts."""
    commands: set[str] = set()
    for path in transcript_dir.rglob("*.jsonl"):
        try:
            handle = path.open(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        with handle:
            for line in handle:
                if '"Bash"' not in line:
                    continue
                try:
                    payload: object = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(payload, dict):
                    continue
                message = payload.get("message")
                if not isinstance(message, dict):
                    continue
                content = message.get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") != "tool_use" or block.get("name") != "Bash":
                        continue
                    tool_input = block.get("input")
                    if not isinstance(tool_input, dict):
                        continue
                    command = tool_input.get("command")
                    if isinstance(command, str) and command:
                        commands.add(command)
    return commands


def display_command(command: str, limit: int = 240) -> str:
    """Render a command on one bounded diagnostic line."""
    visible = command.replace("\n", "\\n")
    if len(visible) <= limit:
        return visible
    return visible[: limit - 3] + "..."


def run_rescan(guard: Path, transcript_dir: Path) -> int:
    """MAINTAINER ONLY: report locally observed denials absent from the fixture."""
    if not transcript_dir.is_dir():
        print(f"rescan error: transcript directory does not exist: {transcript_dir}")
        return 2

    try:
        known = {case.command for case in load_cases(FIXTURE)}
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"fixture error: {error}")
        return 2

    commands = transcript_commands(transcript_dir)
    denied: list[str] = []
    errors: list[tuple[str, str]] = []
    for command in sorted(commands):
        decision = decide(guard, command)
        if decision.verdict == "deny":
            denied.append(command)
        elif decision.verdict == "error":
            errors.append((command, decision.detail or "unknown guard error"))

    print("MAINTAINER RESCAN: local transcript discovery; not the portable gate")
    print(f"scanned {len(commands)} unique commands, {len(denied)} denied")
    for command in denied:
        if command not in known:
            print(f"NEW DENIAL, not in fixture: {display_command(command)}")
    for command, detail in errors:
        print(f"GUARD ERROR: {detail}: {display_command(command)}")
    return 2 if errors else 0


def run_replay(guard: Path) -> int:
    """Run the portable offline corpus gate."""
    try:
        cases = load_cases(FIXTURE)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"fixture error: {error}")
        return 2

    print("fixture privacy: ok (repository policy)")
    mismatches: list[tuple[int, ReplayCase, Decision]] = []
    for index, case in enumerate(cases, start=1):
        decision = decide(guard, case.command)
        if decision.verdict != case.expect:
            mismatches.append((index, case, decision))

    correct = len(cases) - len(mismatches)
    print(f"corpus replay: {correct}/{len(cases)} real commands correct")
    for index, case, decision in mismatches:
        source = f", source={case.source}" if case.source is not None else ""
        detail = f" ({decision.detail})" if decision.detail is not None else ""
        print(f"  case {index}{source}: expected {case.expect}, got {decision.verdict}{detail}")
        print(f"    command: {display_command(case.command)}")
    if any(decision.verdict == "error" for _, _, decision in mismatches):
        return 2
    return 1 if mismatches else 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse gate and maintainer-tool arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guard", type=Path, default=GUARD)
    parser.add_argument(
        "--rescan",
        type=Path,
        metavar="TRANSCRIPT_DIR",
        help="MAINTAINER ONLY: scan local Claude Code transcripts for new denials",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Dispatch the portable gate or the explicit maintainer rescan."""
    args = parse_args(argv)
    guard: Path = args.guard
    rescan: Path | None = args.rescan
    if rescan is not None:
        return run_rescan(guard, rescan.expanduser())
    return run_replay(guard)


if __name__ == "__main__":
    sys.exit(main())
