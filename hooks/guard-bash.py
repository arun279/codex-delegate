#!/usr/bin/env python3
# ruff: noqa: UP006, UP035, UP045 -- runtime supports Python 3.9
"""Block unsupervised Codex turns started from Bash or Monitor tool input.

The parser follows executable positions through common wrappers and code sinks. Text
that merely mentions Codex is data and has no bearing on the decision. Unknown or
invalid shell syntax fails open. To override the hook, start Claude Code with
CODEX_DELEGATE_GUARD_BASH_OVERRIDE=1 in its environment.
"""

from __future__ import annotations

import ast
import json
import os
import re
import shlex
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Dict, List, Literal, Optional, Tuple, Union

OVERRIDE_ENV = "CODEX_DELEGATE_GUARD_BASH_OVERRIDE"
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\+?)=")
SHELLS = frozenset(
    {"bash", "csh", "dash", "fish", "ksh", "powershell", "pwsh", "sh", "tcsh", "xonsh", "zsh"}
)
CODEX_PROGRAMS = frozenset(
    {
        "codex",
        "codex-exec",
        "codex-app-server",
        "codex-mcp-server",
        "codex-code-mode-host",
        "codex-tui",
    }
)
SERVER_PROGRAMS = CODEX_PROGRAMS - {"codex"}
TURN_SUBCOMMANDS = frozenset(
    {"exec", "review", "resume", "mcp", "mcp-server", "app-server", "proto"}
)
VALID_SANDBOXES = frozenset({"read-only", "workspace-write", "danger-full-access"})
WRAPPERS = frozenset(
    {"caffeinate", "command", "env", "exec", "nice", "nohup", "setsid", "stdbuf", "sudo", "time"}
)
SEPARATORS = frozenset({"\n", ";", ";;", "&", "&&", "|", "||", "|&", "(", ")", "{", "}"})
REDIRECTIONS = frozenset({"<", ">", "<<", "<<-", ">>", "<<<", "<>", ">&", "<&", ">|"})
HOOK_COMMANDS = {
    "GIT_EXTERNAL_DIFF": frozenset({"git"}),
    "GIT_SSH_COMMAND": frozenset({"git"}),
    "GIT_PAGER": frozenset({"git"}),
    "PAGER": frozenset({"git", "man"}),
}

REASON = (
    "Blocked: a possible Codex CLI launch could not be proved inert. Model turns and Codex "
    "servers must be started by `codex-delegate`, which owns the sandbox flag, approval config, "
    "prompt stdin, process group, deadline and teardown, and parses the JSON event stream. "
    "Do not rework this command. If you are the calling agent, hand the job to the "
    "codex-delegate:runner agent type and read the `codex-delegate:routing` skill for the call shape. If you are "
    "the codex-delegate:runner agent, use `codex-delegate run` exactly as instructed. For a "
    "false deny, relaunch Claude Code with CODEX_DELEGATE_GUARD_BASH_OVERRIDE=1 in its parent "
    "environment; assigning that variable inside this command cannot change the hook's "
    "already-inherited environment."
)

PartKind = Literal["literal", "variable", "parameter", "command"]
Part = Tuple[PartKind, str]
Redirect = Tuple[str, "Word"]
Variables = Dict[str, str]
TokenValue = Union["Word", str]


@dataclass(frozen=True)
class Word:
    parts: Tuple[Part, ...]
    raw: str


@dataclass(frozen=True)
class SimpleCommand:
    words: Tuple[Word, ...]
    redirects: Tuple[Redirect, ...]
    before: Optional[str]
    after: Optional[str]


@dataclass(frozen=True)
class Heredoc:
    header: str
    body: str
    quoted: bool


def _append_literal(parts: List[Part], value: str) -> None:
    if not value:
        return
    if parts and parts[-1][0] == "literal":
        parts[-1] = ("literal", parts[-1][1] + value)
    else:
        parts.append(("literal", value))


