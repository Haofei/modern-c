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
        "Status: complete only for bounded LLVM direct-local cleanup slices",
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
        "pub const BoundsFactKind = enum",
        "pub const BoundsFact = struct",
        "pub const SourcePoint = struct",
        "pub const PointerProvenance = enum",
        "pub const PointerProvenanceFact = struct",
        "field_path: ?[]const u8",
        "pub const PointerProvenanceInvalidationReason = enum",
        "pub const RepresentationFact = struct",
        "range_facts: []RangeFact",
        "bounds_facts: []BoundsFact",
        "pointer_provenance_facts: []PointerProvenanceFact",
        "representation_facts: []RepresentationFact",
        "elided_bounds: []SourcePoint",
    ],
    "src/mir.zig": [
        "pub fn appendDumpOpt",
        '"mir range_fact',
        '"mir bounds_fact',
        '"mir representation_fact',
        '"mir pointer_provenance_fact',
        "field={s}",
        "fn recordPointerProvenanceForLocalInitializer",
        "fn recordPointerProvenanceForAssignment",
        "fn recordPointerProvenanceCallInvalidation",
        "fn recordPointerProvenanceAddressEscape",
        "fn appendPointerFieldProvenanceFact",
        "fn appendUnknownPointerFieldProvenanceFact",
        "fn invalidatePointerFieldsForLocalPath",
        "fn directPointerProvenance",
        "fn directLocalPointerCopyProvenance",
        "fn rawManyZeroOffsetProvenance",
        "const ProvenFact = struct",
        "proven_facts: std.ArrayList(ProvenFact)",
        "pointer_provenance_facts: std.ArrayList(PointerProvenanceFact)",
        "representation_facts: std.ArrayList(RepresentationFact)",
        "const resolved_value_id = value_id orelse",
        "fn representationFactKind",
        "pub fn validateRepresentationFactsForLowering",
        "fn addRangeFactForUncheckedCall",
        "fn addAggregateRangeFactForUncheckedExpr",
        "fn invalidateFacts",
        "fn recordTrueCondFacts",
        "fn factIdentAllowed",
        "try self.elided_bounds.append",
    ],
    "src/mir_tests.zig": [
        "MIR dump exposes representation value identities",
        "representation_facts=2",
        "kind=typed_load detail=p type=*mut value_id=p",
        "kind=representation_check detail=nonnull_pointer type=*mut value_id=p",
        "kind=representation_use detail=deref_base type=*mut value_id=p",
        "mir representation_fact fn=return_ptr_param",
    ],
    "src/lower_c_arith.zig": [
        "pub const MirCheckElidedFn",
        "pub const MirNoOverflowRangeFactFn",
        "ctx.mir_check_elided",
        "has_mir_no_overflow_range_fact",
    ],
    "src/lower_c_builtin_emit.zig": [
        "uncheckedNoOverflowCallOp",
        "return error.UnsupportedCEmission",
    ],
    "src/lower_c_emitter.zig": [
        "fn arithContext",
        ".mir_check_elided = mirCheckElidedForArith",
        ".has_mir_no_overflow_range_fact = hasMirNoOverflowRangeFactForArith",
        "fn hasMirNoOverflowRangeFact",
        "fn mirCheckElided",
        "fn requireMirBoundsFact",
        "fn applyMirPointerProvenanceForLocalInitializer",
        "fn applyMirPointerProvenanceForAssignment",
        "fn applyMirPointerProvenanceForIndexAssignment",
        "fn applyMirPointerProvenanceInvalidationsAtCall",
        "fn updatePointerProvenanceFromMirOrFallback",
        "fn updatePointerProvenanceAssignmentFromMirOrFallback",
        "fn mirPointerProvenanceCoversDirectLocalUpdate",
        "fn directMirFixedPointerArrayElementExpr",
        "fn directMirPointerLocalCopyExpr",
        "fn directMirRawManyZeroOffsetExpr",
        "fn applyMirAggregatePointerFieldFactsAtSource",
        "fn applyMirAggregatePointerFieldFactsForSubjectAtSource",
        "mir_aggregate_pointer_fields",
        "fn derefAccessLowering",
        "fn derefPointerHasProvenLocalStorage",
        "fn derefPointeeType",
        "fn emitRaceLoadTempFromPointerTemp",
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
        "pointer_local_provenance: std.StringHashMap(mir.PointerProvenance)",
        "local_aggregate_pointer_aliases: std.StringHashMap([]const u8)",
        "local_array_global_pointer_elements: std.StringHashMap(mir.PointerProvenance)",
        "local_slice_global_pointer_arrays: std.StringHashMap([]const u8)",
        "fn collectGlobalPointerProvenanceSummaries",
        "fn resetTransientPointerProvenance",
        "fn seedAggregatePointerParamProvenance",
        "fn updatePointerGlobalProvenance",
        "fn updatePointerProvenanceFromMirOrFallback",
        "fn updatePointerProvenanceAssignmentFromMirOrFallback",
        "fn applyMirPointerProvenanceFactsAtSourceWithMode",
        "fn mirPointerProvenanceCoversDirectLocalUpdate",
        "fn directMirPointerLocalCopyExpr",
        "fn directMirRawManyZeroOffsetExpr",
        "fn updateAggregatePointerAliasProvenance",
        "fn applyMirAggregatePointerFieldFactsAtSource",
        "fn applyMirAggregatePointerFieldFactsForSubjectAtSource",
        "fn applyMirPointerProvenanceForLocalInitializer",
        "fn applyMirPointerProvenanceForAssignment",
        "fn applyMirPointerProvenanceForIndexAssignment",
        "fn applyMirPointerProvenanceInvalidationsAtCall",
        "fn requireMirNoOverflowRangeFact",
        "fn requireMirBoundsFact",
        "fn pointerExprHasGlobalStorageProvenance",
        "fn mirCheckElided",
        "mir range_fact consumed",
        "const use_atomic = self.derefUsesRaceTolerantLowering",
        "load atomic",
        "store atomic",
    ],
}

EXACT_COUNTS: dict[str, dict[str, int]] = {
    "src/lower_c_emitter.zig": {
        "fn requireMirBoundsFact": 1,
        "try self.requireMirBoundsFact(": 3,
        "fn hasMirNoOverflowRangeFactForArith": 1,
        "return self.hasMirNoOverflowRangeFact(": 1,
        "fn hasMirNoOverflowRangeFact(self": 1,
        "fn updatePointerProvenanceFromMirOrFallback": 1,
        "try self.updatePointerProvenanceFromMirOrFallback(": 1,
        "fn updatePointerProvenanceAssignmentFromMirOrFallback": 1,
        "try self.updatePointerProvenanceAssignmentFromMirOrFallback(": 1,
    },
    "src/lower_llvm.zig": {
        "fn requireMirBoundsFact": 1,
        "try self.requireMirBoundsFact(": 5,
        "fn requireMirNoOverflowRangeFact": 1,
        "try self.requireMirNoOverflowRangeFact(": 1,
        "current_mir_range_target": 5,
        "mir range_fact consumed": 1,
        "fn updatePointerGlobalProvenance": 1,
        "try self.updatePointerGlobalProvenance(": 2,
        "fn updatePointerProvenanceFromMirOrFallback": 1,
        "try self.updatePointerProvenanceFromMirOrFallback(": 4,
        "fn updatePointerProvenanceAssignmentFromMirOrFallback": 1,
        "try self.updatePointerProvenanceAssignmentFromMirOrFallback(": 1,
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

    if missing:
        print("semantic facts inventory anchor check failed:", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"semantic facts inventory anchors OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
