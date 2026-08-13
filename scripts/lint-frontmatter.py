#!/usr/bin/env python3
"""Frontmatter gate for this plugin's agents and skills.

`claude plugin validate` reads skill frontmatter properly. For agents it checks exactly one field:
a missing `description` is a warning, which `--strict` turns into a failure. Everything else about
an agent passes with exit 0 and no output, including no `name`, `isolation: bogus`, `model:
not-a-real-model`, `effort: banana`, `maxTurns: not-a-number` and an unsupported `hooks:` block.
The loader is no stricter: an agent key it does not act on is dropped without a word, the one
exception being `permissionMode`, which it warns is ignored for plugin agents. The rules below
close that gap.

The parser is small on purpose. Frontmatter here is flat key/value with at most one list or block
scalar, so a YAML dependency would buy nothing. What it cannot read is a failure rather than a skip:
a gate that passes the files it does not understand has stopped being a gate.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Union, cast

ROOT = Path(__file__).resolve().parent.parent

AGENT_KEYS = (
    "name",
    "description",
    "model",
    "effort",
    "maxTurns",
    "tools",
    "disallowedTools",
    "skills",
    "memory",
    "background",
    "isolation",
)
EFFORTS = ("low", "medium", "high", "xhigh", "max")
# The aliases documented for Claude Code, plus `inherit`, which only an agent can use. Full model
# names change independently of this repository, so validate their structure rather than keeping a
# family allowlist that becomes stale at every model launch. A version component (or the documented
# preview marker) distinguishes a model name from a value such as `claude-not-real`.
MODELS = (
    "best",
    "default",
    "fable",
    "haiku",
    "inherit",
    "opus",
    "opus[1m]",
    "opusplan",
    "sonnet",
    "sonnet[1m]",
)
FULL_MODEL = re.compile(
    r"^claude-(?=[a-z0-9-]*(?:[0-9]|preview(?:-|$)))"
    r"[a-z0-9]+(?:-[a-z0-9]+)*(?:\[[1-9][0-9]*m\])?(?:@[0-9]+)?$"
)
SLUG = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
BLOCK = ("|", "|-", "|+", ">", ">-", ">+")
FrontmatterValue = Union[str, list[str]]
Frontmatter = dict[str, FrontmatterValue]


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def parse_frontmatter(path: Path) -> Frontmatter:
    lines = path.read_text(encoding="utf-8").split("\n")
    if not lines or lines[0].strip() != "---":
        raise ValueError("no frontmatter, the file must open with a --- line")
    close = next((index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---"), None)
    if close is None:
        raise ValueError("frontmatter is never closed by a --- line")

    data: Frontmatter = {}
    blocks: dict[str, str] = {}
    key: str | None = None
    style: str | None = None
    for number, line in enumerate(lines[1:close], start=2):
        if style is not None and (not line.strip() or line[:1] in (" ", "\t")):
            cast(list[str], data[cast(str, key)]).append(line.strip())
            continue
        style = None
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[:1] in (" ", "\t"):
            item = line.strip()
            if key is None or not isinstance(data[key], list) or not item.startswith("- "):
                raise ValueError(f"line {number} is indented but is not a list item under a key")
            cast(list[str], data[key]).append(unquote(item[2:].strip()))
            continue
        key, separator, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if not separator:
            raise ValueError(f"line {number} is not 'key: value'")
        if key in data:
            raise ValueError(f"line {number} repeats the key '{key}'")
        if value in BLOCK:
            blocks[key] = style = value
            data[key] = []
        elif value.startswith("[") and value.endswith("]"):
            data[key] = [unquote(item.strip()) for item in value[1:-1].split(",") if item.strip()]
        else:
            data[key] = unquote(value) if value else []

    for field, marker in blocks.items():
        data[field] = ("\n" if marker[0] == "|" else " ").join(cast(list[str], data[field])).strip()
    return data


def require_text(data: Frontmatter, key: str) -> list[str]:
    value = data.get(key)
    if not value:
        return [f"missing {key}"]
    if not isinstance(value, str):
        return [f"{key} must be a string, not a list"]
    return []


def check_common(data: Frontmatter) -> list[str]:
    problems = require_text(data, "name") + require_text(data, "description")
    name = data.get("name")
    if isinstance(name, str) and name and not SLUG.match(name):
        problems.append(f"name {name!r} is not a lowercase slug ({SLUG.pattern}); it is the last segment of <plugin>:<name>")
    return problems


def check_agent(data: Frontmatter) -> list[str]:
    problems: list[str] = []
    unsupported = sorted(set(data) - set(AGENT_KEYS))
    if unsupported:
        problems.append(f"unsupported key(s) {', '.join(unsupported)}. The keys this repo's agents may set are: {', '.join(AGENT_KEYS)}")
    model = data.get("model")
    if model and not (isinstance(model, str) and (model in MODELS or FULL_MODEL.fullmatch(model))):
        problems.append(f"model {model!r} is not a documented model alias or a version-bearing claude-* model ID")
    effort = data.get("effort")
    if effort and effort not in EFFORTS:
        problems.append(f"effort {effort!r} is not one of {', '.join(EFFORTS)}")
    isolation = data.get("isolation")
    if isolation and isolation != "worktree":
        problems.append(f"isolation {isolation!r} is not worktree, the only value that does anything")
    turns = data.get("maxTurns")
    if turns and not (isinstance(turns, str) and turns.isdigit() and int(turns) > 0):
        problems.append(f"maxTurns {turns!r} is not a positive integer")
    background = data.get("background")
    if background and background not in ("true", "false"):
        problems.append(f"background {background!r} is not true or false")
    return problems


def main() -> int:
    # Claude Code walks agents/ recursively and does not walk skills/: an agents/nested/probe.md is
    # loaded, a skills/deep/nested/SKILL.md is not.
    targets = [(path, "agent") for path in sorted(ROOT.glob("agents/**/*.md"))]
    targets += [(path, "skill") for path in sorted(ROOT.glob("skills/*/SKILL.md"))]
    if not targets:
        print("FAIL no agent or skill frontmatter targets found")
        return 1

    failed = 0
    for path, kind in targets:
        relative = path.relative_to(ROOT)
        try:
            data = parse_frontmatter(path)
        except ValueError as error:
            print(f"FAIL {relative}: {error}")
            failed += 1
            continue
        problems = check_common(data) + (check_agent(data) if kind == "agent" else [])
        for problem in problems:
            print(f"FAIL {relative}: {problem}")
        if problems:
            failed += 1
        else:
            print(f"ok   {relative} ({kind})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