def _consume_dollar_paren(source: str, start: int) -> Tuple[str, int, bool]:
    index, depth, quote = start + 2, 1, None
    while index < len(source):
        char = source[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
        elif quote == '"':
            if char == "\\":
                index += 2
            elif char == '"':
                quote = None
                index += 1
            else:
                index += 1
        elif char in "'\"":
            quote = char
            index += 1
        elif char == "\\":
            index += 2
        elif source.startswith("$(", index):
            depth += 1
            index += 2
        elif char == "(":
            depth += 1
            index += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start + 2 : index], index + 1, True
            index += 1
        else:
            index += 1
    return source[start + 2 :], len(source), False


def _consume_backticks(source: str, start: int) -> Tuple[str, int, bool]:
    index = start + 1
    while index < len(source):
        if source[index] == "\\":
            index += 2
        elif source[index] == "`":
            return source[start + 1 : index], index + 1, True
        else:
            index += 1
    return source[start + 1 :], len(source), False


def _consume_parameter(source: str, start: int) -> Tuple[str, int, bool]:
    index, depth = start + 2, 1
    while index < len(source):
        if source[index] == "\\":
            index += 2
        elif source.startswith("${", index):
            depth += 1
            index += 2
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 2 : index], index + 1, True
            index += 1
        else:
            index += 1
    return source[start + 2 :], len(source), False


def _unescape(source: str) -> Optional[str]:
    try:
        return bytes(source, "utf-8").decode("unicode_escape")
    except UnicodeError:
        return None


MASK_PREFIX = "__CODEX_DELEGATE_GUARD_PART_"
NEWLINE_TOKEN = f"{MASK_PREFIX}NEWLINE__"


def _mask_expansions(source: str) -> Optional[Tuple[str, List[Part]]]:
    if MASK_PREFIX in source:
        return None
    output: List[str] = []
    parts: List[Part] = []
    index, quote = 0, None

    def mask(part: Part) -> None:
        output.append(f"{MASK_PREFIX}{len(parts)}__")
        parts.append(part)

    while index < len(source):
        char = source[index]
        if quote == "'":
            output.append(char)
            if char == "'":
                quote = None
            index += 1
        elif char == "\\":
            output.append(source[index : index + 2])
            index += 2
        elif char == "'" and quote is None:
            output.append(char)
            quote = "'"
            index += 1
        elif char == '"':
            output.append(char)
            quote = None if quote == '"' else '"'
            index += 1
        elif char == "\n" and quote is None:
            output.append(f"\n{NEWLINE_TOKEN}\n")
            index += 1
        elif source.startswith("$'", index) and quote is None:
            end, ansi_parts = index + 2, []
            while end < len(source) and source[end] != "'":
                width = 2 if source[end] == "\\" and end + 1 < len(source) else 1
                ansi_parts.append(source[end : end + width])
                end += width
            value = _unescape("".join(ansi_parts)) if end < len(source) else None
            if value is None:
                return None
            mask(("literal", value))
            index = end + 1
        elif source.startswith("$(", index):
            expansion, index, closed = _consume_dollar_paren(source, index)
            if not closed:
                return None
            mask(("command", expansion))
        elif source.startswith("${", index):
            expansion, index, closed = _consume_parameter(source, index)
            if not closed:
                return None
            mask(("parameter", expansion))
        elif char == "$":
            match = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)", source[index:])
            if match is None:
                output.append(char)
                index += 1
            else:
                mask(("variable", match.group(1)))
                index += len(match.group(0))
        elif char == "`":
            expansion, index, closed = _consume_backticks(source, index)
            if not closed:
                return None
            mask(("command", expansion))
        else:
            output.append(char)
            index += 1
    return ("".join(output), parts) if quote is None else None


