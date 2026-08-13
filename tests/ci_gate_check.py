"""Require the release gate and macOS runner in the same CI job."""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ci_gate_check.py CI_WORKFLOW", file=sys.stderr)
        return 2
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    try:
        start = lines.index("  macos-release-gate:") + 1
    except ValueError:
        print("ci-gate: FAIL: macos-release-gate job is missing", file=sys.stderr)
        return 1
    end = next(
        (
            index
            for index in range(start, len(lines))
            if lines[index].startswith("  ") and not lines[index].startswith("    ")
        ),
        len(lines),
    )
    job = {line.strip() for line in lines[start:end]}
    if "runs-on: macos-latest" not in job or "run: bash scripts/gate.sh" not in job:
        print(
            "ci-gate: FAIL: macos-release-gate must run on macos-latest and execute bash scripts/gate.sh",
            file=sys.stderr,
        )
        return 1
    print("ci-gate: PASS: macos-release-gate runs the gate on macos-latest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
