#!/usr/bin/env python3
"""Verify move-checker pointer-pointee boundary anchors."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

ANCHORS: dict[str, list[str]] = {
    "src/sema_model.zig": [
        "full_deref_alias: bool = false",
        "Moving `*p` out by value",
    ],
    "src/sema_move.zig": [
        "fn fullDerefMoveSubplace",
        "fn immediateFullDerefMoveReferent",
        "fn consumeTrackedMoveReferent",
        "fn arrayIndexEmbedsMove",
        "cannot move a linear `move` value out through a pointer deref",
        "cannot move a linear `move` array element through a non-constant index",
    ],
    "tests/spec/move_place.mc": [
        "accept_move_field_through_full_alias",
        "accept_move_array_element_through_full_alias",
        "accept_move_dynamic_array_element_through_full_alias",
        "accept_move_nested_dynamic_array_element_through_full_alias",
        "accept_move_nested_dynamic_array_field_element_through_full_alias",
        "accept_assigned_uninit_pointer_dynamic_array_element_alias_move_through",
        "reject_constant_after_dynamic_array_element_full_alias_move",
        "reject_dynamic_array_element_full_alias_after_dynamic_move",
        "reject_dynamic_pointer_to_move_array_element",
        "reject_dynamic_pointer_to_move_array_element_assignment",
        "reject_defer_dynamic_pointer_to_move_array_element",
        "reject_dynamic_pointer_to_move_matrix_outer_element",
        "reject_dynamic_pointer_to_move_matrix_inner_element",
        "reject_dynamic_pointer_to_move_matrix_element_assignment",
        "reject_defer_dynamic_pointer_to_move_matrix_element",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker pointer-pointee boundary is explicit",
        "move-pointer-pointee-boundary-inventory.py",
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
        print("FAIL: move pointer-pointee boundary inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move pointer-pointee boundary inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