def _word_from_token(token: str, masked_parts: Sequence[Part]) -> Optional[Word]:
    parts: List[Part] = []
    pattern = re.compile(re.escape(MASK_PREFIX) + r"(\d+)__")
    cursor = 0
    for match in pattern.finditer(token):
        _append_literal(parts, token[cursor : match.start()])
        part_index = int(match.group(1))
        if part_index >= len(masked_parts):
            return None
        kind, value = masked_parts[part_index]
        if kind == "literal":
            _append_literal(parts, value)
        else:
            parts.append((kind, value))
        cursor = match.end()
    _append_literal(parts, token[cursor:])
    return Word(tuple(parts), token)


def _tokenize(source: str, require_balanced: bool = True) -> Optional[List[TokenValue]]:
    masked = _mask_expansions(source)
    if masked is None:
        return None
    text, parts = masked
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    try:
        raw_tokens = list(lexer)
    except ValueError:
        return None
    tokens: List[TokenValue] = []
    depth = 0
    for raw in raw_tokens:
        if raw == NEWLINE_TOKEN:
            tokens.append("\n")
        elif raw in SEPARATORS or raw in REDIRECTIONS:
            depth += int(raw == "(") - int(raw == ")")
            if depth < 0:
                return None
            tokens.append(raw)
        else:
            word = _word_from_token(raw, parts)
            if word is None:
                return None
            tokens.append(word)
    return tokens if not require_balanced or depth == 0 else None


def _simple_commands(tokens: Sequence[TokenValue]) -> List[SimpleCommand]:
    commands: List[SimpleCommand] = []
    words: List[Word] = []
    redirects: List[Redirect] = []
    pending: Optional[str] = None
    before: Optional[str] = None

    def finish(after: Optional[str]) -> None:
        nonlocal before
        if words or redirects:
            commands.append(SimpleCommand(tuple(words), tuple(redirects), before, after))
        words.clear()
        redirects.clear()
        before = after

    for token in tokens:
        if isinstance(token, str):
            operator = token
            if operator in REDIRECTIONS:
                if words and words[-1].raw.isdigit():
                    words.pop()
                pending = operator
            elif operator in SEPARATORS:
                pending = None
                finish(operator)
            continue
        if pending is not None:
            redirects.append((pending, token))
            pending = None
        else:
            words.append(token)
    finish(None)
    return commands


def _strip_heredoc_bodies(command: str) -> Optional[Tuple[str, List[Heredoc]]]:
    if "<<" not in command:
        return command, []
    lines = command.splitlines(True)
    kept: List[str] = []
    completed: List[Heredoc] = []
    index = 0
    while index < len(lines):
        header = lines[index]
        tokens = _tokenize(header, require_balanced=False)
        while tokens is None and index + 1 < len(lines):
            index += 1
            header += lines[index]
            tokens = _tokenize(header, require_balanced=False)
        if tokens is None:
            return None
        kept.append(header)
        specs: List[Tuple[str, bool]] = []
        for token_index, lexeme in enumerate(tokens[:-1]):
            next_token = tokens[token_index + 1]
            if lexeme != "<<" or not isinstance(next_token, Word):
                continue
            raw = next_token.raw
            strip_tabs = raw.startswith("-")
            delimiter = raw[1:] if strip_tabs else raw
            if delimiter:
                specs.append((delimiter, strip_tabs))
        for delimiter, strip_tabs in specs:
            body: List[str] = []
            index += 1
            while index < len(lines):
                line = lines[index]
                logical = line.removesuffix("\n")
                if (logical.lstrip("\t") if strip_tabs else logical) == delimiter:
                    break
                body.append(line.lstrip("\t") if strip_tabs else line)
                index += 1
            if index >= len(lines):
                return None
            completed.append(
                Heredoc(header, "".join(body), bool(re.search(r"<<-?\s*['\"]", header)))
            )
        index += 1
    if not kept:
        return None
    return "".join(kept), completed


