#!/usr/bin/env python3
"""Keep advanced ownership forms out of the stable ownership-v0 surface."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

ANCHORS: dict[str, list[str]] = {
    "docs/spec/MC_0.7_Final_Design.md": [
        "`#[drop]` auto-drop for nameable local places. The following forms are experimental until the",
        "`view struct`, `region struct`, `thread_move`, `borrow(source)` returned views, async ownership,",
        "Dynamic or symbolic indexes such as `arr[i]`, `arr[i + 1]`, and pointer/alias-derived",
        "The ownership authority for auto-drop is the typed MIR ownership-event stream:",
        "`auto_drop` followed by `storage_dead` closes a live local generation; `move_out`,",
        "Backend-local cleanup stacks are a transitional",
        "must fail closed when MIR does not authorize the cleanup they are about to emit.",
        "`thread_move` is not a safe proof of either property.",
        "`view struct` is experimental.",
        "`region struct` is experimental.",
    ],
    "src/sema.zig": [
        "fn_decl.return_borrow_source != null and !hasExperimentalOwnership(decl.attrs)",
        "\"`borrow(source)` return contracts are experimental; add #[experimental_ownership] to opt in while ownership cleanup authority is moving to MIR\"",
        "(struct_decl.is_region or struct_decl.is_view or struct_decl.is_thread_move) and !hasExperimentalOwnership(decl.attrs)",
        "\"`region struct`, `view struct`, and `thread_move` are experimental ownership forms; add #[experimental_ownership] to opt in while the stable subset stays move/linear/drop/lexical-borrow only\"",
        "method.return_borrow_source != null and !trait_experimental_ownership and !hasExperimentalOwnership(method.attrs)",
        "im.return_borrow_source != null and !hasExperimentalOwnership(im.attrs)",
    ],
    "src/sema_tests.zig": [
        "test \"advanced ownership forms require explicit experimental opt-in\"",
        "ownership_experimental_gate.mc",
        "try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, \"E_EXPERIMENTAL_OWNERSHIP_REQUIRED\"));",
        "test \"view structs are lexical borrow aggregates\"",
        "test \"thread spawn boundaries require unsafe checked resource handoff\"",
    ],
    "tests/spec/generic_region_view_containers.mc": [
        "#[experimental_ownership]\nregion struct Node",
        "#[experimental_ownership]\nview struct CellView",
    ],
    "tests/spec/thread_move_boundaries.mc": [
        "`thread_move` is only an experimental marker",
        "#[experimental_ownership]\nthread_move move struct SendTicket",
        "fn reject_thread_move_transfer() -> void",
    ],
}

FORBIDDEN = {
    "docs/spec/MC_0.7_Final_Design.md": [
        "`view struct` is stable",
        "`region struct` is stable",
        "`thread_move` is a safe proof",
        "`borrow(source)` is stable",
        "Backend-local cleanup stacks define ownership semantics",
        "`move_out` is auto-drop cleanup authority",
        "`explicit_drop` is auto-drop cleanup authority",
    ],
}


def fail(message: str) -> int:
    print(f"FAIL: ownership-experimental-surface-inventory-test - {message}", file=sys.stderr)
    return 1


def main() -> int:
    anchor_count = 0
    for rel_path, needles in ANCHORS.items():
        path = ROOT / rel_path
        if not path.is_file():
            return fail(f"missing {rel_path}")
        text = path.read_text(encoding="utf-8")
        for needle in needles:
            anchor_count += 1
            if needle not in text:
                return fail(f"{rel_path} missing anchor: {needle!r}")

    for rel_path, needles in FORBIDDEN.items():
        path = ROOT / rel_path
        if not path.is_file():
            return fail(f"missing {rel_path}")
        text = path.read_text(encoding="utf-8")
        for needle in needles:
            if needle in text:
                return fail(f"{rel_path} contains forbidden stable-surface wording: {needle!r}")

    print(f"PASS: ownership-experimental-surface-inventory-test - {anchor_count} anchors keep advanced ownership forms experimental")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
