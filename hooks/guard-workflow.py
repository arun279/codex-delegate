#!/usr/bin/env python3
"""PreToolUse gate for statically recognizable codex-delegate Workflow calls.

Reject invalid prompts, wrapper overrides, and hidden labels only when object-literal options name
the exact static runner. Dynamic or malformed input passes untouched. Regex and template literals
are unsupported and fail open. Inline scripts and regular UTF-8 ``scriptPath`` inputs share a path.
"""

from __future__ import annotations

import json
import os
import stat
import sys
from typing import NamedTuple

GPT_AGENT = "codex-delegate:runner"
LABEL_PREFIX = "codex:"
FORBIDDEN = ("model", "effort", "tools")
MAX_SCRIPT_BYTES = 2 * 1024 * 1024
REAL_SIGNATURE = (
    "agent(prompt: string, opts?: {label?, phase?, schema?, model?, effort?, "
    "isolation?, agentType?})"
)

OPEN = {"(": ")", "[": "]", "{": "}"}
CLOSE = {value: key for key, value in OPEN.items()}
SIMPLE_ESCAPES = {
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
    "'": "'",
    '"': '"',
}


class Token(NamedTuple):
    kind: str
    value: str
    start: int
    complete: bool = True


class Property(NamedTuple):
    order: int
    key: str
    value: list[Token] | None


class ObjectCheck(NamedTuple):
    forbidden: tuple[str, ...]
    label: str | None


class Violation(NamedTuple):
    line: int
    forbidden: tuple[str, ...]
    label: str | None
    prompt: str | None


def _read_string(source: str, start: int, quote: str) -> tuple[int, str, bool] | None:
    value: list[str] = []
    complete = True
    index = start + 1
    while index < len(source):
        char = source[index]
        if char == "\\":
            index += 1
            if index >= len(source):
                return None
            escaped = source[index]
            if escaped in SIMPLE_ESCAPES:
                value.append(SIMPLE_ESCAPES[escaped])
            else:
                complete = False
            index += 1
        elif char == quote:
            return index + 1, "".join(value), complete
        elif char in "\r\n":
            return None
        else:
            value.append(char)
            index += 1
    return None


def _skip_block_comment(source: str, start: int) -> int | None:
    end = source.find("*/", start + 2)
    return None if end < 0 else end + 2


def _tokenize(source: str) -> list[Token] | None:
    tokens: list[Token] = []
    index = 0
    while index < len(source):
        char = source[index]
        if char.isspace():
            index += 1
        elif source.startswith("//", index):
            newline = source.find("\n", index + 2)
            index = len(source) if newline < 0 else newline + 1
        elif source.startswith("/*", index):
            comment_end = _skip_block_comment(source, index)
            if comment_end is None:
                return None
            index = comment_end
        elif char in "'\"":
            result = _read_string(source, index, char)
            if result is None:
                return None
            end, value, complete = result
            tokens.append(Token("literal", value, index, complete))
            index = end
        elif char in "`/":
            return None
        elif char.isalpha() or char in "_$":
            end = index + 1
            while end < len(source) and (source[end].isalnum() or source[end] in "_$"):
                end += 1
            tokens.append(Token("word", source[index:end], index))
            index = end
        elif char.isdigit():
            end = index + 1
            while end < len(source) and (source[end].isalnum() or source[end] in "._"):
                end += 1
            tokens.append(Token("number", source[index:end], index))
            index = end
        else:
            tokens.append(Token("punct", char, index))
            index += 1
    return tokens


def _pairs(tokens: list[Token]) -> dict[int, int] | None:
    pairs: dict[int, int] = {}
    stack: list[tuple[str, int]] = []
    for index, token in enumerate(tokens):
        if token.value in OPEN:
            stack.append((token.value, index))
        elif token.value in CLOSE:
            if not stack or stack[-1][0] != CLOSE[token.value]:
                return None
            _, opening = stack.pop()
            pairs[opening] = index
            pairs[index] = opening
    return None if stack else pairs