def _program_name(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    name = re.split(r"[\\/]", value)[-1].lower()
    return name.removesuffix(".exe")


def _resolve_parameter(body: str, variables: Variables) -> Optional[str]:
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):?([-+=?])(.*)$", body, re.DOTALL)
    if match is not None:
        name, operator, alternative = match.groups()
        current = variables.get(name)
        if operator == "+":
            return alternative if current not in (None, "") else ""
        if current not in (None, ""):
            return current
        return alternative if operator in ("-", "=") else None
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", body):
        return variables.get(body)
    return None


def _resolve_word(word: Word, variables: Variables) -> Optional[str]:
    values: List[str] = []
    for kind, value in word.parts:
        if kind == "literal":
            values.append(value)
        elif kind == "variable":
            if value == "SHELL" and value not in variables:
                values.append("sh")
            elif value in variables:
                values.append(variables[value])
            else:
                return None
        elif kind == "parameter":
            resolved = _resolve_parameter(value, variables)
            if resolved is None:
                return None
            values.append(resolved)
        else:
            resolved = _infer_output(value, variables)
            if resolved is None:
                return None
            values.append(resolved.rstrip("\n"))
    return "".join(values)


def _assignment(word: Word, variables: Variables) -> Optional[Tuple[str, Optional[str]]]:
    match = ASSIGNMENT.match(word.raw)
    if match is None:
        return None
    name, append = match.groups()
    resolved = _resolve_word(word, variables)
    prefix = name + ("+=" if append else "=")
    if resolved is None or not resolved.startswith(prefix):
        return name, None
    value = resolved[len(prefix) :]
    if append:
        current = variables.get(name)
        return name, None if current is None else current + value
    return name, value


def _local_command(
    simple: SimpleCommand, variables: Variables
) -> Tuple[Variables, Tuple[Word, ...], Dict[str, str]]:
    local = dict(variables)
    assigned: Dict[str, str] = {}
    index = 0
    while index < len(simple.words):
        item = _assignment(simple.words[index], local)
        if item is None:
            break
        name, value = item
        if value is None:
            local.pop(name, None)
        else:
            local[name] = value
            assigned[name] = value
        index += 1
    return local, simple.words[index:], assigned


def _sandbox_is_invalid(args: Sequence[Optional[str]]) -> bool:
    for index, arg in enumerate(args):
        if arg in ("-s", "--sandbox"):
            return index + 1 < len(args) and args[index + 1] not in VALID_SANDBOXES
        if arg is not None and arg.startswith("--sandbox="):
            return arg.removeprefix("--sandbox=") not in VALID_SANDBOXES
    return False


def _first_subcommand(args: Sequence[Optional[str]]) -> Optional[str]:
    takes_value = frozenset(
        {
            "-a",
            "--ask-for-approval",
            "-c",
            "--config",
            "-C",
            "--cd",
            "--disable",
            "--enable",
            "-m",
            "--model",
            "--oss-provider",
            "-p",
            "--profile",
            "-s",
            "--sandbox",
        }
    )
    index = 0
    while index < len(args):
        arg = args[index]
        if arg is None:
            return None
        if arg == "--":
            return args[index + 1] if index + 1 < len(args) else None
        if arg in takes_value:
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            return arg
    return None


def _codex_starts(program: str, args: Sequence[Optional[str]]) -> bool:
    name = _program_name(program)
    if name not in CODEX_PROGRAMS:
        return False
    option_end = next((index for index, arg in enumerate(args) if arg == "--"), len(args))
    option_args = args[:option_end]
    if any(arg in ("--help", "-h") for arg in option_args):
        return False
    if any(arg in ("--version", "-V") for arg in option_args):
        return False
    if name in SERVER_PROGRAMS:
        return True
    subcommand = _first_subcommand(args)
    if subcommand not in TURN_SUBCOMMANDS:
        return False
    if _sandbox_is_invalid(option_args):
        return False
    return not (subcommand == "exec" and "--ask-for-approval" in option_args[1:])


