#!/usr/bin/env -S python3 -I -S
"""Inert PermissionRequest hook that leaves the normal permission decision unchanged.

Keeping it shipped pins this hook surface, and security checks assert its presence so a
future Bash auto-approver cannot be introduced silently.
"""

import sys


def main() -> int:
    """Leave every Bash permission decision to the normal user boundary."""
    sys.stdin.buffer.read()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
