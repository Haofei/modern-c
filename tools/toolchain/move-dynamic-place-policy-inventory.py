#!/usr/bin/env python3
"""Verify move-checker dynamic-place policy anchors."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

ANCHORS: dict[str, list[str]] = {
    "src/sema_model.zig": [
        "pub const MovePlaceProjectionRelation = enum",
        "pub fn movePlaceProjectionRelation",
        ".symbolic_index => switch (right)",
        ".wildcard_index => switch (right)",
        "Dynamic-index policy: stable dynamic indexes are preserved as symbolic",
    ],
    "src/sema_move.zig": [
        "fn stableIndexPlaceKnown",
        "fn symbolicIndexValue",
        "fn wildcardMoveIndexedPlaceKey",
        "fn nestedWildcardIndexedPlaceKeyAndType",
        ".symbolic_index = symbol",
        ".wildcard_index",
    ],
    "src/sema_tests.zig": [
        "move dynamic-place policy separates symbolic identity from overlap",
        "move dynamic-place policy keeps wildcard indexes behind field boundaries",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker dynamic-place policy is explicit",
        "move-dynamic-place-policy-inventory.py",
    ],
}

FORBIDDEN: dict[str, list[str]] = {
    "src/sema_model.zig": [
        "projectionWildcardMatches",
    ],
}


def main() -> int:
    missing: list[str] = []
    checked = 0

    for relative, anchors in sorted(ANCHORS.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"{relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"{relative}: missing anchor {anchor!r}")

        for forbidden in FORBIDDEN.get(relative, []):
            checked += 1
            if forbidden in text:
                missing.append(f"{relative}: forbidden legacy anchor {forbidden!r} is still present")

    if missing:
        print("FAIL: move dynamic-place policy inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move dynamic-place policy inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