def _split_wrapper(values: Sequence[Optional[str]], index: int, program: str) -> Optional[int]:
    value_options = {
        "caffeinate": frozenset({"-t", "-w"}),
        "env": frozenset({"-u", "--unset", "-C", "--chdir"}),
        "exec": frozenset({"-a"}),
        "nice": frozenset({"-n", "--adjustment"}),
        "stdbuf": frozenset({"-i", "-o", "-e", "--input", "--output", "--error"}),
        "sudo": frozenset({"-C", "-D", "-g", "-h", "-p", "-R", "-r", "-t", "-U", "-u"}),
        "time": frozenset({"-o", "-f"}),
    }
    cursor = index + 1
    while cursor < len(values):
        arg = values[cursor]
        if arg is None:
            return None
        if arg == "--":
            return cursor + 1
        if program == "env" and ASSIGNMENT.match(arg):
            cursor += 1
        elif arg in value_options.get(program, frozenset()):
            cursor += 2
        elif arg.startswith("-"):
            if program == "command" and arg in ("-v", "-V"):
                return None
            cursor += 1
        else:
            return cursor
    return None


def _unwrap(values: Sequence[Optional[str]]) -> Optional[Tuple[str, Sequence[Optional[str]]]]:
    index = 0
    while index < len(values):
        value = values[index]
        name = _program_name(value)
        if value is None or name is None:
            return None
        if name not in WRAPPERS:
            return value, values[index + 1 :]
        next_index = _split_wrapper(values, index, name)
        if next_index is None or next_index >= len(values):
            return None
        index = next_index
    return None


def _option_code(args: Sequence[Optional[str]]) -> Tuple[Optional[str], bool]:
    for index, arg in enumerate(args):
        if arg is not None and arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]:
            return (args[index + 1] if index + 1 < len(args) else None), True
    return None, False


def _first_script(args: Sequence[Optional[str]]) -> Optional[str]:
    value_options = frozenset({"-O", "-o"})
    index = 0
    while index < len(args):
        arg = args[index]
        if arg is None:
            return None
        if arg in value_options:
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            return arg
    return None


def _static_node_string(node: ast.AST) -> Optional[str]:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = _static_node_string(node.left)
        right = _static_node_string(node.right)
        return None if left is None or right is None else left + right
    return None


def _static_node_argv(node: ast.AST) -> Optional[List[str]]:
    if not isinstance(node, (ast.List, ast.Tuple)):
        return None
    result: List[str] = []
    for item in node.elts:
        value = _static_node_string(item)
        if value is None:
            return None
        result.append(value)
    return result


def _call_name(call: ast.Call) -> Optional[str]:
    if isinstance(call.func, ast.Name):
        return call.func.id
    if isinstance(call.func, ast.Attribute) and isinstance(call.func.value, ast.Name):
        return f"{call.func.value.id}.{call.func.attr}"
    return None


def _python_starts(code: str, variables: Variables, staged: Dict[str, str]) -> bool:
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return False
    shell_calls = frozenset(
        {"os.system", "os.popen", "subprocess.getoutput", "subprocess.getstatusoutput"}
    )
    process_methods = frozenset({"run", "call", "check_call", "check_output", "Popen"})
    process_calls = {f"subprocess.{method}" for method in process_methods}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "subprocess":
                    prefix = alias.asname or alias.name
                    process_calls.update(f"{prefix}.{method}" for method in process_methods)
        elif isinstance(node, ast.ImportFrom) and node.module == "subprocess":
            process_calls.update(
                alias.asname or alias.name for alias in node.names if alias.name in process_methods
            )
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = _call_name(node)
        if name in shell_calls and node.args:
            value = _static_node_string(node.args[0])
            if value is not None and _scan_shell(value, dict(variables), dict(staged)):
                return True
        elif name in process_calls:
            argument = (
                node.args[0]
                if node.args
                else next(
                    (keyword.value for keyword in node.keywords if keyword.arg == "args"), None
                )
            )
            if argument is None:
                continue
            shell = any(
                keyword.arg == "shell"
                and isinstance(keyword.value, ast.Constant)
                and keyword.value.value is True
                for keyword in node.keywords
            )
            value = _static_node_string(argument)
            argv = _static_node_argv(argument)
            if shell and value is not None and _scan_shell(value, dict(variables), dict(staged)):
                return True
            if not shell and argv is not None and _values_start(argv, variables, staged, None):
                return True
        elif name in {"os.execl", "os.execlp"} and len(node.args) >= 2:
            program = _static_node_string(node.args[0])
            argv_values: List[Optional[str]] = [_static_node_string(item) for item in node.args[2:]]
            if program is not None and _values_start(
                [program, *argv_values], variables, staged, None
            ):
                return True
        elif name in {"os.execv", "os.execvp"} and len(node.args) >= 2:
            program = _static_node_string(node.args[0])
            argv = _static_node_argv(node.args[1])
            if (
                program is not None
                and argv is not None
                and _values_start([program, *argv[1:]], variables, staged, None)
            ):
                return True
    return False


