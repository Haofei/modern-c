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
        "cfg.addBlock(": 6,
        "cfg.addEdge(": 6,
    },
    "multiArmMoveCfg": {
        "cfg.addBlock(": 4,
        "cfg.addEdge(": 3,
    },
    "loopBodyMoveCfg": {
        "cfg.addBlock(": 8,
        "cfg.addEdge(": 7,
    },
}

WORKLIST_ROUTING: dict[str, dict[str, list[str]]] = {
    "moveConsumeShortCircuitRhs": {
        "required": [
            "worklist.useShortCircuitJoinPolicy(rhs.span, false);",
            "worklist.propagateSuccessors(self, block, block_state);",
        ],
        "forbidden": ["mergeShortCircuitMoveStates(self, joined, block_state"],
    },
    "moveDeferShortCircuitRhs": {
        "required": [
            "worklist.useShortCircuitJoinPolicy(rhs.span, true);",
            "worklist.propagateSuccessors(self, block, block_state);",
        ],
        "forbidden": ["mergeShortCircuitMoveStates(self, joined, block_state"],
    },
    "moveWhileConditionCfg": {
        "required": [
            "worklist.useLoopConditionJoinPolicy();",
            "worklist.propagateSuccessors(self, block, block_state);",
        ],
        "forbidden": [
            "reportLoopOuterResourceChanges(self, exit_state, block_state);",
            "worklist.enqueue(self, short.join);",
        ],
    },
    "checkMoveLinearity": {
        "required": [
            "moveExitEdgeCfg(self, &state, \"linear `move` value is never consumed (must be moved, returned, or freed)\");",
        ],
        "forbidden": ["var it = state.iterator();"],
    },
    "moveScopedBlock": {
        "required": [
            "} else if (block_id == linear.exit) {\n            reportMoveLocalsLeavingScope",
        ],
        "forbidden": [],
    },
    "moveDeferBlock": {
        "required": [
            "} else if (block_id == linear.exit) {\n            reportMoveLocalsLeavingScope",
        ],
        "forbidden": [],
    },
    "moveIfLetCfg": {
        "required": [
            "} else if (block == branch.then_exit) {",
            "finalizeBranchLocals(self, block_state, state, true);",
            "} else if (block == branch.else_exit) {",
        ],
        "forbidden": [
            "finalizeBranchLocals(self, block_state, state, !then_div);",
            "finalizeBranchLocals(self, block_state, state, !else_div);",
        ],
    },
    "moveDeferIfLetCfg": {
        "required": [
            "} else if (block == branch.then_exit or block == branch.else_exit) {",
            "worklist.propagateSuccessors(self, block, block_state);",
        ],
        "forbidden": [],
    },
    "moveSwitchCfg": {
        "required": [
            "for (branch.arm_exits, 0..) |exit_block, i|",
            "finalizeBranchLocals(self, block_state, state, true);",
        ],
        "forbidden": ["finalizeBranchLocals(self, state, outer, !diverges);"],
    },
    "moveDeferSwitchCfg": {
        "required": ["for (branch.arm_exits) |exit_block|"],
        "forbidden": [],
    },
    "moveDeferLoopCfg": {
        "required": [
            "worklist.useLoopBackedgeJoinPolicy(loop_cfg.loop_head);",
            "worklist.joinStateAt(self, loop_cfg.loop_head, &condition_state);",
            "replaceMoveState(self, state, exit_state);",
        ],
        "forbidden": [
            "worklist.suppressJoinDiagnostics();",
            "reportLoopOuterResourceChanges(",
        ],
    },
    "moveLoopBodyCfg": {
        "required": [
            "worklist.useLoopBackedgeJoinPolicy(loop_cfg.loop_head);",
            "finalizeLoopBodyCfgExit(self, &loop_cfg, &worklist, outer_state, body_diverges);",
        ],
        "forbidden": ["worklist.suppressJoinDiagnostics();"],
    },
    "finalizeLoopBodyCfgExit": {
        "required": [
            "reportMoveLocalsLeavingScope(self, exit_state, outer_state",
            "replaceMoveState(self, outer_state, exit_state);",
        ],
        "forbidden": ["reportLoopOuterResourceChanges("],
    },
    "runLoopBodyCfgWorklist": {
        "required": [
            "} else if (block == loop_cfg.break_exit or block == loop_cfg.continue_exit) {\n            checkLoopExitLeaks(self, block_state, null);",
            "if (block == loop_cfg.continue_exit) worklist.propagateSuccessors(self, block, block_state);",
        ],
        "forbidden": [],
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
        "const MoveCfgJoinPolicy = union(enum)",
        "fn useShortCircuitJoinPolicy",
        "fn useLoopConditionJoinPolicy",
        "fn useLoopBackedgeJoinPolicy",
        "fn joinStateAt",
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
        "fn preserveOuterScopedMoveState",
        "linearMoveCfg(self, .exit)",
        "linearMoveCfg(self, .branch_join)",
        "moveLoopCfg(self, l, state, aliases)",
        "moveDeferStmt(self, stmt, block_state, &before, aliases)",
        ".if_let => |n| moveDeferIfLetCfg(self, n, state, aliases)",
        '.@"switch" => |sw| moveDeferSwitchCfg(self, sw, state, aliases)',
        ".loop => |l| moveDeferLoopCfg(self, l, state, aliases)",
        "condition_visited = true",
        ".loop_backedge => |loop_head|",
        "ordinary loop backedge widening is owned by the targeted CFG join",
        "worklist.propagateSuccessorsExcept(self, block, block_state, if (body_visited.*) loop_cfg.body else null)",
        "checkMoveExitEdge(self, block_state, message)",
        "checkLoopExitLeaks(self, block_state, null)",
        "worklist.propagateSuccessors(self, block_id, block_state)",
    ],
    "tests/spec/move_place.mc": [
        "reject_defer_block_loop_condition_consume",
        "reject_defer_block_loop_condition_borrow",
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


def worklist_routing_errors(text: str) -> list[str]:
    errors: list[str] = []
    for helper, policy in sorted(WORKLIST_ROUTING.items()):
        body = function_body(text, helper)
        if body is None:
            errors.append(f"src/sema_move.zig: missing function body for {helper}")
            continue
        for required in policy["required"]:
            if required not in body:
                errors.append(f"src/sema_move.zig: {helper} missing worklist routing anchor {required!r}")
        for forbidden in policy["forbidden"]:
            if forbidden in body:
                errors.append(f"src/sema_move.zig: {helper} retains caller-side join {forbidden!r}")
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
            routing_errors = worklist_routing_errors(text)
            checked += sum(len(policy["required"]) + len(policy["forbidden"]) for policy in WORKLIST_ROUTING.values())
            missing.extend(routing_errors)

    if missing:
        print("FAIL: move CFG skeleton inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move CFG skeleton inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
