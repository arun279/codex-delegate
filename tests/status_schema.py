"""Check that status documents expose exactly the public 17-field schema."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

EXPECTED = {
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
    "usage",
    "final_message_path",
    "events_path",
    "stderr_path",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verdict")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    for raw_path in args.paths:
        path = Path(raw_path)
        try:
            status = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"status schema: {path}: {error}")
            return 1
        if not isinstance(status, dict) or set(status) != EXPECTED:
            print(f"status schema: {path}: unexpected fields")
            return 1
        if args.verdict is not None and status["verdict"] != args.verdict:
            print(f"status schema: {path}: expected verdict {args.verdict}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
