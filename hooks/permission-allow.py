#!/usr/bin/env python3
"""PermissionRequest hook with no automatic approval capability.

Starting a delegated Codex turn can read local files, send prompt content to OpenAI,
and, depending on the selected sandbox, change the machine. A hook that sees only the
shell command cannot establish the user's intent for those effects. It therefore must
not approve the command or install a persistent name-based Bash rule.

PermissionRequest hooks express "make the normal permission decision" by producing no
output and exiting successfully. Keeping this inert hook in place makes upgrades from
older plugin versions safe even when their cached hook manifest still references it.
"""

import sys


def main() -> int:
    """Leave every Bash permission decision to the normal user boundary."""
    sys.stdin.buffer.read()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