def _embedded_shell_starts(code: str, variables: Variables, staged: Dict[str, str]) -> bool:
    patterns = (
        r"(?is)\bdo\s+shell\s+script\s+([\"'])(.*?)\1",
        r"(?is)\bsystem\s*\(\s*([\"'])(.*?)\1",
    )
    for pattern in patterns:
        for match in re.finditer(pattern, code):
            body = _unescape(match.group(2))
            if body is None:
                continue
            if _scan_shell(body, dict(variables), dict(staged)):
                return True
    return False


def _values_start(
    values: Sequence[Optional[str]],
    variables: Variables,
    staged: Dict[str, str],
    piped_code: Optional[str],
) -> bool:
    if not values or values[0] is None:
        return False
    first_name = _program_name(values[0])
    if first_name == "env":
        for index, value in enumerate(values[1:], start=1):
            if value in ("-S", "--split-string") and index + 1 < len(values):
                split = values[index + 1]
                if split is None:
                    return False
                try:
                    return _values_start(shlex.split(split), variables, staged, piped_code)
                except ValueError:
                    return False
            if value is not None and value.startswith("--split-string="):
                try:
                    return _values_start(
                        shlex.split(value.removeprefix("--split-string=")),
                        variables,
                        staged,
                        piped_code,
                    )
                except ValueError:
                    return False
    effective = _unwrap(values)
    if effective is None:
        return False
    program, args = effective
    name = _program_name(program)
    if name == "codex-delegate":
        return False
    if _codex_starts(program, args):
        return True
    if program in staged and _scan_shell(staged[program], dict(variables), dict(staged)):
        return True
    if name in SHELLS:
        code, has_code = _option_code(args)
        if has_code:
            return code is not None and _scan_shell(code, dict(variables), dict(staged))
        script = _first_script(args)
        if script in staged:
            return _scan_shell(staged[script], dict(variables), dict(staged))
        return piped_code is not None and _scan_shell(piped_code, dict(variables), dict(staged))
    if name == "eval":
        code = " ".join(value for value in args if value is not None)
        return bool(code) and _scan_shell(code, dict(variables), dict(staged))
    if name in {"python", "python3"}:
        for index, arg in enumerate(args):
            if arg == "-c" and index + 1 < len(args) and args[index + 1] is not None:
                return _python_starts(args[index + 1] or "", variables, staged)
    if name in {"awk", "osascript", "perl", "ruby", "node"}:
        for index, arg in enumerate(args):
            if (
                arg in ("-e", "--eval")
                and index + 1 < len(args)
                and args[index + 1] is not None
                and _embedded_shell_starts(args[index + 1] or "", variables, staged)
            ):
                return True
        if name == "awk" and args and args[0] is not None:
            return _embedded_shell_starts(args[0] or "", variables, staged)
    if name == "npx":
        cursor = 0
        while cursor < len(args):
            arg = args[cursor]
            if arg is None:
                return False
            if arg in ("-p", "--package", "-c", "--call"):
                cursor += 2
            elif arg.startswith("-"):
                cursor += 1
            else:
                return _values_start(args[cursor:], variables, staged, piped_code)
        return False
    if name == "script":
        cursor = 0
        while cursor < len(args):
            arg = args[cursor]
            if arg is None or not arg.startswith("-"):
                break
            cursor += 1
        return cursor + 1 < len(args) and _values_start(
            args[cursor + 1 :], variables, staged, piped_code
        )
    if name == "xargs":
        cursor = 0
        value_options = frozenset({"-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s"})
        while cursor < len(args):
            arg = args[cursor]
            if arg is None:
                return False
            if arg in value_options:
                cursor += 2
            elif arg.startswith("-"):
                cursor += 1
            else:
                return _values_start(args[cursor:], variables, staged, piped_code)
        return False
    if name == "find":
        for cursor, arg in enumerate(args):
            if arg in ("-exec", "-execdir"):
                end = next(
                    (index for index in range(cursor + 1, len(args)) if args[index] in (";", "+")),
                    len(args),
                )
                if _values_start(args[cursor + 1 : end], variables, staged, piped_code):
                    return True
    return False


