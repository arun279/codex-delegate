"""Pin the launcher's complete top-level entry-point surface."""

from __future__ import annotations

import ast
import sys
from pathlib import Path

EXPECTED = {"run", "models", "runner-wait", "runner-report"}


def is_sys_argv_access(node: ast.AST) -> bool:
    return (
        isinstance(node, ast.Subscript)
        and isinstance(node.value, ast.Attribute)
        and isinstance(node.value.value, ast.Name)
        and node.value.value.id == "sys"
        and node.value.attr == "argv"
    )


def string_literals(node: ast.AST) -> set[str]:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return {node.value}
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        values: set[str] = set()
        for item in node.elts:
            values.update(string_literals(item))
        return values
    return set()


def entry_points(source: str) -> set[str]:
    tree = ast.parse(source)
    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and node.args:
            function = node.func
            if isinstance(function, ast.Attribute) and function.attr == "add_parser":
                found.update(string_literals(node.args[0]))
        if isinstance(node, ast.Compare):
            operands = [node.left, *node.comparators]
            for operator, left, right in zip(node.ops, operands, operands[1:]):
                if not isinstance(operator, (ast.Eq, ast.NotEq, ast.Is, ast.IsNot)):
                    continue
                if is_sys_argv_access(left):
                    found.update(string_literals(right))
                if is_sys_argv_access(right):
                    found.update(string_literals(left))
    return found


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: entrypoints_check.py LAUNCHER", file=sys.stderr)
        return 2
    source = Path(sys.argv[1]).read_text(encoding="utf-8")
    actual = entry_points(source)
    if actual != EXPECTED:
        print(
            f"entrypoints: FAIL: expected {sorted(EXPECTED)}, got {sorted(actual)}",
            file=sys.stderr,
        )
        return 1
    print("entrypoints: PASS: run, models, runner-wait, runner-report")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
