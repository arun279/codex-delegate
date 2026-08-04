"""Validate repeated reduced status records and their permitted variance."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import cast

EXPECTED_KEYS = {
    "schema_version",
    "runid",
    "verdict",
    "exit_code",
    "diagnostic",
    "signal",
    "model",
    "effort",
    "sandbox",
    "deadline_s",
    "duration_s",
    "process_exit_code",
    "terminal_event",
    "final_message_path",
    "events_path",
    "stderr_path",
}
PATH_FIELDS = ("final_message_path", "events_path", "stderr_path")
VARIABLE_FIELDS = {"runid", "duration_s", *PATH_FIELDS}


def load_status(path: Path) -> dict[str, object]:
    value = cast(object, json.loads(path.read_text(encoding="utf-8")))
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError(f"{path} is not a JSON object")
    return cast(dict[str, object], value)


def validate(status: dict[str, object], number: int, work: Path) -> list[str]:
    problems: list[str] = []
    runid = f"determinism-{number:02d}"
    if set(status) != EXPECTED_KEYS:
        problems.append(f"run {number} schema differs: {sorted(set(status) ^ EXPECTED_KEYS)}")
    expected = {
        "schema_version": 1,
        "runid": runid,
        "verdict": "COMPLETED",
        "exit_code": 0,
        "diagnostic": None,
        "signal": None,
        "model": "gpt-5.6-sol",
        "effort": "medium",
        "sandbox": "read-only",
        "deadline_s": 60,
        "process_exit_code": 0,
        "terminal_event": "turn.completed",
    }
    for key, value in expected.items():
        if status.get(key) != value:
            problems.append(f"run {number} {key} is {status.get(key)!r}, expected {value!r}")
    duration = status.get("duration_s")
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration < 0:
        problems.append(f"run {number} duration_s is invalid: {duration!r}")
    run_dir = work / "runs" / runid
    expected_paths = {
        "final_message_path": run_dir / "final.txt",
        "events_path": run_dir / "events.jsonl",
        "stderr_path": run_dir / "stderr.log",
    }
    for field, path in expected_paths.items():
        if status.get(field) != str(path) or not path.is_file():
            problems.append(f"run {number} {field} is not its existing artifact")
    if not re.fullmatch(r"determinism-[0-9]{2}", str(status.get("runid"))):
        problems.append(f"run {number} runid shape is invalid")
    exit_text = (work / f"exit-{number}").read_text(encoding="utf-8").strip()
    if exit_text != "0":
        problems.append(f"run {number} command exit is {exit_text}, expected 0")
    output = (work / f"output-{number}").read_text(encoding="utf-8")
    if "STUB FINAL MESSAGE" not in output or '"verdict": "COMPLETED"' not in output:
        problems.append(f"run {number} output lacks final message or status")
    return problems


def stable(status: dict[str, object]) -> dict[str, object]:
    return {key: value for key, value in status.items() if key not in VARIABLE_FIELDS}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: determinism_check.py WORK RUNS", file=sys.stderr)
        return 2
    work = Path(sys.argv[1])
    count = int(sys.argv[2])
    statuses = [load_status(work / f"status-{number}.json") for number in range(1, count + 1)]
    problems = [
        problem
        for number, status in enumerate(statuses, 1)
        for problem in validate(status, number, work)
    ]
    baseline = stable(statuses[0])
    for number, status in enumerate(statuses[1:], 2):
        if stable(status) != baseline:
            problems.append(f"run {number} changed a non-variable status field")
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        return 1
    print("determinism: permitted variance is runid, duration_s, and three run-local paths")
    print(f"determinism: PASS: {count} reduced COMPLETED records were otherwise identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