def _segments(
    tokens: list[Token], start: int, end: int, pairs: dict[int, int]
) -> list[tuple[int, int]]:
    segments: list[tuple[int, int]] = []
    segment_start = start
    index = start
    while index < end:
        if tokens[index].value in OPEN:
            index = pairs[index] + 1
        elif tokens[index].value == ",":
            segments.append((segment_start, index))
            segment_start = index + 1
            index += 1
        else:
            index += 1
    segments.append((segment_start, end))
    return segments


def _object_bounds(
    tokens: list[Token], segment: tuple[int, int], pairs: dict[int, int]
) -> tuple[int, int] | None:
    left, right = segment
    if left < right and tokens[left].value == "{" and pairs.get(left) == right - 1:
        return left, right - 1
    return None


def _property_key(token: Token) -> str | None:
    if token.kind == "word" or (token.kind == "literal" and token.complete):
        return token.value
    return None


def _properties(
    tokens: list[Token], opening: int, closing: int, pairs: dict[int, int]
) -> tuple[list[Property], list[int]]:
    properties: list[Property] = []
    opaque: list[int] = []
    segments = _segments(tokens, opening + 1, closing, pairs)
    for order, (left, right) in enumerate(segments):
        segment = tokens[left:right]
        if not segment:
            opaque.append(order)
            continue
        if len(segment) >= 3 and all(token.value == "." for token in segment[:3]):
            opaque.append(order)
            continue
        key = _property_key(segment[0])
        if key is None:
            opaque.append(order)
            continue
        if len(segment) >= 2 and segment[1].value == ":":
            value: list[Token] | None = segment[2:]
        elif len(segment) == 1 or segment[1].value in ("=", "("):
            value = None
        else:
            opaque.append(order)
            continue
        properties.append(Property(order, key, value))
    return properties, opaque


def _static_literal(tokens: list[Token] | None) -> str | None:
    if tokens is None or len(tokens) != 1:
        return None
    token = tokens[0]
    if token.kind != "literal" or not token.complete:
        return None
    return token.value


def _label_status(tokens: list[Token] | None) -> str:
    if tokens is None or len(tokens) != 1 or tokens[0].kind != "literal":
        return "unknown"
    token = tokens[0]
    if token.value.startswith(LABEL_PREFIX):
        return "valid"
    if not token.complete and LABEL_PREFIX.startswith(token.value):
        return "unknown"
    return "wrong"


def _inspect_runner_object(
    tokens: list[Token], opening: int, closing: int, pairs: dict[int, int]
) -> ObjectCheck | None:
    properties, opaque = _properties(tokens, opening, closing, pairs)
    agent_types = [prop for prop in properties if prop.key == "agentType"]
    if not agent_types:
        return None
    type_property = agent_types[-1]
    if any(order > type_property.order for order in opaque):
        return None
    if _static_literal(type_property.value) != GPT_AGENT:
        return None

    forbidden = tuple(key for key in FORBIDDEN if any(prop.key == key for prop in properties))
    labels = [prop for prop in properties if prop.key == "label"]
    label_issue: str | None = None
    if labels:
        label_property = labels[-1]
        if (
            not any(order > label_property.order for order in opaque)
            and _label_status(label_property.value) == "wrong"
        ):
            label_issue = "wrong"
    elif not opaque:
        label_issue = "missing"
    return ObjectCheck(forbidden, label_issue)


def _prompt_issue(
    tokens: list[Token], segment: tuple[int, int], pairs: dict[int, int]
) -> str | None:
    left, right = segment
    if left >= right:
        return None
    if _object_bounds(tokens, segment, pairs) is not None:
        return "object"
    prompt_tokens = tokens[left:right]
    if len(prompt_tokens) != 1:
        return None
    token = prompt_tokens[0]
    if token.kind == "literal" and token.complete and not token.value.strip():
        return "empty"
    if token.kind == "word" and token.value in ("null", "undefined"):
        return "missing"
    return None


