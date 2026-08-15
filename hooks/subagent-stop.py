#!/usr/bin/env -S python3 -I -S
"""Keep the delegated runner alive while its launcher is still running."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from typing import Any

RUNNER_TYPE = "codex-delegate:runner"
KICKOFF = re.compile(r"(?:^|[/\s])codex-delegate\s+run(?:\s|$)")
HANDOFF = re.compile(r"(?:^|\s)--runner-handoff(?:\s|$)")
OUTPUT_PATH = re.compile(r"Output is being written to:\s*(.+?\.output)(?=$|[\s.,;:!?\])}])")
CORRECTION = "The delegated job is still RUNNING; keep calling runner-wait until it returns ENDED.\n"


def _blocks(record: object) -> list[dict[str, Any]]:
    if not isinstance(record, dict):
        return []
    message = record.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [block for block in content if isinstance(block, dict)]


def _result_text(content: object) -> str | None:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    text: list[str] = []
    for block in content:
        if not isinstance(block, dict) or not isinstance(block.get("text"), str):
            return None
        text.append(block["text"])
    return "\n".join(text)


def _output_path(transcript_path: str) -> str | None:
    kickoff_ids: set[str] = set()
    output_path = None
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as transcript:
            for line in transcript:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for block in _blocks(record):
                    tool_input = block.get("input")
                    command = tool_input.get("command") if isinstance(tool_input, dict) else None
                    tool_id = block.get("id")
                    if (
                        block.get("type") == "tool_use"
                        and isinstance(tool_id, str)
                        and isinstance(command, str)
                        and KICKOFF.search(command)
                        and HANDOFF.search(command)
                    ):
                        kickoff_ids.add(tool_id)
                    if block.get("type") != "tool_result" or block.get("tool_use_id") not in kickoff_ids:
                        continue
                    text = _result_text(block.get("content"))
                    match = OUTPUT_PATH.search(text) if text is not None else None
                    if match is not None:
                        output_path = match.group(1)
    except OSError:
        return None
    return output_path


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("agent_type") != RUNNER_TYPE:
        return 0
    transcript_path = payload.get("agent_transcript_path")
    if not isinstance(transcript_path, str):
        return 0
    output_path = _output_path(transcript_path)
    if output_path is None:
        return 0
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if not plugin_root:
        return 0
    environment = os.environ.copy()
    environment["CODEX_DELEGATE_RUNNER_WAIT_SECONDS"] = "110"
    environment["CODEX_DELEGATE_RUNNER_STARTUP_SECONDS"] = "60"
    try:
        result = subprocess.run(  # noqa: S603 -- executes the plugin's own launcher path
            [os.path.join(plugin_root, "bin", "codex-delegate"), "runner-wait", output_path],
            capture_output=True,
            text=True,
            timeout=115,
            env=environment,
            check=False,
        )
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0
    if result.returncode == 0 and result.stdout.strip() == "RUNNING":
        sys.stderr.write(CORRECTION)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
