#!/usr/bin/env python3
"""Verify typed MovePlace identity hardening anchors."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

ANCHORS: dict[str, list[str]] = {
    "src/sema_move.zig": [
        "fn recordAliasPlaceOrEscapeWithKey",
        "fn aliasSlotPtrForStoragePlace",
        "fn removeAliasSlotForStoragePlace",
        "fn aliasPlaceInfo",
        "fn aliasWildcardPlaceInfo",
        "const AliasPlaceInfo = struct",
        "place: MovePlace",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker alias assignment updates use typed storage places",
        "move-place-identity-inventory.py",
    ],
}

EXACT_COUNTS: dict[str, dict[str, int]] = {
    "src/sema_move.zig": {
        "state.getPtr(key)": 0,
        "state.remove(key)": 0,
        "state.getPtr(target_info.key)": 0,
        "state.remove(target_info.key)": 0,
    },
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

        for needle, expected in EXACT_COUNTS.get(relative, {}).items():
            checked += 1
            actual = text.count(needle)
            if actual != expected:
                missing.append(f"{relative}: expected {expected} occurrences of {needle!r}, found {actual}")

    if missing:
        print("FAIL: move place identity inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move place identity inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
