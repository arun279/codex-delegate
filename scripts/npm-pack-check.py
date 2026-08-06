import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {
    "CHANGELOG.md",
    "LICENSE",
    "PRIVACY.md",
    "README.md",
    "SECURITY.md",
    "bin/codex-delegate",
    "package.json",
}


def main() -> int:
    npm = shutil.which("npm") or sys.exit("npm-pack-check: FAIL: npm is not installed")
    with tempfile.TemporaryDirectory(prefix=".npm-pack-check-") as cache:
        completed = subprocess.run(  # noqa: S603  # npm is resolved from PATH above.
            [npm, "pack", "--cache", cache, "--dry-run", "--json"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            text=True,
            check=False,
        )
    if completed.returncode != 0:
        return 1
    try:
        actual = {item["path"] for item in json.loads(completed.stdout)[0]["files"]}
    except (json.JSONDecodeError, IndexError, KeyError, TypeError):
        print("npm-pack-check: FAIL: invalid npm pack JSON", file=sys.stderr)
        return 1

    if actual != EXPECTED:
        print(
            f"npm-pack-check: FAIL: expected {sorted(EXPECTED)}, got {sorted(actual)}",
            file=sys.stderr,
        )
        return 1
    print(f"npm-pack-check: PASS ({len(actual)} exact files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
