#!/usr/bin/env python3
"""Reject committed PEM private keys.

This gate scans the files tracked by git for PEM private-key blocks. Test harnesses
that need keys must generate them in a per-run temporary directory instead.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys


PRIVATE_KEY_RE = re.compile(
    rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----",
)


def repo_root() -> pathlib.Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return pathlib.Path(result.stdout.strip())


def tracked_paths(root: pathlib.Path) -> list[pathlib.Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        check=True,
        cwd=root,
        stdout=subprocess.PIPE,
    )
    names = [name for name in result.stdout.split(b"\0") if name]
    return [root / name.decode("utf-8", errors="surrogateescape") for name in names]


def main() -> int:
    root = repo_root()
    violations: list[str] = []

    for path in tracked_paths(root):
        if not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            print(f"error: failed to read {path.relative_to(root)}: {exc}", file=sys.stderr)
            return 2
        if PRIVATE_KEY_RE.search(data):
            violations.append(str(path.relative_to(root)))

    if violations:
        print("error: committed PEM private key material found:", file=sys.stderr)
        for path in violations:
            print(f"  {path}", file=sys.stderr)
        print(
            "Generate test keys at runtime in a temporary directory instead of committing them.",
            file=sys.stderr,
        )
        return 1

    print("PASS: no committed PEM private keys")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
