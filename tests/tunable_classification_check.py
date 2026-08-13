#!/usr/bin/env python3
"""Fail when a launcher numeric constant or environment name is unclassified."""

import ast
import sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())


def assigned(name: str) -> ast.expr:
    for statement in tree.body:
        if isinstance(statement, ast.Assign):
            if any(isinstance(target, ast.Name) and target.id == name for target in statement.targets):
                return statement.value
    raise SystemExit(f"missing classification declaration: {name}")


def dictionary_keys(name: str) -> set[str]:
    value = assigned(name)
    if not isinstance(value, ast.Dict):
        raise SystemExit(f"{name} is not a literal table")
    return {key.value for key in value.keys if isinstance(key, ast.Constant) and isinstance(key.value, str)}


def numeric_expression(node: ast.expr) -> bool:
    if isinstance(node, ast.Constant):
        return type(node.value) in (int, float)
    if isinstance(node, ast.UnaryOp):
        return isinstance(node.op, (ast.UAdd, ast.USub)) and numeric_expression(node.operand)
    if isinstance(node, ast.BinOp):
        return numeric_expression(node.left) and numeric_expression(node.right)
    return False


tunables = dictionary_keys("TUNABLES")
fixed = dictionary_keys("DELIBERATELY_FIXED")
required = {
    "DEADLINE",
    "RUNNER_WAIT_SECONDS",
    "RUNNER_STARTUP_SECONDS",
    "EVENT_LIMIT",
    "LINE_LIMIT",
    "READ_BATCH",
    "TERMINAL_SETTLE_LIMIT_SECONDS",
}
if not required <= tunables:
    raise SystemExit(f"operational tunables missing from TUNABLES: {sorted(required - tunables)}")

numeric_constants: set[str] = set()
for statement in tree.body:
    if isinstance(statement, ast.Assign) and numeric_expression(statement.value):
        numeric_constants.update(target.id for target in statement.targets if isinstance(target, ast.Name) and target.id.isupper())
    if (
        isinstance(statement, ast.AnnAssign)
        and isinstance(statement.target, ast.Name)
        and statement.target.id.isupper()
        and statement.value is not None
        and numeric_expression(statement.value)
    ):
        numeric_constants.add(statement.target.id)
unclassified = numeric_constants - tunables - fixed
if unclassified:
    raise SystemExit(f"unclassified numeric constants: {sorted(unclassified)}")

specs = assigned("TUNABLES")
assert isinstance(specs, ast.Dict)
configured_environment = set()
for key, value in zip(specs.keys, specs.values):
    if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
        raise SystemExit("TUNABLES has a non-literal name")
    if not isinstance(value, ast.Call) or not value.args or not isinstance(value.args[0], ast.Constant):
        raise SystemExit(f"{key.value} has no literal environment variable")
    environment = value.args[0].value
    if environment != f"CODEX_DELEGATE_{key.value}":
        raise SystemExit(f"{key.value} breaks the environment naming convention")
    configured_environment.add(environment)

non_tunable = assigned("NON_TUNABLE_ENVIRONMENT")
if not isinstance(non_tunable, (ast.Tuple, ast.List)):
    raise SystemExit("NON_TUNABLE_ENVIRONMENT is not a literal list")
accounted_environment = configured_environment | {
    item.value for item in non_tunable.elts if isinstance(item, ast.Constant) and isinstance(item.value, str)
}
used_environment = set()
for node in ast.walk(tree):
    if not isinstance(node, ast.Call) or not node.args:
        continue
    function = node.func
    if not isinstance(function, ast.Attribute) or function.attr != "get":
        continue
    owner = function.value
    if not (isinstance(owner, ast.Attribute) and owner.attr == "environ" and isinstance(owner.value, ast.Name) and owner.value.id == "os"):
        continue
    argument = node.args[0]
    if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
        used_environment.add(argument.value)
unaccounted_environment = {name for name in used_environment if name.startswith("CODEX_DELEGATE_") and name not in accounted_environment}
if unaccounted_environment:
    raise SystemExit(f"unaccounted CODEX_DELEGATE environment hooks: {sorted(unaccounted_environment)}")