def _violation_for_call(
    source: str,
    tokens: list[Token],
    call_open: int,
    call_close: int,
    pairs: dict[int, int],
) -> Violation | None:
    arguments = _segments(tokens, call_open + 1, call_close, pairs)
    if any(left >= right for left, right in arguments):
        return None

    prompt_issue: str | None
    if len(arguments) == 1:
        bounds = _object_bounds(tokens, arguments[0], pairs)
        if bounds is None:
            return None
        check = _inspect_runner_object(tokens, bounds[0], bounds[1], pairs)
        prompt_issue = "object"
    elif len(arguments) == 2:
        bounds = _object_bounds(tokens, arguments[1], pairs)
        if bounds is None:
            return None
        check = _inspect_runner_object(tokens, bounds[0], bounds[1], pairs)
        prompt_issue = _prompt_issue(tokens, arguments[0], pairs)
    else:
        return None

    if check is None:
        return None
    if not check.forbidden and check.label is None and prompt_issue is None:
        return None
    line = source.count("\n", 0, tokens[call_open].start) + 1
    return Violation(line, check.forbidden, check.label, prompt_issue)


def lint_script(source: str) -> list[Violation]:
    tokens = _tokenize(source)
    if tokens is None:
        return []
    pairs = _pairs(tokens)
    if pairs is None:
        return []
    violations: list[Violation] = []
    for index, token in enumerate(tokens[:-1]):
        if token.kind != "word" or token.value != "agent" or tokens[index + 1].value != "(":
            continue
        if index and (
            tokens[index - 1].value == "." or tokens[index - 1].value in ("function", "new")
        ):
            continue
        call_end = pairs.get(index + 1)
        if call_end is None:
            continue
        if call_end + 1 < len(tokens) and tokens[call_end + 1].value == "{":
            continue
        violation = _violation_for_call(source, tokens, index + 1, call_end, pairs)
        if violation is not None:
            violations.append(violation)
    return violations


def denial_reason(violations: list[Violation]) -> str:
    details: list[str] = []
    for violation in violations:
        problems: list[str] = []
        if violation.prompt == "object":
            problems.append("pass the prompt string as argument 1, not an object literal")
        elif violation.prompt == "empty":
            problems.append("argument 1 must be a non-empty prompt string")
        elif violation.prompt == "missing":
            problems.append("argument 1 is missing; pass a non-empty prompt string")
        if violation.forbidden:
            keys = ", ".join(f"{key}:" for key in violation.forbidden)
            problems.append(f"remove {keys}; call-site values override the pinned agent definition")
        if violation.label == "missing":
            problems.append("add label: 'codex:<purpose>' for the progress UI")
        elif violation.label == "wrong":
            problems.append("change label so it starts with 'codex:' for the progress UI")
        details.append(f"line {violation.line}: {'; '.join(problems)}")
    return (
        "Blocked Workflow codex-delegate:runner agent() call. "
        f"Real signature: {REAL_SIGNATURE}. " + " | ".join(details)
    )


def _workflow_script(tool_input: object) -> str | None:
    if not isinstance(tool_input, dict):
        return None
    script = tool_input.get("script")
    if isinstance(script, str) and script:
        return script
    path = tool_input.get("scriptPath")
    if not isinstance(path, str):
        return script if isinstance(script, str) else None
    try:
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SCRIPT_BYTES:
            return None
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (OSError, UnicodeError):
        return None


def main() -> int:
    try:
        payload: object = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") != "Workflow":
        return 0
    script = _workflow_script(payload.get("tool_input"))
    if script is None:
        return 0
    violations = lint_script(script)
    if not violations:
        return 0
    decision = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": denial_reason(violations),
        }
    }
    print(json.dumps(decision))
    return 0


if __name__ == "__main__":
    sys.exit(main())
