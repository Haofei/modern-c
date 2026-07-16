#!/usr/bin/env python3
"""Verify move-checker CFG skeleton anchors."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

CFG_CONSTRUCTION_HELPERS: dict[str, dict[str, int]] = {
    "linearMoveCfg": {
        "cfg.addBlock(": 3,
        "cfg.addEdge(": 2,
    },
    "exitMoveCfg": {
        "cfg.addBlock(": 2,
        "cfg.addEdge(": 1,
    },
    "shortCircuitMoveCfg": {
        "cfg.addBlock(": 3,
        "cfg.addEdge(": 3,
    },
    "twoArmMoveCfg": {
        "cfg.addBlock(": 4,
        "cfg.addEdge(": 4,
    },
    "multiArmMoveCfg": {
        "cfg.addBlock(": 3,
        "cfg.addEdge(": 2,
    },
    "loopBodyMoveCfg": {
        "cfg.addBlock(": 7,
        "cfg.addEdge(": 6,
    },
}

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
        "fn propagateSuccessorsExcept",
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
        "fn loopBodyMoveCfg",
        "fn moveFunctionBodyCfg",
        "fn moveExitEdgeCfg",
        "fn moveLoopExitEdgeCfg",
        "fn moveWhileConditionCfg",
        "fn moveLoopCfg",
        "fn moveIfLetCfg",
        "fn moveSwitchCfg",
        "fn moveDeferBlock",
        "fn moveDeferIfLetCfg",
        "fn moveDeferSwitchCfg",
        "fn moveDeferLoopCfg",
        "fn moveDeferLoopConditionCfg",
        "fn moveDeferLoopBodyCfg",
        "fn preserveOuterScopedMoveState",
        "linearMoveCfg(self, .exit)",
        "linearMoveCfg(self, .branch_join)",
        "moveLoopCfg(self, l, state, aliases)",
        "moveDeferStmt(self, stmt, block_state, &before, aliases)",
        ".if_let => |n| moveDeferIfLetCfg(self, n, state, aliases)",
        '.@"switch" => |sw| moveDeferSwitchCfg(self, sw, state, aliases)',
        ".loop => |l| moveDeferLoopCfg(self, l, state, aliases)",
        "checkMoveExitEdge(self, block_state, message)",
        "checkLoopExitLeaks(self, block_state, null)",
        "worklist.propagateSuccessors(self, block_id, block_state)",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker CFG skeleton is explicit",
        "Move checker linear CFG construction is centralized",
        "Move checker exit CFG construction is centralized",
        "Move checker bypass CFG construction is centralized",
        "Move checker two-arm branch CFG construction is centralized",
        "Move checker multi-arm branch CFG construction is centralized",
        "Move checker CFG construction inventory is exact",
        "Move checker return and try exits use CFG worklist state",
        "Move checker loop early exits first gained CFG worklist transport",
        "Move checker routes loop early exits through target CFG worklists",
        "Move checker function fallthrough exits use CFG worklist state",
        "Move checker loop statement orchestration is centralized",
        "Move checker scoped blocks use CFG worklist state",
        "Move checker deferred cleanup blocks use CFG worklist state",
        "Move checker deferred if-let cleanup uses CFG worklist state",
        "Move checker deferred switch cleanup uses CFG worklist state",
        "Move checker deferred loop cleanup uses CFG worklist state",
        "move-cfg-skeleton-inventory.py",
    ],
}


def function_body(text: str, name: str) -> str | None:
    signature = f"fn {name}"
    start = text.find(signature)
    if start < 0:
        return None
    brace = text.find("{", start)
    if brace < 0:
        return None

    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    return None


def cfg_construction_errors(text: str) -> list[str]:
    errors: list[str] = []
    helper_total = {"cfg.addBlock(": 0, "cfg.addEdge(": 0}

    for helper, expected_counts in sorted(CFG_CONSTRUCTION_HELPERS.items()):
        body = function_body(text, helper)
        if body is None:
            errors.append(f"src/sema_move.zig: missing function body for {helper}")
            continue
        for pattern, expected in sorted(expected_counts.items()):
            actual = body.count(pattern)
            helper_total[pattern] += actual
            if actual != expected:
                errors.append(
                    "src/sema_move.zig: "
                    f"{helper} has {actual} occurrences of {pattern!r}, expected {expected}"
                )

    for pattern, helper_count in sorted(helper_total.items()):
        total = text.count(pattern)
        if total != helper_count:
            outside = total - helper_count
            errors.append(
                "src/sema_move.zig: "
                f"{outside} occurrences of {pattern!r} outside centralized CFG helpers"
            )

    return errors


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

        if relative == "src/sema_move.zig":
            cfg_errors = cfg_construction_errors(text)
            checked += len(CFG_CONSTRUCTION_HELPERS) * 2 + 2
            missing.extend(cfg_errors)

    if missing:
        print("FAIL: move CFG skeleton inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move CFG skeleton inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
