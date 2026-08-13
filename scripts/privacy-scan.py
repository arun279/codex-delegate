#!/usr/bin/env python3
"""Reject private paths, project identifiers, and contextual work product.

The default scan covers every non-ignored working-tree file, every distinct path
in reachable Git trees, reachable blob/commit/tag content, and published ref
names. Content scanning includes UTF-8 plus bounded decoding of obvious UTF-16,
base64, hexadecimal, and zlib representations. It also joins backslash-newline
continuations and adjacent quoted literals.

Derived decoding is deliberately capped at two transformation levels and 1 MiB
per decoded run. Candidate runs are streamed and duplicate decoded values are
discarded by digest, so an earlier benign run cannot hide a later one without an
unbounded aggregate buffer. This does not unpack archives, decrypt content,
recognize custom encodings, or inspect a single decoded run beyond those limits.
``--path`` applies the same policy to explicit files without placing test content
in the repository.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import codecs
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zlib
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from re import Pattern
from typing import Literal, Optional, cast

ROOT = Path(__file__).resolve().parent.parent
RuleMode = Literal["direct", "private_project", "work_product"]

MAX_DECODED_BYTES = 1024 * 1024
MAX_DECODE_DEPTH = 2
BASE64_RUN = re.compile(rb"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{16,}={0,2}(?![A-Za-z0-9+/=])")
HEX_RUN = re.compile(rb"(?<![0-9A-Fa-f])[0-9A-Fa-f]{24,}(?![0-9A-Fa-f])")
LINE_CONTINUATION = re.compile(r"\\\r?\n")
ADJACENT_LITERAL_BOUNDARY = re.compile(r"([\"'])[ \t\r\n]*\1")


@dataclass(frozen=True)
class RuleSpec:
    key: str
    pattern_parts: tuple[str, ...]
    flags: int
    reason: str
    mode: RuleMode


@dataclass(frozen=True)
class SelfTestResult:
    checks: int
    skipped_reason: str | None


# This is the one policy list. Pattern fragments are joined at runtime so the
# scanner does not have to exempt its own source from the policy it enforces.
FORBIDDEN_RULES: tuple[RuleSpec, ...] = (
    # Absolute developer-machine paths disclose both platform and account location.
    RuleSpec(
        "macos-home-path",
        (
            r"(?<![A-Za-z0-9_.-])/",
            r"Users/",
            r"(?!(?i:you|your-user(?:name)?|username|name|example)(?=/|\b))",
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}(?=/|\b)",
        ),
        0,
        "absolute macOS account path",
        "direct",
    ),
    # Explicit Unix account homes are private; synthetic /fixture/home is not this shape.
    RuleSpec(
        "unix-home-path",
        (
            r"(?<![A-Za-z0-9_.-])/(?:home|var/home)/",
            r"[A-Za-z][A-Za-z0-9._-]{0,31}(?=/|\b)",
            r"|(?<![A-Za-z0-9_.-])/",
            r"root(?=/|\b)",
        ),
        0,
        "real-looking Unix account home",
        "direct",
    ),
    # Development-process roles have no referent in this repository; shipped text that names one
    # narrates how a change was produced rather than what it does.
    RuleSpec(
        "process-role-narrative",
        (r"\borchest", r"rators?\b|\bgaunt", r"lets?\b"),
        re.IGNORECASE,
        "development-process narrative in shipped text",
        "direct",
    ),
    # A numbered register entry points at a tracker that is not in this repository.
    RuleSpec(
        "private-register-item",
        (r"\bitems? ", r"[0-9]{1,3}\b"),
        re.IGNORECASE,
        "reference to a private issue register",
        "direct",
    ),
    # These document names belong to private working notes, not to this repository.
    RuleSpec(
        "private-document-name",
        (r"\b(?:ISSUES|WORKLOG|HAND", r"OFF)\.md\b|\bSTANDING-INSTR", r"UCTIONS\b"),
        0,
        "reference to a private working document",
        "direct",
    ),
    # This extension identifier uniquely names a known private project.
    RuleSpec(
        "private-project-extension",
        (r"\bheader", r"shim\b"),
        re.IGNORECASE,
        "known private extension project",
        "private_project",
    ),
    # This analysis identifier uniquely names a second known private project.
    RuleSpec(
        "private-project-analysis",
        (r"\btoken-", r"analysis\b"),
        re.IGNORECASE,
        "known private analysis project",
        "private_project",
    ),
    # This otherwise ordinary noun is private only in an explicit project/repository context.
    RuleSpec(
        "private-project-scratch",
        (
            r"(?:^|[/\\])(?:projects?|repos?|worktrees?)[/\\-]+scratch",
            r"pad(?=[/\\\s\"']|$)|\b(?:project|repo(?:sitory)?)(?:[-_ ]+name)?",
            r"\s*[:=]\s*[\"']?scratch",
            r"pad\b|\bproject[-_]scratch",
            r"pad\b",
        ),
        re.IGNORECASE | re.MULTILINE,
        "project-name use of an otherwise generic noun",
        "private_project",
    ),
    # Uppercase review-result headings are private work product only with a private project.
    RuleSpec(
        "review-output-finding",
        (r"\bFIND", r"INGS?\b"),
        0,
        "review finding heading beside a private project name",
        "work_product",
    ),
    # A severity label beside a private project name is private review work product.
    RuleSpec(
        "review-severity-medium",
        (r"\bMED", r"IUM\b"),
        0,
        "review severity beside a private project name",
        "work_product",
    ),
    # A severity label beside a private project name is private review work product.
    RuleSpec(
        "review-severity-high",
        (r"\bHI", r"GH(?=\s)"),
        0,
        "review severity beside a private project name",
        "work_product",
    ),
    # Component source suffixes beside a private project name reveal private source files.
    RuleSpec(
        "component-source-suffix",
        (r"\.t", r"sx\b"),
        0,
        "component source path beside a private project name",
        "work_product",
    ),
    # TypeScript file-and-line notation beside a private project name reveals private source locations.
    RuleSpec(
        "typescript-location",
        (r"\.t", r"s:"),
        0,
        "source location beside a private project name",
        "work_product",
    ),
    # A package-manager token beside a private project name reveals private tooling detail.
    RuleSpec(
        "package-manager-token",
        (r"\bp", r"npm\b"),
        0,
        "task tooling beside a private project name",
        "work_product",
    ),
    # Review-role prose beside a private project name is private work product.
    RuleSpec(
        "review-role-token",
        (r"\breview", r"er\b"),
        re.IGNORECASE,
        "review role beside a private project name",
        "work_product",
    ),
    # A review status assignment beside a private project name is private review output.
    RuleSpec(
        "review-verdict-assignment",
        (r"\bVER", r"DICT="),
        0,
        "review verdict beside a private project name",
        "work_product",
    ),
)

COMPILED_RULES: tuple[tuple[RuleSpec, Pattern[str]], ...] = tuple(
    (rule, re.compile("".join(rule.pattern_parts), rule.flags)) for rule in FORBIDDEN_RULES
)


@dataclass(frozen=True)
class ScanTarget:
    label: str
    path_text: str
    data: bytes


@dataclass(frozen=True)
class Violation:
    label: str
    line: int
    rule_key: str
    match: str
    reason: str


@dataclass(frozen=True)
class GitObject:
    oid: bytes
    kind: str
    data: bytes


class ScanError(RuntimeError):
    """An input could not be enumerated or read completely."""


def run_git(root: Path, args: Sequence[str], input_data: bytes | None = None) -> bytes:
    """Run a read-only Git query and return its bytes."""
    process = subprocess.run(  # noqa: S603  # Every argv tail is built by fixed internal queries.
        ["git", "-C", str(root), *args],  # noqa: S607  # Use the developer's Git from PATH.
        input=input_data,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise ScanError(f"git {' '.join(args)} failed: {detail or 'no diagnostic'}")
    return process.stdout


def read_path(path: Path) -> bytes:
    """Read a regular file or the text of a symbolic link without following it."""
    try:
        if path.is_symlink():
            return os.readlink(path).encode("utf-8", errors="surrogateescape")
        return path.read_bytes()
    except OSError as error:
        raise ScanError(f"cannot read {path}: {error}") from error


def working_tree_targets(root: Path) -> list[ScanTarget]:
    """Enumerate tracked and non-ignored untracked working-tree files."""
    output = run_git(
        root,
        ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    )
    targets: list[ScanTarget] = []
    for encoded_name in sorted(name for name in output.split(b"\0") if name):
        relative = encoded_name.decode(sys.getfilesystemencoding(), errors="surrogateescape")
        path = root / relative
        if not path.is_symlink() and not path.is_file():
            continue
        targets.append(ScanTarget(relative, relative, read_path(path)))
    return targets


def parse_object_names(output: bytes) -> list[tuple[bytes, str]]:
    """Parse object ids and optional display paths from rev-list output."""
    objects: list[tuple[bytes, str]] = []
    for line in output.splitlines():
        encoded_oid, separator, encoded_path = line.partition(b" ")
        path = encoded_path.decode("utf-8", errors="surrogateescape") if separator else ""
        objects.append((encoded_oid, path))
    return objects


def read_git_objects(root: Path, object_ids: Sequence[bytes]) -> dict[bytes, GitObject]:
    """Read a known set of object ids with one bounded Git subprocess."""
    request = b"".join(oid + b"\n" for oid in object_ids)
    output = run_git(root, ["cat-file", "--batch"], request)
    objects: dict[bytes, GitObject] = {}
    offset = 0
    for requested_oid in object_ids:
        header_end = output.find(b"\n", offset)
        if header_end < 0:
            raise ScanError("git cat-file returned a truncated object header")
        header = output[offset:header_end].split()
        offset = header_end + 1
        if len(header) != 3:
            raise ScanError(f"git cat-file returned an invalid header for {requested_oid!r}")
        actual_oid, object_type, encoded_size = header
        try:
            size = int(encoded_size)
        except ValueError as error:
            raise ScanError(f"git cat-file returned an invalid size for {actual_oid!r}") from error
        end = offset + size
        if end >= len(output) or output[end : end + 1] != b"\n":
            raise ScanError(f"git cat-file returned truncated data for {actual_oid!r}")
        data = output[offset:end]
        offset = end + 1
        kind = object_type.decode("ascii", errors="replace")
        if actual_oid != requested_oid:
            raise ScanError(
                f"git cat-file returned {actual_oid!r} when {requested_oid!r} was requested"
            )
        objects[requested_oid] = GitObject(requested_oid, kind, data)
    if offset != len(output):
        raise ScanError("git cat-file returned unexpected trailing data")
    return objects


def tree_entries(data: bytes, raw_oid_size: int) -> list[tuple[bytes, bytes, bytes]]:
    """Parse raw Git tree entries as ``(mode, name, hex oid)`` triples."""
    entries: list[tuple[bytes, bytes, bytes]] = []
    offset = 0
    while offset < len(data):
        mode_end = data.find(b" ", offset)
        name_end = data.find(b"\0", mode_end + 1)
        if mode_end < 0 or name_end < 0:
            raise ScanError("reachable Git tree has a truncated entry")
        oid_start = name_end + 1
        oid_end = oid_start + raw_oid_size
        if oid_end > len(data):
            raise ScanError("reachable Git tree has a truncated object id")
        entries.append(
            (
                data[offset:mode_end],
                data[mode_end + 1 : name_end],
                data[oid_start:oid_end].hex().encode("ascii"),
            )
        )
        offset = oid_end
    return entries


def root_tree_ids(objects: dict[bytes, GitObject]) -> set[bytes]:
    """Find the tree referenced by every reachable commit."""
    roots: set[bytes] = set()
    for git_object in objects.values():
        if git_object.kind != "commit":
            continue
        first_line = git_object.data.partition(b"\n")[0]
        marker, separator, oid = first_line.partition(b" ")
        if marker != b"tree" or not separator or oid not in objects:
            raise ScanError(f"reachable commit {git_object.oid!r} has no readable root tree")
        if objects[oid].kind != "tree":
            raise ScanError(f"reachable commit {git_object.oid!r} names a non-tree root")
        roots.add(oid)
    return roots


def historical_paths(
    objects: dict[bytes, GitObject],
) -> tuple[set[tuple[bytes, str]], set[str]]:
    """Return every blob occurrence and non-blob path from reachable commit trees."""
    if not objects:
        return set(), set()
    oid_lengths = {len(oid) for oid in objects}
    if len(oid_lengths) != 1:
        raise ScanError("reachable Git objects use inconsistent object-id lengths")
    hex_oid_size = oid_lengths.pop()
    if hex_oid_size % 2 != 0:
        raise ScanError("reachable Git object id has an invalid length")
    raw_oid_size = hex_oid_size // 2

    blobs: set[tuple[bytes, str]] = set()
    non_blob_paths: set[str] = set()
    pending = [(oid, "") for oid in root_tree_ids(objects)]
    seen_trees: set[tuple[bytes, str]] = set()
    while pending:
        tree_oid, prefix = pending.pop()
        tree_key = (tree_oid, prefix)
        if tree_key in seen_trees:
            continue
        seen_trees.add(tree_key)
        tree = objects.get(tree_oid)
        if tree is None or tree.kind != "tree":
            raise ScanError(f"reachable tree {tree_oid!r} could not be read")
        for mode, encoded_name, child_oid in tree_entries(tree.data, raw_oid_size):
            name = encoded_name.decode("utf-8", errors="surrogateescape")
            path = f"{prefix}/{name}" if prefix else name
            child = objects.get(child_oid)
            if mode in (b"40000", b"040000"):
                if child is None or child.kind != "tree":
                    raise ScanError(f"tree path {path!r} does not resolve to a readable tree")
                pending.append((child_oid, path))
            elif child is not None and child.kind == "blob":
                blobs.add((child_oid, path))
            else:
                # Gitlinks have no blob content in this repository, but their published
                # path remains privacy-sensitive and must still be scanned.
                non_blob_paths.add(path)
    return blobs, non_blob_paths


def reference_targets(root: Path) -> list[ScanTarget]:
    """Enumerate published branch, tag, remote, and notes ref names."""
    output = run_git(root, ["for-each-ref", "--format=%(refname)"])
    targets: list[ScanTarget] = []
    for encoded_name in output.splitlines():
        name = encoded_name.decode("utf-8", errors="surrogateescape")
        targets.append(ScanTarget(f"git-ref:{name}", name, b""))
    return targets


def historical_targets(root: Path) -> list[ScanTarget]:
    """Read reachable object content and every path from every commit tree."""
    named_objects = parse_object_names(run_git(root, ["rev-list", "--objects", "--all"]))
    object_ids = list(dict.fromkeys(oid for oid, _ in named_objects))
    if not object_ids:
        return []
    objects = read_git_objects(root, object_ids)
    blob_paths, path_only = historical_paths(objects)
    targets: list[ScanTarget] = []
    seen_blobs: set[bytes] = set()
    for oid, path in sorted(blob_paths, key=lambda item: (item[1], item[0])):
        seen_blobs.add(oid)
        targets.append(ScanTarget(f"git:{oid.decode('ascii')}:{path}", path, objects[oid].data))

    # Direct blob refs and unusual reachable blobs outside commit trees still get a
    # content scan, using any rev-list hint available for path context.
    hinted_paths: dict[bytes, str] = {}
    for oid, path in named_objects:
        if path and oid not in hinted_paths:
            hinted_paths[oid] = path
    for oid, git_object in sorted(objects.items()):
        if git_object.kind == "blob" and oid not in seen_blobs:
            path = hinted_paths.get(oid, "")
            display_path = path or "<blob>"
            targets.append(
                ScanTarget(f"git:{oid.decode('ascii')}:{display_path}", path, git_object.data)
            )
        elif git_object.kind in ("commit", "tag"):
            targets.append(
                ScanTarget(
                    f"git:{oid.decode('ascii')}:<{git_object.kind}>",
                    "",
                    git_object.data,
                )
            )
    for path in sorted(path_only):
        targets.append(ScanTarget(f"git-path:{path}", path, b""))
    return targets


def explicit_targets(paths: Sequence[Path]) -> list[ScanTarget]:
    """Build scan targets for explicitly requested files."""
    targets: list[ScanTarget] = []
    for path in paths:
        if not path.is_symlink() and not path.is_file():
            raise ScanError(f"explicit scan path is not a file: {path}")
        label = str(path)
        targets.append(ScanTarget(label, path.name, read_path(path)))
    return targets


@dataclass(frozen=True)
class TextView:
    suffix: str
    text: str


def utf16_encodings(data: bytes) -> tuple[str, ...]:
    """Return BOM-marked or strongly NUL-shaped UTF-16 encodings."""
    if data.startswith(codecs.BOM_UTF16_LE):
        return ("utf-16le",)
    if data.startswith(codecs.BOM_UTF16_BE):
        return ("utf-16be",)
    sample = data[:4096]
    pairs = len(sample) // 2
    if pairs < 4:
        return ()
    even_nuls = sample[0 : pairs * 2 : 2].count(0) / pairs
    odd_nuls = sample[1 : pairs * 2 : 2].count(0) / pairs
    if odd_nuls >= 0.3 and even_nuls <= 0.05:
        return ("utf-16le",)
    if even_nuls >= 0.3 and odd_nuls <= 0.05:
        return ("utf-16be",)
    return ()


def decode_text(data: bytes) -> list[tuple[str, str]]:
    """Decode the ordinary UTF-8 view plus any strongly indicated UTF-16 view."""
    decoded = [("", data.decode("utf-8", errors="replace"))]
    for encoding in utf16_encodings(data):
        bounded = data[: MAX_DECODED_BYTES * 2 + 2]
        if len(bounded) % 2:
            bounded = bounded[:-1]
        codec = (
            "utf-16" if bounded.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)) else encoding
        )
        decoded.append((encoding, bounded.decode(codec, errors="replace")))
    return decoded


def source_joined(text: str) -> str:
    """Join explicit continuations and directly adjacent single-line literals."""
    without_continuations = LINE_CONTINUATION.sub("", text)
    return ADJACENT_LITERAL_BOUNDARY.sub("", without_continuations)


def looks_like_zlib(data: bytes) -> bool:
    """Recognize the two-byte header used by zlib-wrapped DEFLATE streams."""
    if len(data) < 2:
        return False
    compression_method_and_window, flags = data[:2]
    return (
        compression_method_and_window & 0x0F == 8
        and compression_method_and_window >> 4 <= 7
        and (compression_method_and_window * 256 + flags) % 31 == 0
    )


def bounded_zlib_decode(data: bytes) -> bytes | None:
    """Decode at most the policy limit from one obvious zlib stream."""
    if not looks_like_zlib(data):
        return None
    try:
        decoder = zlib.decompressobj()
        decoded = decoder.decompress(data, MAX_DECODED_BYTES + 1)
    except zlib.error:
        return None
    return decoded[:MAX_DECODED_BYTES]


def bounded_base64_decode(token: bytes) -> bytes | None:
    """Decode no more base64 input than can contribute to a bounded derived view."""
    encoded_limit = ((MAX_DECODED_BYTES + 2) // 3) * 4
    bounded = token[:encoded_limit]
    if len(token) > encoded_limit:
        bounded = bounded[: len(bounded) - (len(bounded) % 4)]
    padding = b"=" * (-len(bounded) % 4)
    try:
        return base64.b64decode(bounded + padding, validate=True)[:MAX_DECODED_BYTES]
    except binascii.Error:
        return None


def encoded_candidates(text: str) -> Iterator[tuple[str, bytes]]:
    """Yield a per-run-bounded value for each obvious standalone encoding."""
    encoded = text.encode("utf-8", errors="surrogatepass")
    for match in BASE64_RUN.finditer(encoded):
        decoded = bounded_base64_decode(match.group(0))
        if decoded:
            yield "base64", decoded

    for match in HEX_RUN.finditer(encoded):
        token = match.group(0)
        if len(token) % 2:
            continue
        try:
            decoded = bytes.fromhex(token[: MAX_DECODED_BYTES * 2].decode("ascii"))
        except ValueError:
            continue
        if decoded:
            yield "hex", decoded


def content_text_views(data: bytes) -> Iterator[TextView]:
    """Stream bounded decoded and source-normalized views of content."""
    seen_data = {(len(data), hashlib.sha256(data).digest())}

    def descend(current: bytes, transformations: tuple[str, ...], depth: int) -> Iterator[TextView]:
        for encoding, text in decode_text(current):
            view_parts = (*transformations, *((encoding,) if encoding else ()))
            suffix = f" [decoded:{'/'.join(view_parts)}]" if view_parts else ""
            yield TextView(suffix, text)
            joined = source_joined(text)
            if joined != text:
                yield TextView(f"{suffix} [source-joined]", joined)
            if depth >= MAX_DECODE_DEPTH:
                continue
            for transformation, decoded in encoded_candidates(joined):
                fingerprint = (len(decoded), hashlib.sha256(decoded).digest())
                if fingerprint in seen_data:
                    continue
                seen_data.add(fingerprint)
                yield from descend(decoded, (*transformations, transformation), depth + 1)
        if depth < MAX_DECODE_DEPTH:
            inflated = bounded_zlib_decode(current)
            if inflated:
                fingerprint = (len(inflated), hashlib.sha256(inflated).digest())
                if fingerprint not in seen_data:
                    seen_data.add(fingerprint)
                    yield from descend(inflated, (*transformations, "zlib"), depth + 1)

    yield from descend(data, (), 0)


def scan_text(label: str, text: str) -> list[Violation]:
    """Find policy matches in one text while retaining exact line numbers."""
    violations: list[Violation] = []
    for rule, pattern in COMPILED_RULES:
        for match in pattern.finditer(text):
            if rule.key == "macos-home-path" and macos_match_is_in_web_url(text, match.start()):
                continue
            violations.append(
                Violation(
                    label,
                    text.count("\n", 0, match.start()) + 1,
                    rule.key,
                    match.group(0),
                    rule.reason,
                )
            )
    return violations


def macos_match_is_in_web_url(text: str, match_start: int) -> bool:
    """Return whether a home-like substring is part of an HTTP(S) URL path."""
    line_start = text.rfind("\n", 0, match_start) + 1
    prefix = text[line_start:match_start]
    url_start = re.search(r"(?i)https?://[^\s<>\"']*$", prefix)
    return url_start is not None


def scan_target(target: ScanTarget) -> list[Violation]:
    """Scan a target path and content with shared project-name context."""
    violations: list[Violation] = []
    if target.path_text:
        violations.extend(scan_text(f"{target.label} [path]", target.path_text))
    for view in content_text_views(target.data):
        violations.extend(scan_text(f"{target.label}{view.suffix}", view.text))

    private_project_keys = {rule.key for rule in FORBIDDEN_RULES if rule.mode == "private_project"}
    project_present = any(violation.rule_key in private_project_keys for violation in violations)
    if project_present:
        return violations
    work_product_keys = {rule.key for rule in FORBIDDEN_RULES if rule.mode == "work_product"}
    return [violation for violation in violations if violation.rule_key not in work_product_keys]


def run_test_git(root: Path, args: Sequence[str]) -> None:
    """Run a Git setup command inside an isolated self-test repository."""
    process = subprocess.run(  # noqa: S603  # Every argv tail is built by the isolated self-test.
        ["git", "-C", str(root), *args],  # noqa: S607  # Use the developer's Git from PATH.
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise AssertionError(f"self-test git {' '.join(args)} failed: {detail}")


def violation_keys(target: ScanTarget) -> set[str]:
    """Return the rule keys hit by one self-test target."""
    return {violation.rule_key for violation in scan_target(target)}


def require_rule(target: ScanTarget, key: str, description: str) -> None:
    """Assert that one regression fixture triggers its intended rule."""
    if key not in violation_keys(target):
        raise AssertionError(f"{description} was not detected")


def run_self_tests(temp_root: Path | None) -> SelfTestResult:
    """Exercise the detector gaps that would otherwise make a clean result unsound."""
    private_home = "/" + "Users/" + "actual-person/private-file.txt"
    private_project = "header" + "shim"
    macos_key = "macos-home-path"
    project_key = "private-project-extension"

    require_rule(
        ScanTarget("self-test:utf16le", "", codecs.BOM_UTF16_LE + private_home.encode("utf-16le")),
        macos_key,
        "UTF-16LE private path",
    )
    require_rule(
        ScanTarget("self-test:base64", "", base64.b64encode(private_home.encode("utf-8"))),
        macos_key,
        "base64 private path",
    )
    require_rule(
        ScanTarget("self-test:hex", "", private_home.encode("utf-8").hex().encode("ascii")),
        macos_key,
        "hex private path",
    )
    require_rule(
        ScanTarget("self-test:zlib", "", zlib.compress(private_home.encode("utf-8"))),
        macos_key,
        "zlib private path",
    )
    continued = private_project[:6] + "\\\n" + private_project[6:]
    require_rule(
        ScanTarget("self-test:continuation", "", continued.encode("utf-8")),
        project_key,
        "line-continued private identifier",
    )
    adjacent = f'"{private_project[:6]}" "{private_project[6:]}"'
    require_rule(
        ScanTarget("self-test:adjacent", "", adjacent.encode("utf-8")),
        project_key,
        "adjacent-literal private identifier",
    )

    safe_examples = (
        "https://example.test/?path=" + private_home,
        "/" + "Users/<name>/project",
        "/" + "Users/you/.tool-state/run",
    )
    for index, example in enumerate(safe_examples, 1):
        if macos_key in violation_keys(
            ScanTarget(f"self-test:false-positive-{index}", "", example.encode("utf-8"))
        ):
            raise AssertionError(f"benign macOS-path example {index} was rejected")

    if temp_root is None:
        return SelfTestResult(9, "no writable temporary root is available")
    try:
        directory = tempfile.mkdtemp(prefix="privacy-scan-self-test-", dir=temp_root)
    except OSError as error:
        return SelfTestResult(9, f"cannot create a temporary directory under {temp_root}: {error}")

    root = Path(directory)
    try:
        run_test_git(root, ["init", "-q"])
        run_test_git(root, ["config", "user.name", "Privacy Scan Test"])
        run_test_git(root, ["config", "user.email", "privacy-scan@example.invalid"])
        duplicate = b"shared harmless content\n"
        (root / "safe.txt").write_bytes(duplicate)
        private_copy = root / private_project / "copy.txt"
        private_copy.parent.mkdir(parents=True)
        private_copy.write_bytes(duplicate)
        run_test_git(root, ["add", "safe.txt", private_project])
        run_test_git(root, ["commit", "-q", "-m", "self test"])
        run_test_git(root, ["tag", private_project])
        run_test_git(root, ["branch", private_project])
        run_test_git(root, ["update-ref", f"refs/notes/{private_project}", "HEAD"])

        history_violations = [
            violation for target in historical_targets(root) for violation in scan_target(target)
        ]
        if not any(
            violation.rule_key == project_key and "copy.txt" in violation.label
            for violation in history_violations
        ):
            raise AssertionError("private duplicate-blob filename was not detected")
        ref_violations = [
            violation for target in reference_targets(root) for violation in scan_target(target)
        ]
        ref_labels = {
            violation.label for violation in ref_violations if violation.rule_key == project_key
        }
        for ref_kind in ("tags", "heads", "notes"):
            if not any(f"refs/{ref_kind}/" in label for label in ref_labels):
                raise AssertionError(f"private {ref_kind} ref name was not detected")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return SelfTestResult(13, None)


def temp_root_for_self_test(argument: Path | None) -> tuple[Path | None, str | None]:
    """Resolve the caller override or Python's first usable temporary root."""
    if argument is not None:
        return argument, None
    environment = os.environ.get("PRIVACY_SCAN_TEMP_ROOT")
    if environment:
        return Path(environment), None
    try:
        return Path(tempfile.gettempdir()), None
    except (FileNotFoundError, OSError) as error:
        return None, str(error)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse default repository mode or explicit-file test mode."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--path",
        action="append",
        type=Path,
        dest="paths",
        help="scan one explicit file instead of the repository; repeatable",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run the embedded regression tests and exit",
    )
    parser.add_argument(
        "--temp-root",
        type=Path,
        help=(
            "temporary root for Git-backed self-tests; otherwise use "
            "PRIVACY_SCAN_TEMP_ROOT or Python's temporary directory"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Scan all requested sources and report deterministic diagnostics."""
    args = parse_args(argv)
    paths = cast(Optional[list[Path]], args.paths)
    temp_root, temp_root_error = temp_root_for_self_test(args.temp_root)
    try:
        self_test = run_self_tests(temp_root)
    except (AssertionError, OSError) as error:
        print(
            f"privacy scan self-test: ERROR (scanner could not run correctly: {error})",
            file=sys.stderr,
        )
        return 2

    skipped_reason = self_test.skipped_reason
    if skipped_reason is None and temp_root_error is not None:
        skipped_reason = temp_root_error
    if skipped_reason is not None:
        print(
            "privacy scan self-test: SKIP "
            f"({self_test.checks} in-memory checks passed; Git-backed checks skipped: "
            f"{skipped_reason})",
            file=sys.stderr,
        )

    if args.self_test:
        if skipped_reason is None:
            print(f"privacy scan self-test: PASS ({self_test.checks} regression checks)")
        return 0

    try:
        if paths is not None:
            targets = explicit_targets(paths)
            mode_summary = f"{len(targets)} explicit file(s)"
        else:
            working = working_tree_targets(ROOT)
            historical = historical_targets(ROOT)
            references = reference_targets(ROOT)
            targets = working + historical + references
            mode_summary = (
                f"{len(working)} working-tree file(s), {len(historical)} historical target(s), "
                f"{len(references)} ref name(s)"
            )
    except ScanError as error:
        print(f"privacy scan: ERROR (scanner could not run: {error})", file=sys.stderr)
        return 2

    violations = sorted(
        (violation for target in targets for violation in scan_target(target)),
        key=lambda violation: (
            violation.label,
            violation.line,
            violation.rule_key,
            violation.match,
        ),
    )
    if violations:
        for violation in violations:
            print(
                f"{violation.label}:{violation.line}: {violation.rule_key}: "
                f"{violation.match!r} ({violation.reason})"
            )
        print(
            f"privacy scan: FAIL (private data found: {len(violations)} violation(s); "
            f"{mode_summary})"
        )
        return 1

    print(f"privacy scan: ok ({mode_summary}; {len(FORBIDDEN_RULES)} rules)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
