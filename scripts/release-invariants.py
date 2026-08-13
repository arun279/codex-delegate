"""Run CI and release invariants."""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import subprocess
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
DISCLOSURES = {
    "PreToolUse hook scope": re.compile(
        r"PreToolUse hooks.*Bash, Monitor, and Workflow", re.IGNORECASE
    ),
    "PermissionRequest behavior": re.compile(r"PermissionRequest hook is inert", re.IGNORECASE),
    "OpenAI data egress": re.compile(r"prompts and files.*sent to OpenAI", re.IGNORECASE),
    "account-funded usage": re.compile(r"ChatGPT.*API-billed usage", re.IGNORECASE),
}
CHANGELOG_ENTRY = re.compile(r"^[-+*] ")
CHANGELOG_EVIDENCE = re.compile(
    r"^  <!-- evidence: (?P<path>[A-Za-z0-9_./-]+) :: (?P<needle>.+) -->$"
)
CHANGELOG_SECTIONS = {"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}
CHANGELOG_PRODUCT_SURFACE = (
    "bin/",
    "hooks/",
    ".claude-plugin/marketplace.json",
    ".claude-plugin/plugin.json",
    "package.json",
)
TYPOGRAPHIC_DASH = re.compile(r"[\u2010-\u2015]")
PUBLICATION_COPY_EXCLUSIONS = {
    "tests/run.sh",  # Deliberate UTF-8 stream fixture.
}


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
    except (SyntaxError, ValueError):
        return 2
    return 1 if DynamicEvalAnalyzer(tree).found() else 0


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
    plugin = load_object(ROOT / ".claude-plugin" / "plugin.json")
    package = load_object(ROOT / "package.json")
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

    shipped_descriptions: list[tuple[str, str, bool]] = []
    for path, manifest, has_hooks in (
        ("package.json", package, False),
        (".claude-plugin/plugin.json", plugin, True),
    ):
        raw_description = manifest.get("description", "")
        description = raw_description if isinstance(raw_description, str) else ""
        if not isinstance(raw_description, str):
            problems.append(f"{path} description must be a string")
        shipped_descriptions.append((path, description, has_hooks))

    for index, entry in enumerate(entries):
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
        if label == "codex-delegate" and source != "./":
            problems.append(
                "codex-delegate source must remain './' until an installable release asset exists, "
                f"got {source!r}"
            )
        raw_description = entry.get("description", "")
        description = raw_description if isinstance(raw_description, str) else ""
        if not 10 <= len(description) <= 2000:
            problems.append(
                f"{label} description is {len(description)} characters, the range is 10 to 2000"
            )
        if description != description.strip():
            problems.append(f"{label} description has leading or trailing whitespace")
        if label == "codex-delegate":
            shipped_descriptions.append((f"marketplace.json plugins[{index}]", description, True))
        hidden(problems, f"{label} description", description)

    common_disclosures = {"OpenAI data egress", "account-funded usage"}
    for label, description, has_hooks in shipped_descriptions:
        for disclosure, pattern in DISCLOSURES.items():
            if (has_hooks or disclosure in common_disclosures) and pattern.search(
                description
            ) is None:
                problems.append(f"{label} description omits {disclosure}")

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


def changelog_check() -> int:
    """Require every release-note claim to carry adjacent, independently readable evidence."""
    path = ROOT / "CHANGELOG.md"
    lines = path.read_text(encoding="utf-8").splitlines()
    problems: list[str] = []
    headings = [
        match.group(1)
        for line in lines
        if (match := re.fullmatch(r"## \[([^]]+)](?: - \d{4}-\d{2}-\d{2})?", line))
    ]
    if not headings or headings[0] != "Unreleased":
        problems.append("CHANGELOG.md must begin its release sections with [Unreleased]")
    if len(headings) != len(set(headings)):
        problems.append(f"CHANGELOG.md repeats a release section: {headings}")
    for heading in headings[1:]:
        if not SEMVER.fullmatch(heading):
            problems.append(f"CHANGELOG.md release section {heading!r} is not SemVer 2.0.0")

    in_release_sections = False
    for index, line in enumerate(lines):
        if re.fullmatch(r"## \[[^]]+](?: - \d{4}-\d{2}-\d{2})?", line):
            in_release_sections = True
            continue
        if line.startswith("[") and "]: " in line:
            in_release_sections = False
        if in_release_sections and line.startswith("### "):
            section = line.removeprefix("### ")
            if section not in CHANGELOG_SECTIONS:
                problems.append(f"CHANGELOG.md:{index + 1} has unknown section {section!r}")
        elif (
            in_release_sections
            and line
            and CHANGELOG_ENTRY.match(line) is None
            and CHANGELOG_EVIDENCE.fullmatch(line) is None
        ):
            problems.append(f"CHANGELOG.md:{index + 1} has unstructured release-note content")

    for index, line in enumerate(lines):
        if CHANGELOG_ENTRY.match(line) is None:
            continue
        line_number = index + 1
        evidence_line = lines[index + 1] if index + 1 < len(lines) else ""
        evidence = CHANGELOG_EVIDENCE.fullmatch(evidence_line)
        if evidence is None:
            problems.append(f"CHANGELOG.md:{line_number} entry has no adjacent evidence")
            continue
        relative = evidence.group("path")
        needle = evidence.group("needle")
        if relative == "CHANGELOG.md":
            problems.append(f"CHANGELOG.md:{line_number} cites itself as evidence")
            continue
        if len(needle) < 20:
            problems.append(
                f"CHANGELOG.md:{line_number} evidence needle is too weak ({len(needle)} chars)"
            )
            continue
        source = ROOT / relative
        try:
            source_text = source.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            problems.append(
                f"CHANGELOG.md:{line_number} cannot read evidence path {relative!r}: {error}"
            )
            continue
        if needle not in source_text:
            problems.append(f"CHANGELOG.md:{line_number} claims {needle!r}, absent from {relative}")

    git = shutil.which("git")
    base = os.environ.get("CHANGELOG_BASE")
    skip_diff_reason: str | None = None
    if git is None:
        skip_diff_reason = "git is not installed"
    elif base is None:
        head_result = subprocess.run(  # noqa: S603 -- git is resolved from PATH above.
            [git, "rev-parse", "--verify", "--quiet", "HEAD"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if head_result.returncode != 0:
            skip_diff_reason = "no comparable Git base"
        else:
            head = head_result.stdout.strip()
            for candidate in ("refs/remotes/origin/main", "refs/heads/main"):
                exists = subprocess.run(  # noqa: S603 -- git is resolved from PATH above.
                    [git, "rev-parse", "--verify", "--quiet", candidate],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if exists.returncode != 0:
                    continue
                merge_base_result = subprocess.run(  # noqa: S603 -- resolved above.
                    [git, "merge-base", head, candidate],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if merge_base_result.returncode != 0:
                    continue
                merge_base = merge_base_result.stdout.strip()
                if merge_base != head:
                    base = merge_base
                    break
            if base is None:
                parent = subprocess.run(  # noqa: S603 -- git is resolved from PATH above.
                    [git, "rev-parse", "--verify", "--quiet", f"{head}^"],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if parent.returncode == 0:
                    base = parent.stdout.strip()
                else:
                    skip_diff_reason = "no comparable Git base"

    if skip_diff_reason is not None:
        print(f"changelog: product-diff coverage SKIP ({skip_diff_reason})")
    elif base is not None and git is not None:
        try:
            changed = subprocess.run(  # noqa: S603 -- git is resolved from PATH above.
                [git, "diff", "--name-only", base, "--"],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.splitlines()
            product_changed = any(
                relative == surface or relative.startswith(surface)
                for relative in changed
                for surface in CHANGELOG_PRODUCT_SURFACE
            )
            if product_changed:
                prior = subprocess.run(  # noqa: S603 -- git is resolved from PATH above.
                    [git, "show", f"{base}:CHANGELOG.md"],
                    cwd=ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.splitlines()
                prior_entries = {
                    (line, prior[index + 1] if index + 1 < len(prior) else "")
                    for index, line in enumerate(prior)
                    if CHANGELOG_ENTRY.match(line) is not None
                }
                current_entries = {
                    (line, lines[index + 1] if index + 1 < len(lines) else "")
                    for index, line in enumerate(lines)
                    if CHANGELOG_ENTRY.match(line) is not None
                }
                if not current_entries - prior_entries:
                    problems.append(
                        f"product surface changed without a new CHANGELOG.md entry (base {base})"
                    )
        except subprocess.CalledProcessError as error:
            detail = error.stderr.strip() if isinstance(error.stderr, str) else ""
            problems.append(f"cannot inspect the product diff from {base!r}: {detail or error}")

    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        return 1
    entry_count = sum(CHANGELOG_ENTRY.match(line) is not None for line in lines)
    print(f"changelog: PASS ({entry_count} verified entries)")
    return 0


def publication_copy_check() -> int:
    """Reject typographic dashes from the npm and repository-backed plugin payloads."""
    problems: list[str] = []
    git = shutil.which("git")
    if git is None:
        print("FAIL cannot list tracked plugin payload: git is not installed")
        return 1
    completed = subprocess.run(  # noqa: S603 -- git is resolved from PATH above.
        [git, "ls-files", "-z"],
        cwd=ROOT,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        print(f"FAIL cannot list tracked plugin payload: {completed.stderr.decode().strip()}")
        return 1
    tracked = {item.decode() for item in completed.stdout.split(b"\0") if item}
    shipped_copy = tracked - PUBLICATION_COPY_EXCLUSIONS
    for relative in sorted(shipped_copy):
        try:
            lines = (ROOT / relative).read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            problems.append(f"{relative} cannot be read as UTF-8: {error}")
            continue
        for line_number, line in enumerate(lines, start=1):
            if match := TYPOGRAPHIC_DASH.search(line):
                problems.append(
                    f"{relative}:{line_number} contains typographic dash U+{ord(match.group()):04X}"
                )
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        return 1
    print(f"publication copy: PASS ({len(shipped_copy)} shipped files)")
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
    if command == ["changelog"]:
        return changelog_check()
    if command == ["publication-copy"]:
        return publication_copy_check()
    print(
        f"usage: {Path(sys.argv[0]).name} "
        "[dynamic-eval|manifests|versions|release-versions|changelog|publication-copy]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
