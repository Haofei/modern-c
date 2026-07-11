#!/usr/bin/env python3
"""Verify fail-closed move-array unsupported-channel inventory."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

CHANNELS: dict[str, dict[str, list[str]]] = {
    "global move-array storage rejects": {
        "src/sema.zig": [
            "global storage cannot own an array of linear `move` values by value",
        ],
        "tests/spec/bad/move_cfg_arrays_reject.mc": [
            "global bad_move_array_global",
        ],
    },
    "extern/export move-array ABI boundaries reject": {
        "src/sema.zig": [
            "extern/export ABI parameters cannot pass arrays of linear `move` values by value",
            "extern/export ABI returns cannot carry arrays of linear `move` values by value",
        ],
        "tests/spec/bad/move_cfg_arrays_reject.mc": [
            "extern fn reject_move_array_param",
            "export fn reject_move_array_return",
        ],
    },
    "aggregate containment is scoped by owner kind": {
        "src/sema.zig": [
            "a non-`move` struct cannot store an array of linear `move` values by value",
        ],
        "tests/spec/bad/move_cfg_arrays_reject.mc": [
            "struct BadArrayContainer",
        ],
        "tests/spec/move_place.mc": [
            "move struct ResArrayBox",
            "accept_move_array_field_elements",
            "reject_whole_after_array_field_partial",
        ],
    },
    "arbitrary pointer-to-array dynamic pointees reject": {
        "src/sema_move.zig": [
            "arrayIndexEmbedsMove",
            "cannot move a linear `move` array element through a non-constant index",
            "cannot assign a linear `move` array element through a non-constant index",
            "cannot defer a linear `move` array element through a non-constant index",
        ],
        "tests/spec/move_place.mc": [
            "reject_dynamic_pointer_to_move_array_element",
            "reject_dynamic_pointer_to_move_array_element_assignment",
            "reject_defer_dynamic_pointer_to_move_array_element",
            "reject_dynamic_pointer_to_move_matrix_outer_element",
            "reject_dynamic_pointer_to_move_matrix_inner_element",
            "reject_dynamic_pointer_to_move_matrix_element_assignment",
            "reject_defer_dynamic_pointer_to_move_matrix_element",
        ],
    },
    "multi-element non-nameable returned arrays reject": {
        "src/sema_move.zig": [
            "nonNameableSingletonMoveIndex",
        ],
        "tests/spec/move_place.mc": [
            "reject_dynamic_returned_move_array_element",
            "reject_defer_dynamic_returned_move_array_element",
            "reject_dynamic_returned_matrix_element",
            "reject_dynamic_inner_returned_matrix_element",
            "reject_defer_dynamic_returned_matrix_element",
            "reject_defer_dynamic_inner_returned_matrix_element",
        ],
    },
    "multi-element non-nameable array literals reject": {
        "src/sema_move.zig": [
            "arrayLiteralElementEmbedsMove",
            "nonNameableSingletonMoveIndex",
        ],
        "tests/spec/move_place.mc": [
            "reject_dynamic_array_literal_move_element",
            "reject_defer_dynamic_array_literal_move_element",
            "reject_dynamic_nested_array_literal_move_element",
            "reject_dynamic_inner_nested_array_literal_move_element",
            "reject_defer_dynamic_nested_array_literal_move_element",
            "reject_defer_dynamic_inner_nested_array_literal_move_element",
        ],
    },
    "singleton non-nameable arrays are the accepted exception": {
        "src/sema_move.zig": [
            "nonNameableSingletonMoveIndex",
        ],
        "tests/spec/move_place.mc": [
            "accept_dynamic_returned_singleton_move_array_element",
            "accept_defer_dynamic_returned_singleton_move_array_element",
            "accept_dynamic_outer_returned_singleton_matrix_element",
            "accept_dynamic_singleton_array_literal_move_element",
            "accept_defer_dynamic_singleton_array_literal_move_element",
            "accept_dynamic_inner_nested_singleton_array_literal_move_element",
            "accept_defer_dynamic_inner_nested_singleton_array_literal_move_element",
            "accept_dynamic_outer_nested_singleton_array_literal_move_element",
            "accept_defer_dynamic_outer_nested_singleton_array_literal_move_element",
        ],
    },
}

ANCHORS: dict[str, list[str]] = {
    "src/sema.zig": [
        "global storage cannot own an array of linear `move` values by value",
        "a non-`move` struct cannot store an array of linear `move` values by value",
        "extern/export ABI parameters cannot pass arrays of linear `move` values by value",
        "extern/export ABI returns cannot carry arrays of linear `move` values by value",
    ],
    "src/sema_move.zig": [
        "cannot assign a linear `move` array element through a non-constant index",
        "cannot move a linear `move` array element through a non-constant index",
        "cannot defer a linear `move` array element through a non-constant index",
        "arrayIndexEmbedsMove",
        "nonNameableSingletonMoveIndex",
    ],
    "tests/spec/bad/move_cfg_arrays_reject.mc": [
        "struct BadArrayContainer",
        "export fn reject_move_array_return",
        "extern fn reject_move_array_param",
        "global bad_move_array_global",
    ],
    "tests/spec/move_place.mc": [
        "reject_dynamic_pointer_to_move_array_element",
        "reject_dynamic_pointer_to_move_array_element_assignment",
        "reject_defer_dynamic_pointer_to_move_array_element",
        "reject_dynamic_pointer_to_move_matrix_outer_element",
        "reject_dynamic_pointer_to_move_matrix_inner_element",
        "reject_dynamic_pointer_to_move_matrix_element_assignment",
        "reject_defer_dynamic_pointer_to_move_matrix_element",
        "reject_dynamic_returned_move_array_element",
        "reject_defer_dynamic_returned_move_array_element",
        "reject_dynamic_returned_matrix_element",
        "reject_dynamic_inner_returned_matrix_element",
        "reject_defer_dynamic_returned_matrix_element",
        "reject_defer_dynamic_inner_returned_matrix_element",
        "reject_dynamic_array_literal_move_element",
        "reject_defer_dynamic_array_literal_move_element",
        "reject_dynamic_nested_array_literal_move_element",
        "reject_dynamic_inner_nested_array_literal_move_element",
        "reject_defer_dynamic_nested_array_literal_move_element",
        "reject_defer_dynamic_inner_nested_array_literal_move_element",
        "accept_dynamic_returned_singleton_move_array_element",
        "accept_dynamic_singleton_array_literal_move_element",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker unsupported-channel inventory is explicit",
        "move-unsupported-inventory.py",
    ],
}

EXACT_COUNTS: dict[str, dict[str, int]] = {
    "src/sema.zig": {
        '"E_MOVE_ARRAY_UNSUPPORTED"': 4,
    },
    "src/sema_move.zig": {
        '"E_MOVE_ARRAY_UNSUPPORTED"': 4,
    },
    "tests/spec/bad/move_cfg_arrays_reject.mc": {
        "EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED": 4,
    },
    "tests/spec/move_place.mc": {
        "EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED": 19,
    },
}

FORBIDDEN_ANCHORS: dict[str, list[str]] = {
    "docs/compiler-production-readiness.md": [
        "aliasWildcardPlaceKey",
        "aliasPlaceForKey",
        "fullDerefMoveSubplaceAlias",
        "legacySubplaceReferentMoved",
        "memberPlaceKey",
        "movedReferentPlaceFromState",
        "formatted subplace and wildcard keys",
        "legacy formatted-subplace fallback",
        "all-concrete typed scans",
    ],
}


def main() -> int:
    missing: list[str] = []
    checked = 0

    for channel, files in sorted(CHANNELS.items()):
        for relative, anchors in sorted(files.items()):
            path = REPO_ROOT / relative
            try:
                text = path.read_text(encoding="utf-8")
            except FileNotFoundError:
                missing.append(f"{channel}: {relative}: file missing")
                continue

            for anchor in anchors:
                checked += 1
                if anchor not in text:
                    missing.append(f"{channel}: {relative}: missing anchor {anchor!r}")

    all_paths = set(ANCHORS.keys()) | set(FORBIDDEN_ANCHORS.keys())
    for relative in sorted(all_paths):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"{relative}: file missing")
            continue

        anchors = ANCHORS.get(relative, [])
        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"{relative}: missing anchor {anchor!r}")

        for needle, expected in EXACT_COUNTS.get(relative, {}).items():
            checked += 1
            actual = text.count(needle)
            if actual != expected:
                missing.append(f"{relative}: expected {expected} occurrences of {needle!r}, found {actual}")

        for forbidden in FORBIDDEN_ANCHORS.get(relative, []):
            checked += 1
            if forbidden in text:
                missing.append(f"{relative}: forbidden stale anchor {forbidden!r}")

    if missing:
        print("FAIL: move unsupported inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move unsupported inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
