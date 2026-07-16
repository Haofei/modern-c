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
        "fn directAliasReferentPlace",
        "fn carriedAliasReferent",
        "fn carriedAliasReferentForExpr",
        "fn markEscapedBorrowForCarriedAlias",
        "fn immediateFullDerefMoveReferent",
        "fn typedAliasReferentPlace",
        "fn typedAliasReferentPlace(referent: AliasReferent) ?MovePlace",
        "fn aliasReferentTargetsOuter",
        "fn sameDeferredBorrowFact",
        "fn recordLoopEarlyExitInvalidations",
        "fn recordInvalidatedAliasPlace",
        "const pp = placeKeyAndType(self, expr, state) orelse return null;",
        "const base = placeKeyAndType(self, ix.base.*, state) orelse return null;",
        "const AliasPlaceInfo = struct",
        "place: MovePlace",
        "fn markDeferredBorrowAliasReferent",
        "fn markDeferredBorrowReferent(self: *Checker, borrowed_place: MovePlace",
    ],
    "docs/compiler-production-readiness.md": [
        "Move checker alias assignment updates use typed storage places",
        "Move checker alias key formatter has no external callers",
        "Move checker alias key formatter is retired",
        "Move checker laundered referents are typed",
        "Move checker deferred aliases use typed referents",
        "move-place-identity-inventory.py",
    ],
}

EXACT_COUNTS: dict[str, dict[str, int]] = {
    "src/sema_move.zig": {
        # aliasPlaceKey was a display-key formatter. Keeping it at zero prevents
        # reintroducing formatted storage identity as a move-checker authority.
        "aliasPlaceKey": 0,
        "aliasPlaceIndex": 0,
        "callLaunderedMoveReferent": 0,
        "invalidated_aliases": 0,
        "state.getPtr(key)": 0,
        "state.remove(key)": 0,
        "state.getPtr(target_info.key)": 0,
        "state.remove(target_info.key)": 0,
        "outer.contains(aliasReferentRoot(referent))": 0,
    },
}

BLOCK_FORBIDDEN: dict[str, dict[tuple[str, str], list[str]]] = {
    "src/sema_move.zig": {
        ("fn aliasWildcardPlaceInfo", "fn aliasPlaceBaseType"): [
            "const base = aliasPlaceKey(self, ix.base.*, state) orelse return null;",
        ],
        ("pub fn moveDefer", "fn cleanupLocalAliasReferent"): [
            "markDeferredBorrowReferent(self, referent, deferredAliasBorrowPlace",
            "markDeferredBorrowReferent(self, referent.key",
        ],
        ("fn markDeferredBorrowReferent", "fn markDeferredBorrowAliasReferent"): [
            "state.get(",
            "referent: []const u8",
            "place: ?MovePlace",
        ],
        ("fn aliasSlotReferentMoved", "fn referentPlaceMoved"): [
            "state.get(",
            "referent_slot",
        ],
        ("fn typedAliasReferentPlace", "fn aliasReferentTargetsOuter"): [
            "state.get(",
            "referent.key",
        ],
        ("fn carriedAliasReferent", "fn carriedAliasReferentForExpr"): [
            "state.get(",
            "trackedMoveReferentPlaceForKey",
        ],
        ("fn carriedAliasReferentForExpr", "fn trackedMoveReferentPlaceForKey"): [
            "trackedMoveReferentPlaceForKey",
            "spine.",
        ],
        ("fn markEscapedBorrowForCarriedAlias", "// Map keys remain compatibility indexes"): [
            "trackedMoveReferentPlaceForKey",
            "spine.",
            "markEscapedBorrowForReferentKey",
        ],
        ("fn immediateFullDerefMoveReferent", "fn consumeTrackedMoveBinding"): [
            "trackedMoveReferentPlaceForKey",
            "spine.borrowedMoveRoot",
        ],
        ("fn consumeTrackedMoveReferent", "// An alias can retain a typed root place"): [
            "consumeTrackedMoveBinding",
            "referent.place",
        ],
        ("fn recordLoopEarlyExitInvalidations", "fn recordInvalidatedAliasPlace"): [
            "invalidated_aliases",
        ],
        ("fn applyLoopEarlyExitAliasInvalidations", "pub fn cloneMoveState"): [
            "invalidated_aliases",
            "state.getPtr(name.*)",
        ],
        ("fn callLaunderedMoveAliasReferent", "// (bug #3 / T1.3)"): [
            "trackedMoveReferentPlaceForKey",
            "spine.borrowedMoveRoot",
            "spine.aliasReferentOf",
        ],
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

        for (start_anchor, end_anchor), forbidden_items in BLOCK_FORBIDDEN.get(relative, {}).items():
            checked += 1
            start = text.find(start_anchor)
            end = text.find(end_anchor, start + len(start_anchor)) if start != -1 else -1
            if start == -1 or end == -1:
                missing.append(f"{relative}: cannot find block {start_anchor!r}..{end_anchor!r}")
                continue
            block = text[start:end]
            for forbidden in forbidden_items:
                checked += 1
                if forbidden in block:
                    missing.append(f"{relative}: block {start_anchor!r} still contains {forbidden!r}")

    if missing:
        print("FAIL: move place identity inventory drift", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"move place identity inventory OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
