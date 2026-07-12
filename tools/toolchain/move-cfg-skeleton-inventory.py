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
        "const LinearMoveCfg = struct",
        "fn linearMoveCfg",
        "const ExitMoveCfg = struct",
        "fn exitMoveCfg",
        "const ShortCircuitMoveCfg = struct",
        "fn shortCircuitMoveCfg",
        "const TwoArmMoveCfg = struct",
        "fn twoArmMoveCfg",
        "const MultiArmMoveCfg = struct",
        "fn multiArmMoveCfg",
        "fn moveFunctionBodyCfg",
        "fn moveExitEdgeCfg",
        "fn moveLoopExitEdgeCfg",
        "fn moveWhileConditionCfg",
        "fn moveIfLetCfg",
        "fn moveSwitchCfg",
        "fn preserveOuterScopedMoveState",
        "linearMoveCfg(self, .exit)",
        "linearMoveCfg(self, .branch_join)",
        "checkMoveExitEdge(self, block_state, message)",
        "checkLoopExitLeaks(self, block_state, target)",
        "worklist.propagateSuccessors(self, block_id, block_state)",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker CFG skeleton is explicit",
        "Move checker linear CFG construction is centralized",
        "Move checker exit CFG construction is centralized",
        "Move checker bypass CFG construction is centralized",
        "Move checker two-arm branch CFG construction is centralized",
        "Move checker multi-arm branch CFG construction is centralized",
        "Move checker return and try exits use CFG worklist state",
        "Move checker loop early exits use CFG worklist state",
        "Move checker function fallthrough exits use CFG worklist state",
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