def _format_printf(args: Sequence[str]) -> Optional[str]:
    if not args:
        return None
    template = args[0].replace("\\n", "\n").replace("\\t", "\t")
    values = list(args[1:])
    output: List[str] = []
    index, value_index = 0, 0
    while index < len(template):
        if template.startswith("%%", index):
            output.append("%")
            index += 2
        elif template.startswith(("%s", "%b"), index):
            if value_index >= len(values):
                return None
            value = values[value_index]
            if template.startswith("%b", index):
                decoded = _unescape(value)
                if decoded is None:
                    return None
                value = decoded
            output.append(value)
            value_index += 1
            index += 2
        elif template[index] == "%":
            return None
        else:
            output.append(template[index])
            index += 1
    return "".join(output)


def _static_output(simple: SimpleCommand, variables: Variables) -> Optional[str]:
    local, words, _ = _local_command(simple, variables)
    values = [_resolve_word(word, local) for word in words]
    if not values or any(value is None for value in values):
        return None
    known = [value or "" for value in values]
    name = _program_name(known[0])
    if name == "echo":
        args = known[1:]
        if args and args[0] == "-n":
            return " ".join(args[1:])
        return " ".join(args) + "\n"
    if name == "printf":
        return _format_printf(known[1:])
    if name in {"which", "type"} and len(known) == 2:
        return known[1]
    return None


def _infer_output(source: str, variables: Variables) -> Optional[str]:
    tokens = _tokenize(source)
    if tokens is None:
        return None
    commands = _simple_commands(tokens)
    if len(commands) != 1:
        return None
    return _static_output(commands[0], variables)


def _scan_word_substitutions(
    words: Sequence[Word], variables: Variables, staged: Dict[str, str]
) -> bool:
    for word in words:
        for kind, body in word.parts:
            if kind == "command" and _scan_shell(body, dict(variables), dict(staged)):
                return True
    return False


def _scan_expansions(source: str, variables: Variables, staged: Dict[str, str]) -> bool:
    index = 0
    while index < len(source):
        if source.startswith("$(", index):
            body, index, closed = _consume_dollar_paren(source, index)
            if not closed:
                return False
            if _scan_shell(body, dict(variables), dict(staged)):
                return True
        elif source[index] == "`":
            body, index, closed = _consume_backticks(source, index)
            if not closed:
                return False
            if _scan_shell(body, dict(variables), dict(staged)):
                return True
        else:
            index += 1
    return False


