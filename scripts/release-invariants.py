"""Run CI and release invariants."""

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
    if not isinstance(owner, dict) or not owner.get("name"):
        problems.append("owner must be an object carrying a name")

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
        if not source:
            problems.append(f"{label} has no source")
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


def version_check() -> int:
    package = load_object(ROOT / "package.json")
    plugin = load_object(ROOT / ".claude-plugin" / "plugin.json")
    package_version = package.get("version")
    plugin_version = plugin.get("version")
    if (
        not isinstance(package_version, str)
        or not isinstance(plugin_version, str)
        or package_version != plugin_version
    ):
        print(
            f"package.json version {package_version!r} does not match "
            f"plugin.json version {plugin_version!r}"
        )
        return 1
    print(f"version {plugin_version}")
    return 0


def release_version_check() -> int:
    package = load_object(ROOT / "package.json")
    plugin = load_object(ROOT / ".claude-plugin" / "plugin.json")
    package_version = package.get("version")
    plugin_version = plugin.get("version")
    tag = os.environ.get("RELEASE_TAG")
    problems: list[str] = []
    if (
        not isinstance(package_version, str)
        or not isinstance(plugin_version, str)
        or package_version != plugin_version
    ):
        problems.append(
            f"package.json version {package_version!r} does not match "
            f"plugin.json version {plugin_version!r}"
        )
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
    if command == ["manifests"]:
        return manifest_check()
    if command == ["versions"]:
        return version_check()
    if command == ["release-versions"]:
        return release_version_check()
    print(
        f"usage: {Path(sys.argv[0]).name} [manifests|versions|release-versions]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
