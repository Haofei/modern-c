#!/usr/bin/env python3
"""Verify move-checker CFG skeleton anchors."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

ANCHORS: dict[str, list[str]] = {
    "src/sema_model.zig": [
        "pub const MoveCfgBlockKind = enum",
        "pub const MoveCfgEdgeKind = enum",
        "pub const MoveCfgFlowState = struct",
        "pub const MoveCfg = struct",
        "pub const MoveCfgWorklist = struct",
        "pub fn propagateSuccessors",
    ],
    "src/sema_tests.zig": [
        "move CFG skeleton joins branch states through worklist",
        "move CFG skeleton requeues loop head on backedge state change",
        "move CFG skeleton carries early-exit state to exit block",
    ],
    "src/sema_move.zig": [
        "const MoveStateCfgWorklist = struct",
        "fn preserveOuterScopedMoveState",
        "worklist.propagateSuccessors(self, block_id, block_state)",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker CFG skeleton is explicit",
        "Move checker scoped blocks use CFG worklist state",
        "move-cfg-skeleton-inventory.py",
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

    if missing:
        print("FAIL: move CFG skeleton inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move CFG skeleton inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
