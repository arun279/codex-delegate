"""Run CI and release invariants."""

from __future__ import annotations

import ast
import json
import os
import re
import sys
import unicodedata
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from typing import cast

ROOT = Path(__file__).resolve().parent.parent
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")
SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
META = set("`$&;|<>(){}[]*?!#~\\\"' \t\r\n")
RESERVED = {
    "claude-code-marketplace",
    "claude-code-plugins",
    "claude-plugins-official",
    "claude-plugins-community",
    "claude-community",
    "anthropic-marketplace",
    "anthropic-plugins",
    "agent-skills",
    "anthropic-agent-skills",
    "knowledge-work-plugins",
    "life-sciences",
    "claude-for-legal",
    "claude-for-financial-services",
    "financial-services-plugins",
    "first-party-plugins",
    "healthcare",
}
DANGEROUS_BUILTINS = {"__import__", "compile", "eval", "exec"}
DANGEROUS_DOTTED_CALLS = {"__import__", "eval", "exec"}
DANGEROUS_MODULE_ROOTS = {"importlib", "runpy"}
TRACKED_MODULE_ROOTS = {"builtins", "os", "sys"}


def literal_string(node: ast.AST) -> str | None:
    """Return a literal string used for attribute or mapping lookup."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def assignment_bindings(target: ast.AST, value: ast.AST) -> list[tuple[str, ast.AST]]:
    """Pair simple and structurally unpacked assignment names with their values."""
    if isinstance(target, ast.Name):
        return [(target.id, value)]
    if (
        isinstance(target, (ast.List, ast.Tuple))
        and isinstance(value, (ast.List, ast.Tuple))
        and len(target.elts) == len(value.elts)
    ):
        return [
            binding
            for target_item, value_item in zip(target.elts, value.elts)
            for binding in assignment_bindings(target_item, value_item)
        ]
    return []


class DynamicEvalAnalyzer:
    """Find built-in evaluation/import, importlib/runpy, and os process-dispatch surfaces."""

    def __init__(self, tree: ast.AST) -> None:
        self.tree = tree
        self.modules = {
            "__builtins__": "builtins",
            "builtins": "builtins",
            "os": "os",
            "sys": "sys",
        }
        self.callables = set(DANGEROUS_BUILTINS)
        self.assignments: list[tuple[str, ast.AST]] = []
        self.dangerous_import = False

    def module_path(self, node: ast.AST) -> str | None:
        if isinstance(node, ast.Name):
            return self.modules.get(node.id)
        if isinstance(node, ast.Attribute):
            prefix = self.module_path(node.value)
            return f"{prefix}.{node.attr}" if prefix else None
        if isinstance(node, ast.Subscript):
            value = self.module_path(node.value)
            key = literal_string(node.slice)
            if value == "sys.modules" and key is not None:
                return key
        return None

    @staticmethod
    def dangerous_attribute(module: str | None, name: str | None) -> bool:
        if name in DANGEROUS_DOTTED_CALLS:
            return True
        if module is None:
            return False
        root = module.partition(".")[0]
        if root == "builtins":
            return name is None or name in DANGEROUS_BUILTINS
        if root == "os":
            return name is None or (
                name.startswith(("exec", "spawn", "posix_spawn")) or name in {"popen", "system"}
            )
        return False

    def dangerous_reference(self, node: ast.AST) -> bool:
        if isinstance(node, ast.Name):
            return node.id in self.callables
        if isinstance(node, ast.Attribute):
            return self.dangerous_attribute(self.module_path(node.value), node.attr)
        if isinstance(node, ast.Subscript):
            name = literal_string(node.slice)
            return self.dangerous_attribute(self.module_path(node.value), name)
        if isinstance(node, ast.Call) and len(node.args) >= 2:
            function = node.func
            is_getattr = isinstance(function, ast.Name) and function.id == "getattr"
            if is_getattr:
                return self.dangerous_attribute(
                    self.module_path(node.args[0]), literal_string(node.args[1])
                )
        return False

    def collect(self) -> None:
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Import):
                for item in node.names:
                    root = item.name.partition(".")[0]
                    if root in TRACKED_MODULE_ROOTS:
                        local = item.asname or root
                        self.modules[local] = item.name if item.asname else root
                    if root in DANGEROUS_MODULE_ROOTS:
                        self.dangerous_import = True
            elif isinstance(node, ast.ImportFrom):
                root = (node.module or "").partition(".")[0]
                if root in DANGEROUS_MODULE_ROOTS:
                    self.dangerous_import = True
                for item in node.names:
                    local = item.asname or item.name
                    if (
                        root == "builtins"
                        and item.name in DANGEROUS_BUILTINS
                        or root == "os"
                        and self.dangerous_attribute(root, item.name)
                    ):
                        self.callables.add(local)
            elif isinstance(node, ast.Assign):
                for target in node.targets:
                    self.assignments.extend(assignment_bindings(target, node.value))

    def resolve_aliases(self) -> None:
        # At most one new callable alias needs to become reachable per pass. Keep an explicit bound
        # so cyclic and self-referential assignments cannot make this check hang after later edits.
        for _ in range(len(self.assignments) + 1):
            changed = False
            for name, value in self.assignments:
                dangerous = self.dangerous_reference(value)
                module = self.module_path(value)
                if (
                    module is not None
                    and module != name
                    and not module.startswith(f"{name}.")
                    and self.modules.get(name) != module
                ):
                    self.modules[name] = module
                    changed = True
                if dangerous and name not in self.callables:
                    self.callables.add(name)
                    changed = True
            if not changed:
                break

    def found(self) -> bool:
        self.collect()
        self.resolve_aliases()
        return self.dangerous_import or any(
            isinstance(node, ast.Call) and self.dangerous_reference(node.func)
            for node in ast.walk(self.tree)
        )


def dynamic_eval_check(source: str) -> int:
    """Return 0 for clean input, 1 for a dangerous surface, and 2 when analysis cannot run."""
    try:
        tree = ast.parse(source)
        return 1 if DynamicEvalAnalyzer(tree).found() else 0
    except SyntaxError:
        return 2


def load_object(path: Path) -> dict[str, object]:
    raw: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not all(isinstance(key, str) for key in raw):
        raise ValueError(f"{path} must contain a JSON object")
    return cast(dict[str, object], raw)


def hidden(problems: list[str], where: str, text: str) -> None:
    for char in text:
        if unicodedata.category(char).startswith("C"):
            problems.append(f"{where} holds hidden character U+{ord(char):04X}")


def strings_under(value: object) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, Mapping):
        for item in value.values():
            yield from strings_under(item)
    elif isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        for item in value:
            yield from strings_under(item)


def manifest_check() -> int:
    market = load_object(ROOT / ".claude-plugin" / "marketplace.json")
    problems: list[str] = []

    raw_name = market.get("name", "")
    name = raw_name if isinstance(raw_name, str) else ""
    if not NAME.fullmatch(name):
        problems.append(f"marketplace name {raw_name!r} does not match {NAME.pattern}")
    if name in RESERVED:
        problems.append(f"marketplace name {name!r} is reserved by Anthropic")
    hidden(problems, "marketplace name", name)

    raw_market_description = market.get("description", "")
    market_description = raw_market_description if isinstance(raw_market_description, str) else ""
    if not isinstance(raw_market_description, str):
        problems.append("marketplace description must be a string")
    hidden(problems, "marketplace description", market_description)

    owner = market.get("owner")
    if not isinstance(owner, dict):
        problems.append("owner must be an object carrying a name")
    else:
        owner_name = owner.get("name")
        if not isinstance(owner_name, str) or not owner_name.strip():
            problems.append("owner.name must be a non-empty string")
        else:
            hidden(problems, "owner.name", owner_name)

    raw_entries = market.get("plugins")
    if not isinstance(raw_entries, list) or not raw_entries:
        problems.append("plugins must be a non-empty array")
        entries: list[dict[str, object]] = []
    else:
        entries = []
        for index, raw_entry in enumerate(raw_entries):
            if not isinstance(raw_entry, dict) or not all(
                isinstance(key, str) for key in raw_entry
            ):
                problems.append(f"plugins[{index}] must be an object")
                continue
            entries.append(cast(dict[str, object], raw_entry))

    names = [entry.get("name", "") for entry in entries]
    string_names = [value if isinstance(value, str) else "" for value in names]
    if string_names != sorted(string_names):
        problems.append(f"plugins is not sorted by name: {', '.join(string_names)}")
    if len(set(string_names)) != len(string_names):
        problems.append(f"plugins repeats a name: {', '.join(string_names)}")

    for entry in entries:
        raw_label = entry.get("name", "<unnamed>")
        label = raw_label if isinstance(raw_label, str) else "<unnamed>"
        if not NAME.fullmatch(label):
            problems.append(f"plugin name {raw_label!r} does not match {NAME.pattern}")
        hidden(problems, f"{label} name", label)
        if "version" in entry:
            problems.append(
                f"{label} carries a version; plugin.json owns it and a disagreement warns"
            )
        source = entry.get("source")
        if not isinstance(source, (str, dict)):
            problems.append(f"{label} source must be a string or object")
        elif not source:
            problems.append(f"{label} has no source")
        else:
            for text in strings_under(source):
                if set(text) & META:
                    problems.append(f"{label} source {text!r} holds a shell metacharacter")
        raw_description = entry.get("description", "")
        description = raw_description if isinstance(raw_description, str) else ""
        if not 10 <= len(description) <= 2000:
            problems.append(
                f"{label} description is {len(description)} characters, the range is 10 to 2000"
            )
        if description != description.strip():
            problems.append(f"{label} description has leading or trailing whitespace")
        hidden(problems, f"{label} description", description)

    for problem in problems:
        print(f"FAIL {problem}")
    return 1 if problems else 0


def version_problems(package_version: object, plugin_version: object) -> list[str]:
    """Validate the shared package/plugin version and its SemVer syntax."""
    if (
        not isinstance(package_version, str)
        or not isinstance(plugin_version, str)
        or package_version != plugin_version
    ):
        return [
            (
                f"package.json version {package_version!r} does not match "
                f"plugin.json version {plugin_version!r}"
            )
        ]
    if not SEMVER.fullmatch(plugin_version):
        return [f"version {plugin_version!r} is not valid SemVer 2.0.0"]
    return []


def version_check() -> int:
    package = load_object(ROOT / "package.json")
    plugin = load_object(ROOT / ".claude-plugin" / "plugin.json")
    package_version = package.get("version")
    plugin_version = plugin.get("version")
    problems = version_problems(package_version, plugin_version)
    for problem in problems:
        print(problem)
    if problems:
        return 1
    print(f"version {plugin_version}")
    return 0


def release_version_check() -> int:
    package = load_object(ROOT / "package.json")
    plugin = load_object(ROOT / ".claude-plugin" / "plugin.json")
    package_version = package.get("version")
    plugin_version = plugin.get("version")
    tag = os.environ.get("RELEASE_TAG")
    problems = version_problems(package_version, plugin_version)
    if not isinstance(plugin_version, str) or tag != f"v{plugin_version}":
        problems.append(f"tag {tag!r} does not match plugin.json version {plugin_version!r}")
    for problem in problems:
        print(problem)
    if problems:
        return 1
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        print("GITHUB_OUTPUT is not set", file=sys.stderr)
        return 1
    with Path(output_path).open("a", encoding="utf-8") as output:
        output.write(f"version={plugin_version}\n")
    print(f"version {plugin_version} matches tag {tag}")
    return 0


def main() -> int:
    command = sys.argv[1:]
    if command == ["dynamic-eval"]:
        try:
            source = sys.stdin.read()
        except UnicodeError as error:
            print(f"dynamic-eval check failed: {error}", file=sys.stderr)
            return 2
        return dynamic_eval_check(source)
    if command == ["manifests"]:
        return manifest_check()
    if command == ["versions"]:
        return version_check()
    if command == ["release-versions"]:
        return release_version_check()
    print(
        f"usage: {Path(sys.argv[0]).name} [dynamic-eval|manifests|versions|release-versions]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