def _record_stage(
    simple: SimpleCommand, output: Optional[str], variables: Variables, staged: Dict[str, str]
) -> None:
    if output is None:
        return
    for operator, word in simple.redirects:
        if operator not in (">", ">|", ">>"):
            continue
        path = _resolve_word(word, variables)
        if path is None:
            continue
        if operator == ">>":
            staged[path] = staged.get(path, "") + output
        else:
            staged[path] = output


def _inspect_simple(
    simple: SimpleCommand,
    variables: Variables,
    staged: Dict[str, str],
    piped_code: Optional[str],
) -> bool:
    local, words, assigned = _local_command(simple, variables)
    if _scan_word_substitutions(simple.words, local, staged):
        return True
    if not words:
        if simple.after not in ("|", "|&"):
            variables.update(assigned)
        return False
    first = _resolve_word(words[0], local)
    first_name = _program_name(first)
    if first_name in {"declare", "export", "local", "readonly", "typeset"}:
        declarations: Dict[str, str] = {}
        for word in words[1:]:
            item = _assignment(word, local)
            if item is not None and item[1] is not None:
                local[item[0]] = item[1]
                declarations[item[0]] = item[1]
        if simple.after not in ("|", "|&"):
            variables.update(declarations)
        return False
    values = [_resolve_word(word, local) for word in words]
    if values and values[0] is not None and _values_start(values, local, staged, piped_code):
        return True
    host = _program_name(values[0] if values else None)
    for name, value in assigned.items():
        if host in HOOK_COMMANDS.get(name, frozenset()) and _scan_shell(
            value, dict(local), dict(staged)
        ):
            return True
    return False


def _heredoc_starts(heredoc: Heredoc, variables: Variables, staged: Dict[str, str]) -> bool:
    tokens = _tokenize(heredoc.header)
    if tokens is None:
        return False
    commands = _simple_commands(tokens)
    for simple in commands:
        local, words, _ = _local_command(simple, variables)
        values = [_resolve_word(word, local) for word in words]
        effective = _unwrap(values) if values else None
        if (
            effective is not None
            and _program_name(effective[0]) in SHELLS
            and (
                any(operator in ("<<", "<<-") for operator, _ in simple.redirects)
                or simple.before in ("|", "|&")
            )
            and _scan_shell(heredoc.body, dict(local), dict(staged))
        ):
            return True
        for operator, word in simple.redirects:
            if operator not in (">", ">|", ">>"):
                continue
            path = _resolve_word(word, local)
            if path is not None:
                if operator == ">>":
                    staged[path] = staged.get(path, "") + heredoc.body
                else:
                    staged[path] = heredoc.body
    return not heredoc.quoted and _scan_expansions(heredoc.body, variables, staged)


def _scan_shell(command: str, variables: Variables, staged: Dict[str, str]) -> bool:
    stripped = _strip_heredoc_bodies(command)
    if stripped is None:
        return False
    source, heredocs = stripped
    for heredoc in heredocs:
        if _heredoc_starts(heredoc, variables, staged):
            return True
    tokens = _tokenize(source)
    if tokens is None:
        return False
    commands = _simple_commands(tokens)
    previous_output: Optional[str] = None
    for simple in commands:
        piped = previous_output if simple.before in ("|", "|&") else None
        if _inspect_simple(simple, variables, staged, piped):
            return True
        output = _static_output(simple, variables)
        _record_stage(simple, output, variables, staged)
        previous_output = output
    return False


def starts_codex(command: str) -> bool:
    """Return whether parsed shell text starts an unsupervised Codex turn or server."""
    return _scan_shell(command, {}, {})


def main() -> int:
    try:
        payload: object = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") not in ("Bash", "Monitor"):
        return 0
    if os.environ.get(OVERRIDE_ENV) == "1":
        return 0
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0
    command = tool_input.get("command", "")
    if not isinstance(command, str):
        return 0
    try:
        deny = starts_codex(command)
    except Exception:  # noqa: BLE001 -- a hook parser failure must fail open
        deny = False
    if not deny:
        return 0
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": REASON,
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
