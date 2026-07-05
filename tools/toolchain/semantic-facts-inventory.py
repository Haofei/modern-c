#!/usr/bin/env python3
"""Verify anchors for the typed semantic facts Phase 1 inventory.

This script is intentionally read-only and stdlib-only. It checks for stable
function/type/output anchors used by docs/typed-semantic-facts.md so inventory
drift fails closed instead of silently leaving stale evidence in the docs.
"""

from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

ANCHORS: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Phase 1 inventory: current fact-like surfaces",
        "### Phase 2: add a typed fact table for one narrow fact family",
        "Status: complete for the narrow MIR pointer/global provenance table",
        "Status: complete only for LLVM consumption of the narrow",
        "Status: complete for the narrow C subset",
        "Status: complete only for the bounded LLVM direct-local cleanup",
        "LLVM backend-local pointer/global race provenance",
        "MIR check-elision source points",
    ],
    "src/ir.zig": [
        "pub fn appendLowerIr",
        "pub fn appendFacts",
        "fn appendFacts(self: *ModuleFactCollector",
        "fn collectContractBlock",
        "fn mmioAccess",
        "fn mmioRegisterTarget",
        '"fact checked_arithmetic_trap',
        '"fact ordinary_access',
        '"fact racing_load_semantics',
        '"fact non_atomic_rmw',
        '"fact mmio_access',
    ],
    "src/main.zig": [
        'std.mem.eql(u8, command, "facts")',
        'std.mem.eql(u8, command, "lower-mir")',
        'std.mem.eql(u8, command, "lower-ir")',
        "try ir.appendFacts",
        "try mir.appendDumpOpt",
        "try ir.appendLowerIr",
    ],
    "src/mir_model.zig": [
        "pub const ValueType = union(enum)",
        "pub const Instruction = struct",
        "value_id: ?[]const u8",
        "contract_region_id: ?usize",
        "pub const RangeFact = struct",
        "pub const SourcePoint = struct",
        "pub const PointerProvenance = enum",
        "pub const PointerProvenanceFact = struct",
        "pub const PointerProvenanceInvalidationReason = enum",
        "range_facts: []RangeFact",
        "pointer_provenance_facts: []PointerProvenanceFact",
        "elided_bounds: []SourcePoint",
    ],
    "src/mir.zig": [
        "pub fn appendDumpOpt",
        '"mir range_fact',
        '"mir pointer_provenance_fact',
        "fn recordPointerProvenanceForLocalInitializer",
        "fn recordPointerProvenanceForAssignment",
        "fn recordPointerProvenanceCallInvalidation",
        "fn recordPointerProvenanceAddressEscape",
        "fn directPointerProvenance",
        "fn rawManyZeroOffsetProvenance",
        "const ProvenFact = struct",
        "proven_facts: std.ArrayList(ProvenFact)",
        "pointer_provenance_facts: std.ArrayList(PointerProvenanceFact)",
        "fn addRangeFactForUncheckedCall",
        "fn addAggregateRangeFactForUncheckedExpr",
        "fn invalidateFacts",
        "fn recordTrueCondFacts",
        "fn factIdentAllowed",
        "try self.elided_bounds.append",
    ],
    "src/lower_c_arith.zig": [
        "pub const MirCheckElidedFn",
        "pub const MirNoOverflowRangeFactFn",
        "ctx.mir_check_elided",
        "has_mir_no_overflow_range_fact",
    ],
    "src/lower_c_emitter.zig": [
        "fn arithContext",
        ".mir_check_elided = mirCheckElidedForArith",
        ".has_mir_no_overflow_range_fact = hasMirNoOverflowRangeFactForArith",
        "fn hasMirNoOverflowRangeFact",
        "fn mirCheckElided",
        "fn applyMirPointerProvenanceForLocalInitializer",
        "fn applyMirPointerProvenanceForAssignment",
        "fn applyMirPointerProvenanceForIndexAssignment",
        "fn applyMirPointerProvenanceInvalidationsAtCall",
        "fn mirPointerProvenanceDerefRaceInfo",
        "fn derefPointeeType",
        "mir pointer_provenance consumed",
        "if (self.mirCheckElided(node.index.span))",
        "if (self.mirCheckElided(slice_span))",
    ],
    "src/lower_c_global.zig": [
        "pub fn appendGlobalLoadExpr",
        "pub fn appendGlobalStorePrefix",
        "pub fn globalAssignmentTarget",
        "pub fn emitGlobalArrayElementLoadExpr",
        "pub fn appendGlobalArrayElementStore",
        "pub fn appendGlobalArrayElementMemberStore",
    ],
    "src/lower_c_inspect.zig": [
        '"lower ordinary_access',
        '"lower race_backend',
        '"lower race_semantics',
        '"lower c_ub',
        '"lower racing_load_semantics',
        '"lower contract_scope',
    ],
    "src/lower_llvm.zig": [
        "global_pointer_locals: std.StringHashMap(void)",
        "local_aggregate_pointer_aliases: std.StringHashMap([]const u8)",
        "local_array_global_pointer_elements: std.StringHashMap(void)",
        "local_slice_global_pointer_arrays: std.StringHashMap([]const u8)",
        "fn collectGlobalPointerProvenanceSummaries",
        "fn resetTransientPointerProvenance",
        "fn seedAggregatePointerParamProvenance",
        "fn updatePointerGlobalProvenance",
        "fn mirPointerProvenanceCoversDirectLocalUpdate",
        "fn directMirRawManyZeroOffsetExpr",
        "fn updateAggregatePointerAliasProvenance",
        "fn applyMirPointerProvenanceForLocalInitializer",
        "fn applyMirPointerProvenanceForAssignment",
        "fn applyMirPointerProvenanceForIndexAssignment",
        "fn applyMirPointerProvenanceInvalidationsAtCall",
        "fn pointerExprHasGlobalStorageProvenance",
        "fn mirCheckElided",
        "const use_atomic = self.pointerExprHasGlobalStorageProvenance",
        "load atomic",
        "store atomic",
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
        print("semantic facts inventory anchor check failed:", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"semantic facts inventory anchors OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
