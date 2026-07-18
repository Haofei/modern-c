#!/usr/bin/env python3
"""Verify the M3 move-place projection admission inventory."""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

# Every admitted projection has a structural owner and positive/conflicting
# coverage. Every non-nameable or arbitrary-pointee dynamic projection has the
# stable E_MOVE_ARRAY_UNSUPPORTED boundary instead of a key-format fallback.
ROWS: dict[str, dict[str, list[str]]] = {
    "root and field projections": {
        "src/sema_move.zig": ["pub fn placeKeyAndType", "pub fn moveFieldPlaceKey"],
        "tests/spec/move_place.mc": ["reject_nested_field_move", "reject_duplicate_field_move"],
        "docs/compiler-production-readiness.md": ["Root and field"],
    },
    "constant element projections": {
        "src/sema_model.zig": ["constant_index: usize"],
        "src/sema_move.zig": ["constIndexValue", ".constant_index = k"],
        "tests/spec/move_place.mc": ["accept_move_array_alias_elements"],
        "docs/compiler-production-readiness.md": ["Constant array element"],
    },
    "symbolic element projections": {
        "src/sema_model.zig": ["symbolic_index: []const u8", "MovePlaceProjectionRelation"],
        "src/sema_move.zig": ["symbolicIndexValue", ".symbolic_index = symbol"],
        "tests/spec/move_place.mc": ["reject_dynamic_multi_array_element_move_after_constant"],
        "docs/compiler-production-readiness.md": ["Stable symbolic element"],
    },
    "unknown wildcard projections": {
        "src/sema_model.zig": ["wildcard_index", "movePlaceProjectionRelation"],
        "src/sema_move.zig": ["wildcardMoveIndexedPlaceKey", "nestedWildcardIndexedPlaceKeyAndType"],
        "tests/spec/move_place.mc": ["reject_constant_after_dynamic_multi_array_element_move"],
        "docs/compiler-production-readiness.md": ["Unknown dynamic element"],
    },
    "full alias and dereference projections": {
        "src/sema_move.zig": ["fullDerefMoveSubplace", "immediateFullDerefMoveReferent"],
        "tests/spec/move_place.mc": ["accept_move_array_element_through_full_alias", "accept_move_field_through_immediate_full_deref"],
        "docs/compiler-production-readiness.md": ["Full alias / dereference"],
    },
    "arbitrary pointee and non-nameable boundaries": {
        "src/sema_move.zig": ["arrayIndexEmbedsMove", "cannot move a linear `move` array element through an untracked dynamic index"],
        "tests/spec/move_place.mc": ["reject_dynamic_pointer_to_move_array_element", "reject_dynamic_returned_move_array_element", "reject_dynamic_array_literal_move_element"],
        "docs/compiler-production-readiness.md": ["Arbitrary pointee or non-nameable dynamic element"],
    },
}

FIXTURE_EXPECTATIONS: dict[str, dict[str, str | None]] = {
    "root and field projections": {
        "accept_move_each_field": None,
        "reject_duplicate_field_move": "E_USE_AFTER_MOVE",
    },
    "constant element projections": {
        "accept_move_array_alias_elements": None,
        "reject_duplicate_array_element_move": "E_USE_AFTER_MOVE",
    },
    "symbolic element projections": {
        "accept_branch_preserves_matching_symbolic_index": None,
        "reject_different_symbolic_dynamic_array_field_element_move": "E_USE_AFTER_MOVE",
    },
    "unknown wildcard projections": {
        "accept_dynamic_multi_array_element_move": None,
        "reject_constant_after_dynamic_multi_array_element_move": "E_USE_AFTER_MOVE",
    },
    "full alias and dereference projections": {
        "accept_move_array_element_through_full_alias": None,
        "reject_constant_after_dynamic_array_element_full_alias_move": "E_USE_AFTER_MOVE",
    },
    "arbitrary pointee and non-nameable boundaries": {
        "reject_dynamic_pointer_to_move_array_element": "E_MOVE_ARRAY_UNSUPPORTED",
        "reject_dynamic_returned_move_array_element": "E_MOVE_ARRAY_UNSUPPORTED",
        "reject_dynamic_array_literal_move_element": "E_MOVE_ARRAY_UNSUPPORTED",
    },
}


def function_body(text: str, name: str) -> str | None:
    start = text.find(f"fn {name}(")
    if start < 0:
        return None
    brace = text.find("{", start)
    if brace < 0:
        return None
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    return None


def main() -> int:
    missing: list[str] = []
    checked = 0
    for row, files in sorted(ROWS.items()):
        for relative, anchors in sorted(files.items()):
            try:
                text = (REPO_ROOT / relative).read_text(encoding="utf-8")
            except FileNotFoundError:
                missing.append(f"{row}: {relative}: file missing")
                continue
            for anchor in anchors:
                checked += 1
                if anchor not in text:
                    missing.append(f"{row}: {relative}: missing anchor {anchor!r}")

    fixture_text = (REPO_ROOT / "tests/spec/move_place.mc").read_text(encoding="utf-8")
    for row, cases in sorted(FIXTURE_EXPECTATIONS.items()):
        for name, expected in sorted(cases.items()):
            checked += 1
            body = function_body(fixture_text, name)
            if body is None:
                missing.append(f"{row}: missing fixture function {name!r}")
            elif expected is None:
                if "EXPECT_ERROR:" in body:
                    missing.append(f"{row}: accepted fixture {name!r} declares an error")
            elif f"EXPECT_ERROR: {expected}" not in body:
                missing.append(f"{row}: fixture {name!r} lacks EXPECT_ERROR: {expected}")
    if missing:
        print("FAIL: move projection inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(f"move projection inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
