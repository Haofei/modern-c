#!/usr/bin/env python3
"""Verify anchors for the typed semantic facts Phase 1 inventory.

This script is intentionally read-only and stdlib-only. It checks for stable
function/type/output anchors used by docs/typed-semantic-facts.md so inventory
drift fails closed instead of silently leaving stale evidence in the docs.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

SEMANTIC_INFERENCE_FAMILIES: dict[str, dict[str, list[str]]] = {
    "c-expression-type-inference": {
        "docs/typed-semantic-facts.md": ["| `c-expression-type-inference` |"],
        "src/lower_c_infer.zig": [
            "//! C backend expression type inference helpers.",
            "pub fn operandEmitType(",
            "pub fn derefPointeeType(",
        ],
    },
    "c-type-shape-classification": {
        "docs/typed-semantic-facts.md": ["| `c-type-shape-classification` |"],
        "src/lower_c_info.zig": [
            "const LocalInfo = lower_c_model.LocalInfo",
            "const GlobalInfo = lower_c_model.GlobalInfo",
            "pub fn localInfoFromType(",
            "pub fn globalInfoFromType(",
        ],
        "src/lower_c_shape.zig": [
            "pub fn resolvedArrayChildType(",
            "pub fn isPointerLikeGlobalType(",
        ],
    },
    "c-abi-aggregate-lowering": {
        "docs/typed-semantic-facts.md": ["| `c-abi-aggregate-lowering` |"],
        "src/lower_c_aggregate.zig": [
            "pub fn emitArrayLiteral(",
            "pub fn emitStructLiteral(",
            "pub fn emitTaggedUnionConstructor(",
        ],
    },
    "c-call-target-classification": {
        "docs/typed-semantic-facts.md": ["| `c-call-target-classification` |"],
        "src/lower_c_call.zig": [
            "pub fn emitBitcastInferredLocalInit(",
            "pub fn emitExternNonNullCallInferredLocalInit(",
            "pub fn emitSequencedCallLocalInit(",
            "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .declassify",
            "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .assume_noalias",
        ],
        "src/lower_c_builtin.zig": [
            "pub fn reflectionCallKind(",
            "const byteViewCallKind = ast_query.byteViewCallKind",
        ],
        "src/lower_c_reflect.zig": [
            "mir.reflectionCallTargetKind(call)",
            "ctx.mir_call_target_kind(ctx.type_ctx, call.callee.*.span) != expected_fact",
        ],
        "src/lower_c_memory.zig": [
            "mir.byteViewCallTargetKind(call)",
            "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != expected_fact",
        ],
        "src/lower_c_convert.zig": [
            "mir.conversionCallTargetKindForName(op)",
            "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != expected_target",
        ],
    },
    "c-bounds-range-consumption": {
        "docs/typed-semantic-facts.md": ["| `c-bounds-range-consumption` |"],
        "src/lower_c_emitter.zig": [
            "fn requireMirBoundsFact(",
            "fn hasMirNoOverflowRangeFact(",
            "fn mirCheckElided(",
        ],
    },
    "c-pointer-provenance-consumption": {
        "docs/typed-semantic-facts.md": ["| `c-pointer-provenance-consumption` |"],
        "src/lower_c_emitter.zig": [
            "fn updatePointerProvenanceFromMir(",
            "fn derefAccessLowering(",
            "fn derefPointerHasProvenLocalStorage(",
        ],
    },
    "c-direct-global-race-helpers": {
        "docs/typed-semantic-facts.md": ["| `c-direct-global-race-helpers` |"],
        "src/lower_c_global.zig": [
            "pub fn appendGlobalLoadExpr(",
            "pub fn appendGlobalStorePrefix(",
            "pub fn globalAssignmentTarget(",
        ],
    },
    "llvm-pointer-provenance-consumption": {
        "docs/typed-semantic-facts.md": ["| `llvm-pointer-provenance-consumption` |"],
        "src/lower_llvm.zig": [
            "fn updatePointerProvenanceFromMirOrLocalProof(",
            "fn derefUsesRaceTolerantLowering(",
            "fn pointerExprHasGlobalStorageProvenance(",
        ],
    },
    "llvm-expression-type-inference": {
        "docs/typed-semantic-facts.md": ["| `llvm-expression-type-inference` |"],
        "src/ast_query.zig": [
            "pub fn bitcastCallReturnType(",
            "pub fn atomicMemberOpName(",
            "pub fn atomicCallMemberOp(",
            "pub fn maybeUninitMemberOpName(",
            "pub fn maybeUninitCallMemberOp(",
            "pub fn isDeclassifyCallee(",
            "pub fn isDeclassifyCall(",
            "pub fn resultConstructorCallTag(",
            "pub fn isPhysCall(",
            "pub fn isBindCallNode(",
            "pub fn isBindCallExpr(",
            "pub fn reduceCallKind(",
            "pub fn reduceCallOpName(",
            "pub fn constGetCallTarget(",
        ],
        "src/lower_llvm.zig": [
            "fn exprType(",
            "fn derefPointeeType(",
            "isDeclassifyCall(call)",
            "resultConstructorCallTag(call)",
            "isBindCallExpr(expr)",
            "isBindCallNode(call)",
            "fn physCallTargetType(",
            "self.mirCallTargetKindAt(call.callee.*.span) != .phys",
            "constGetCallTarget(call)",
        ],
    },
    "llvm-bounds-range-consumption": {
        "docs/typed-semantic-facts.md": ["| `llvm-bounds-range-consumption` |"],
        "src/lower_llvm.zig": [
            "fn requireMirBoundsFact(",
            "fn requireMirNoOverflowRangeFact(",
            "fn mirCheckElided(",
        ],
    },
    "llvm-representation-fact-consumption": {
        "docs/typed-semantic-facts.md": ["| `llvm-representation-fact-consumption` |"],
        "src/mir.zig": ["pub fn validateRepresentationFactsForLowering"],
        "src/lower_llvm.zig": ["try mir.validateRepresentationFactsForLowering(module_mir.*)"],
    },
    "mir-pointer-provenance-production": {
        "docs/typed-semantic-facts.md": ["| `mir-pointer-provenance-production` |"],
        "src/mir.zig": [
            "fn recordPointerProvenanceForLocalInitializer",
            "fn appendPointerFieldProvenanceFact",
            "fn recordPointerProvenanceAddressEscape",
        ],
    },
    "mir-aggregate-return-production": {
        "docs/typed-semantic-facts.md": ["| `mir-aggregate-return-production` |"],
        "src/mir.zig": [
            "fn appendAggregateReturnPointerFact",
            "fn collectSequentialSwitchAggregateReturnLiteralPathsFrom",
            "max_aggregate_return_literal_paths",
        ],
    },
    "mir-bounds-range-production": {
        "docs/typed-semantic-facts.md": ["| `mir-bounds-range-production` |"],
        "src/mir.zig": [
            "fn addRangeFactForUncheckedCall",
            "fn addAggregateRangeFactForUncheckedExpr",
            "try self.elided_bounds.append",
        ],
    },
    "sema-call-type-resolution": {
        "docs/typed-semantic-facts.md": ["| `sema-call-type-resolution` |"],
        "src/sema.zig": [
            "pub fn directCallReturnType(",
            "fn fnPointerCallReturnType(",
            "fn closureCallReturnType(",
        ],
    },
    "sema-layout-representation-checks": {
        "docs/typed-semantic-facts.md": ["| `sema-layout-representation-checks` |"],
        "src/sema.zig": [
            "const layoutFieldInfo = sema_lookup.layoutFieldInfo",
            "fn packedBitsInfoForType(",
            "const isBitcastLayoutClass = sema_type.isBitcastLayoutClass",
        ],
    },
}

BACKEND_AST_INFERENCE_BUDGET: dict[str, object] = {
    "docs/typed-semantic-facts.md": [
        "Current backend AST-inference budget: **8 registered families**.",
        "| `c-expression-type-inference` | Backend AST inference budget |",
        "| `c-type-shape-classification` | Backend AST inference budget |",
        "| `c-abi-aggregate-lowering` | Backend AST inference budget |",
        "| `c-call-target-classification` | Backend AST inference budget |",
        "| `c-direct-global-race-helpers` | Backend AST inference budget |",
        "| `c-pointer-provenance-consumption` | Backend AST inference budget |",
        "| `llvm-pointer-provenance-consumption` | Backend AST inference budget |",
        "| `llvm-expression-type-inference` | Backend AST inference budget |",
    ],
    "families": [
        "c-expression-type-inference",
        "c-type-shape-classification",
        "c-abi-aggregate-lowering",
        "c-call-target-classification",
        "c-direct-global-race-helpers",
        "c-pointer-provenance-consumption",
        "llvm-pointer-provenance-consumption",
        "llvm-expression-type-inference",
    ],
}

SCALAR_DEREF_DEFAULT_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Scalar pointer deref default audit",
        "| C bare scalar pointer deref |",
        "| C aggregate pointer deref leaves |",
        "| LLVM bare scalar pointer deref |",
        "| LLVM aggregate pointer deref leaves |",
    ],
    "src/lower_c_emitter.zig": [
        "fn derefPointerHasProvenLocalStorage(",
        "fn directLocalStorageTarget(",
        "fn derefAccessLowering(",
        "fn emitRaceTolerantDerefStoreStmt(",
        "fn emitRaceTolerantAggregateDerefExpr(",
        "fn emitRaceTolerantAggregateLoadFromPtr(",
        "fn emitRaceTolerantAggregateStoreFromPtr(",
    ],
    "src/lower_llvm.zig": [
        "fn pointerExprHasProvenLocalStorage(",
        "fn directLocalStorageRoot(",
        "fn derefUsesRaceTolerantLowering(",
        "fn emitDeref(",
        "fn emitRaceTolerantAggregateDerefLoad(",
        "fn emitRaceTolerantAggregateDerefStore(",
    ],
}

ESCAPED_POINTER_BOUNDARY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Escaped pointer boundary audit",
        "| Direct pointer argument escape |",
        "| Aggregate address escape |",
        "| Function-pointer callback escape |",
    ],
    "src/lower_c_emitter.zig": [
        "self.applyMirPointerProvenanceInvalidationsAtCall(expr.span, locals);",
        "fn applyMirPointerProvenanceInvalidationsAtCall(",
    ],
    "src/lower_c_tests.zig": [
        "lower-c escaped pointer provenance lowers conservatively",
        "escaped_local_pointer_lowers_race_tolerant",
        "escaped_aggregate_pointer_field_lowers_race_tolerant",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM escaped pointer provenance lowers conservatively",
        "consume_alias_copy_escape_param",
        "consume_aggregate_alias_copy_escape_param",
        "escaped_local_pointer_lowers_race_tolerant",
        "escaped_aggregate_pointer_field_lowers_race_tolerant",
    ],
    "src/mir_tests.zig": [
        "MIR pointer provenance facts fail closed on reassignment dynamic writes calls and address escape",
        "invalidation_reason=address_escape",
    ],
}

RETURNED_POINTER_FACTS_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Returned pointer facts audit",
        "| Direct internal return |",
        "| Local function alias return |",
        "| Callback/function-pointer return |",
        "| Exported pointer return |",
    ],
    "src/mir.zig": [
        "fn collectDirectGlobalPointerReturnSummaries(",
        "fn directPointerReturnAliasTarget(",
    ],
    "src/mir_tests.zig": [
        "MIR records direct internal global pointer return provenance in callers",
        "uses_callback_pointer_return",
        "uses_exported_global_pointer",
    ],
    "src/lower_c_tests.zig": [
        "lower-c consumes MIR facts for direct internal global pointer returns",
        "c_uses_callback_pointer_return",
        "c_uses_exported_global_pointer",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM consumes MIR facts for direct internal global pointer returns",
        "uses_callback_pointer_return",
        "uses_exported_global_pointer",
    ],
}

AGGREGATE_RETURN_CFG_DECISION_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Aggregate-return unsupported CFG matrix",
        "| Non-transparent nested call/control |",
        "| Above-cap path expansion |",
        "| Argument-bearing tracked-local calls/defer |",
        "| Non-stable pointer mutation in loop prefixes |",
        "| Ambiguous dynamic-index writes |",
        "| Dereference writes through aliases |",
        "| Exported or escaping-local aggregate returns |",
        "| Unsupported aggregate nesting |",
    ],
    "src/mir_tests.zig": [
        "MIR records direct aggregate-return pointer facts and excludes legacy shapes",
        "nested_call_control_holder",
        "path_overflow_switch_holder",
        "local_defer_arg_prefix_holder",
        "mixed_pointer_mutating_while_prefix_holder",
        "trailing_mixed_dynamic_array_updated_holder",
        "deref_updated_holder",
        "exported_holder",
        "local_only_holder",
    ],
    "src/lower_c_tests.zig": [
        "lower-c aggregate-return nested call control fails closed",
        "lower-c aggregate-return path overflow switches fail closed",
        "lower-c aggregate-return mixed pointer-mutating while prefix fails closed",
        "lower-c aggregate-return dereference writes fail closed",
        "lower-c aggregate-return nested pointer arrays with missing leaf facts fail closed",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM aggregate-return nested call control fails closed",
        "LLVM aggregate-return path overflow switches fail closed",
        "LLVM aggregate-return mixed pointer-mutating while prefix fails closed",
        "LLVM aggregate-return dereference writes fail closed",
        "LLVM aggregate-return nested pointer arrays with missing leaf facts fail closed",
    ],
}

BOUNDS_RANGE_FACT_FAMILY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "| MIR no-overflow range facts |",
        "| MIR bounds facts |",
        "| MIR check-elision source points |",
        "| `c-bounds-range-consumption` |",
        "| `llvm-bounds-range-consumption` |",
    ],
    "docs/compiler-production-readiness.md": [
        "| Bounds checks require typed MIR facts |",
        "| MIR bounds facts have a stable dump artifact |",
        "| Typed semantic facts inventory pins bounds-fact consumers |",
        "Bounds/range fact family is gated",
    ],
    "src/mir_model.zig": [
        "pub const RangeFact = struct",
        "pub const BoundsFact = struct",
        "bounds_facts: []BoundsFact",
        "range_facts: []RangeFact",
        "elided_bounds: []SourcePoint",
    ],
    "src/mir.zig": [
        '"mir range_fact',
        '"mir bounds_fact',
        '"mir elided_bounds_fact',
        "try self.bounds_facts.append",
        "fn addRangeFactForUncheckedCall",
        "fn addAggregateRangeFactForUncheckedExpr",
    ],
    "src/mir_tests.zig": [
        "MIR dump emits non-elided bounds facts",
        "MIR dump exposes elided bounds facts",
        "MIR records no_overflow range facts for unchecked add contract",
    ],
    "src/lower_c_tests.zig": [
        "lower-c rejects prebuilt MIR with missing bounds facts",
        "lower-c unchecked arithmetic requires MIR no-overflow range fact",
        "appendCheckedCTestWithRetargetedRangeFacts",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM rejects prebuilt MIR with missing bounds facts",
        "LLVM unchecked arithmetic requires MIR no-overflow range fact",
        "appendLlvmTestWithRetargetedRangeFacts",
    ],
}

INTEGER_DEFAULT_FACT_FAMILY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "| MIR integer literal facts |",
        "target-typed integer literal conversion",
        "validateIntegerFactsForLowering",
    ],
    "docs/compiler-production-readiness.md": [
        "Integer/default fact family is gated",
    ],
    "src/mir_model.zig": [
        "integer_literal_conversion",
        "pub const IntegerFact = struct",
        "pub const TargetTypeFact = struct",
        "integer_facts: []IntegerFact",
        "target_type_facts: []TargetTypeFact",
    ],
    "src/mir.zig": [
        '"mir integer_fact',
        '"mir target_type_fact',
        "fn addIntegerLiteralFact(",
        "pub fn validateIntegerFactsForLowering(",
        "fn functionHasMatchingIntegerFact(",
        "fn integerFactLiteralText(",
    ],
    "src/mir_tests.zig": [
        "MIR dump emits target-typed integer literal facts",
        "mir integer_fact fn=integer_literals literal=255 target_type=u8 recorded=true",
    ],
    "src/lower_c.zig": [
        "try mir.validateIntegerFactsForLowering(typed_mir.*);",
    ],
    "src/lower_llvm.zig": [
        "try mir.validateIntegerFactsForLowering(module_mir.*);",
    ],
    "src/lower_c_tests.zig": [
        "lower-c rejects prebuilt MIR with missing integer facts",
        "lower-c rejects prebuilt MIR with stale integer facts",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM rejects prebuilt MIR with missing integer facts",
        "LLVM rejects prebuilt MIR with stale integer facts",
    ],
}

REPRESENTATION_FACT_HARDENING_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Representation-fact hardening audit",
        "| Owned fact model |",
        "| Backend admission gate |",
        "| Extra stale-fact rejection |",
    ],
    "docs/compiler-production-readiness.md": [
        "Representation-fact hardening is gated",
    ],
    "src/mir_model.zig": [
        "pub const RepresentationFact = struct",
        "representation_facts: []RepresentationFact",
    ],
    "src/mir.zig": [
        "pub fn validateRepresentationFactsForLowering",
        "fn functionHasMatchingRepresentationFact",
        "fn functionHasMatchingRepresentationInstruction",
        "fn representationFactKind",
    ],
    "src/lower_c.zig": [
        "try mir.validateRepresentationFactsForLowering(typed_mir.*);",
    ],
    "src/lower_llvm.zig": [
        "try mir.validateRepresentationFactsForLowering(module_mir.*);",
    ],
    "src/lower_c_tests.zig": [
        "lower-c rejects prebuilt MIR with missing representation facts",
        "lower-c rejects prebuilt MIR with stale representation facts",
        "lower-c rejects prebuilt MIR with extra stale representation facts",
        "fn appendStaleRepresentationFactForFunction",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM rejects prebuilt MIR with missing representation facts",
        "LLVM rejects prebuilt MIR with stale representation facts",
        "LLVM rejects prebuilt MIR with extra stale representation facts",
        "fn appendStaleRepresentationFactForFunction",
    ],
    "src/mir_tests.zig": [
        "MIR dump exposes representation value identities",
        "MIR target representation checks see through casts",
        "mir representation_fact fn=return_ptr_param",
    ],
}

ANCHORS: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Phase 1 inventory: current fact-like surfaces",
        "### Phase 2: add a typed fact table for one narrow fact family",
        "Status: complete for the narrow MIR pointer/global provenance table",
        "Status: complete only for LLVM consumption of the narrow",
        "Status: complete for the narrow C subset",
        "Status: complete for retirement of global pointer-local AST inference",
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
    "src/numeric.zig": [
        "pub fn parseIntegerLiteral",
        "if (raw.len > cleaned.len) return null;",
        "std.fmt.parseInt(u128",
    ],
    "src/sema.zig": [
        "fn checkIntegerLiteralInitializer",
        "fn checkTargetlessLiteralInitializer",
        "fn checkLiteralOperandAgainstClass",
        "fn integerLiteralSyntaxOverflow",
        "E_INTEGER_LITERAL_OUT_OF_RANGE",
    ],
    "src/mir_model.zig": [
        "pub const ValueType = union(enum)",
        "pub const Instruction = struct",
        "value_id: ?[]const u8",
        "contract_region_id: ?usize",
        "pub const IntegerFact = struct",
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
        "integer_facts: []IntegerFact",
        "pointer_provenance_facts: []PointerProvenanceFact",
        "representation_facts: []RepresentationFact",
        "elided_bounds: []SourcePoint",
    ],
    "src/mir.zig": [
        "pub fn appendDumpOpt",
        '"mir range_fact',
        '"mir bounds_fact',
        '"mir integer_fact',
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
        "fn addIntegerLiteralFact",
        "pub fn validateIntegerFactsForLowering",
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
    "tests/spec/no_implicit_conversion.mc": [
        "reject_binary_operand_larger_than_u128",
        "reject_literal_larger_than_u128",
    ],
    "tests/spec/initialization.mc": [
        "reject_targetless_integer_larger_than_u128",
    ],
    "tests/spec/global_initializers.mc": [
        "reject_out_of_range_initializer",
    ],
    "tests/spec/return_types.mc": [
        "reject_out_of_range_literal_return",
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
        "fn updatePointerProvenanceFromMir",
        "fn updatePointerProvenanceAssignmentFromMir",
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
    "src/lower_c.zig": [
        "try mir.validateIntegerFactsForLowering(typed_mir.*);",
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
        "try mir.validateIntegerFactsForLowering(module_mir.*);",
        "pointer_local_provenance: std.StringHashMap(mir.PointerProvenance)",
        "local_aggregate_pointer_aliases: std.StringHashMap([]const u8)",
        "local_array_global_pointer_elements: std.StringHashMap(mir.PointerProvenance)",
        "local_slice_global_pointer_arrays: std.StringHashMap([]const u8)",
        "fn collectMirAggregateReturnPointerFieldFacts",
        "fn resetTransientPointerProvenance",
        "fn updatePointerProvenanceFromMirOrLocalProof",
        "fn updatePointerProvenanceAssignmentFromMirOrLocalProof",
        "fn applyMirPointerProvenanceFactsAtSourceWithMode",
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
    "src/mir.zig": {
        "fn addSelfTypedExpressionFact(": 1,
        "qualified_union_result": 1,
        "enum_variant_path_result": 1,
        "appendTargetTypeFact(.reflection_result": 1,
        "appendTargetTypeFact(.byte_view_result": 1,
        "fn vaCallFactInfo(": 1,
        "addCallTargetFact(va.kind": 1,
        "appendTargetTypeFact(.raw_load_result": 1,
        "appendTargetTypeFact(.raw_ptr_result": 1,
        "fn semanticEscapeSourceTypeExpr(": 1,
        "try self.appendTargetTypeFact(source_kind, target.source_type_expr": 1,
        "try self.appendTargetTypeFact(result_kind, target.result_type_expr": 1,
    },
    "src/numeric.zig": {
        "pub fn parseIntegerLiteral": 1,
        "std.fmt.parseInt(u128": 1,
    },
    "src/lower_c.zig": {
        "try mir.validateIntegerFactsForLowering(typed_mir.*);": 1,
        "try mir.validateTargetTypeFactsForLowering(typed_mir.*);": 1,
    },
    "src/sema.zig": {
        "fn checkIntegerLiteralInitializer": 1,
        "fn checkTargetlessLiteralInitializer": 1,
        "fn checkLiteralOperandAgainstClass": 1,
        "fn integerLiteralSyntaxOverflow": 1,
        "if (integerLiteralSyntaxOverflow(expr))": 4,
        "fn rawLoadCallReturnType(": 0,
        "fn isRawPtrCall(": 0,
        "fn bitcastCallReturnType(": 0,
        "fn vaCallName(": 0,
        "fn vaCallReturnType(": 0,
        "fn byteViewCallReturnType(": 0,
        "std.mem.eql(u8, member.name.text, \"fetch_add\")": 0,
        "std.mem.eql(u8, member.name.text, \"assume_init\")": 0,
        "const isDeclassifyCallName = sema_builtin.isDeclassifyCallName;": 0,
        "const ptr_ty = ast.TypeExpr{ .span = node.type_args[0].span": 0,
    },
    "src/sema_builtin.zig": {
        "pub fn isDeclassifyCallName(": 0,
    },
    "src/lower_c_expr.zig": {
        "pub fn isDeclassifyCall(": 0,
    },
    "src/lower_llvm_query.zig": {
        "pub fn builtinCallReturnType(": 0,
        "ast_query.rawLoadCallReturnType(call)": 0,
        "ast_query.rawPtrCallReturnType(call)": 0,
        "pub fn isDeclassifyCall(": 0,
        "pub fn isResultConstructorCall(": 0,
        "pub fn isPhysCall(": 0,
        "pub fn isBindCall(": 0,
        "pub fn isBindCallByNode(": 0,
        "fn bitcastTargetType(": 0,
        "pub fn reflectionCallKind(": 0,
        "pub const ReflectionCallKind": 0,
        "ast_query.isPhysCall(call.callee.*)": 0,
    },
    "src/lower_c_emitter.zig": {
        "fn mirTargetTypeFactAt(": 1,
        "mirTargetTypeFactAt(.value_optional_coercion": 1,
        "mirTargetTypeFactAt(.dyn_coercion": 1,
        "mirTargetTypeFactAt(.explicit_cast_source": 2,
        "mirTargetTypeFactAt(.explicit_cast_target": 6,
        "mirTargetTypeFactAt(.view_const_narrow_source": 1,
        "mirTargetTypeFactAt(.view_const_narrow_target": 1,
        "mirTargetTypeFactAt(.qualified_union_result": 1,
        "mirTargetTypeFactAt(.reflection_result": 2,
        "mirTargetTypeFactAt(.byte_view_result": 2,
        "mirTargetTypeFactAt(.declassify_result": 2,
        "mirTargetTypeFactAt(.assume_noalias_result": 2,
        "self.exprSourceTypeForEmission(value_expr, locals)": 0,
        "self.cTypeFor(node.ty.*, .typedef_name)": 0,
        "self.emitExprWithTarget(node.value.*, locals, node.ty.*)": 0,
        "self.current_function = global.name.text;": 1,
        "if (span.line == 0 or span.column == 0) return null;": 1,
        "fn emitEnumLiteralWithTarget(self: *CEmitter, literal: ast.Ident, target_ty:": 0,
        "fn emitStringLiteralWithTarget(self: *CEmitter, literal: []const u8, target_ty:": 0,
        "fn emitAggregateLiteralWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty:": 0,
        "fn mirAggregateTargetTypeForExpr(": 1,
        "fn mirFloatLiteralTargetForExpr(": 1,
        "emitTaggedUnionConstructor(self.aggregateEmitContext(), node, locals, ty)": 0,
        "fn requireMirBoundsFact": 1,
        "try self.requireMirBoundsFact(": 3,
        "fn hasMirNoOverflowRangeFactForArith": 1,
        "return self.hasMirNoOverflowRangeFact(": 1,
        "fn hasMirNoOverflowRangeFact(self": 1,
        "fn updatePointerProvenanceFromMir": 1,
        "try self.updatePointerProvenanceFromMir(": 1,
        "fn updatePointerProvenanceAssignmentFromMir": 1,
        "try self.updatePointerProvenanceAssignmentFromMir(": 1,
        "fn mirPointerProvenanceCoversDirectLocalUpdate": 0,
        "global_pointer_return_fns": 0,
        "fn collectGlobalPointerProvenanceSummaries": 0,
        "fn derefAccessLowering(": 1,
        "try self.derefAccessLowering(": 2,
        "fn derefPointerHasProvenLocalStorage(": 1,
    },
    "src/lower_c_convert.zig": {
        "mir.conversionCallTargetKindForName(op)": 1,
        "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != expected_target": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .conversion_source": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .conversion_target": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .bitcast_source": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .bitcast_target": 1,
        "resolveAliasType(ctx.type_aliases, call.type_args[0])": 0,
        "numeric_expr_type:": 0,
    },
    "src/lower_c_infer.zig": {
        "mir_target_type(ctx.source_ctx, .qualified_union_result": 1,
        "mir_target_type(ctx.source_ctx, .enum_variant_path_result": 1,
        "fn qualifiedUnionConstructorType(": 0,
        "fn enumVariantPathType(": 0,
        "taggedUnionCase(union_decl": 0,
        "for (enum_decl.cases)": 0,
        "fn assumeNoaliasReturnTypeForCall(": 0,
    },
    "src/lower_c_reflect.zig": {
        "mir.reflectionCallTargetKind(call)": 1,
        "ctx.mir_call_target_kind(ctx.type_ctx, call.callee.*.span) != expected_fact": 1,
        "mir_target_type(ctx.type_ctx, .reflection_result": 1,
    },
    "src/lower_c_memory.zig": {
        "mir.byteViewCallTargetKind(call)": 1,
        "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != expected_fact": 1,
        "mir_target_type(ctx.emit_ctx, .byte_view_result": 1,
    },
    "src/lower_c_call.zig": {
        "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .declassify": 1,
        "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != .assume_noalias": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .raw_load_result": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .raw_ptr_result": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .va_start_result": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .va_arg_result": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .bitcast_source": 2,
        "ctx.mir_target_type(ctx.emit_ctx, .bitcast_target": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .phys_result": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .declassify_source": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .declassify_result": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .assume_noalias_source": 1,
        "ctx.mir_target_type(ctx.emit_ctx, .assume_noalias_result": 1,
        "return call.type_args[0];": 0,
    },
    "src/lower_llvm.zig": {
        "try mir.validateIntegerFactsForLowering(module_mir.*);": 1,
        "try mir.validateTargetTypeFactsForLowering(module_mir.*);": 1,
        "fn mirTargetTypeFactAt(": 1,
        "mirTargetTypeFactAt(.value_optional_coercion": 1,
        "mirTargetTypeFactAt(.dyn_coercion": 1,
        "mir.conversionCallTargetKindForName(member.name.text)": 1,
        "self.mirCallTargetKindAt(call.callee.*.span) != expected_kind": 1,
        "mirTargetTypeFactAt(.conversion_source": 1,
        "mirTargetTypeFactAt(.conversion_target": 1,
        "mirTargetTypeFactAt(.explicit_cast_source": 2,
        "mirTargetTypeFactAt(.explicit_cast_target": 3,
        "mirTargetTypeFactAt(.view_const_narrow_source": 2,
        "mirTargetTypeFactAt(.view_const_narrow_target": 2,
        "mirTargetTypeFactAt(.raw_load_result": 2,
        "mirTargetTypeFactAt(.raw_ptr_result": 2,
        "mirTargetTypeFactAt(.va_start_result": 3,
        "mirTargetTypeFactAt(.va_arg_result": 2,
        "mirTargetTypeFactAt(.qualified_union_result": 2,
        "mirTargetTypeFactAt(.enum_variant_path_result": 2,
        "mirTargetTypeFactAt(.reflection_result": 2,
        "mirTargetTypeFactAt(.byte_view_result": 2,
        "mirTargetTypeFactAt(.bitcast_source": 1,
        "mirTargetTypeFactAt(.bitcast_target": 1,
        "mirTargetTypeFactAt(.phys_result": 1,
        "mirTargetTypeFactAt(.declassify_source": 1,
        "mirTargetTypeFactAt(.declassify_result": 2,
        "mirTargetTypeFactAt(.assume_noalias_source": 1,
        "mirTargetTypeFactAt(.assume_noalias_result": 2,
        "reflectionValueCallReturnType(call)": 0,
        "byteViewCallReturnType(call)": 0,
        "vaCallReturnType(call)": 0,
        "fn emitCast(self: *LlvmEmitter, value_expr: ast.Expr, target_ty:": 0,
        "const source_ty = self.exprType(value_expr)": 0,
        "self.exprType(call.args[0]) orelse info.target_ty": 0,
        "self.exprType(call.args[0]) orelse expected_ty": 0,
        "self.current_function = global.name.text;": 1,
        "if (span.line == 0 or span.column == 0) return null;": 1,
        "fn bindClosureType(": 0,
        "emitTaggedUnionConstructor(call, expected_ty)": 0,
        "enumDeclForType(expected_ty)) |enum_decl|\n                try self.enumCaseValueByName": 0,
        "fn emitStringLiteral(self: *LlvmEmitter, literal: []const u8, expected_ty:": 0,
        "emitArrayLiteralValue(expected_ty, items)": 0,
        "packedBitsInfoForType(expected_ty)": 0,
        "emitStructLiteralValue(expected_ty, fields)": 0,
        "normalizedFloatLiteral(self.scratch.allocator(), literal, self.isF32TypeOf(expected_ty))": 0,
        "fn requireMirBoundsFact": 1,
        "try self.requireMirBoundsFact(": 5,
        "fn requireMirNoOverflowRangeFact": 1,
        "try self.requireMirNoOverflowRangeFact(": 1,
        "current_mir_range_target": 5,
        "mir range_fact consumed": 1,
        "fn updatePointerGlobalProvenance": 0,
        "try self.updatePointerGlobalProvenance(": 0,
        "fn updatePointerProvenanceFromMirOrLocalProof": 1,
        "try self.updatePointerProvenanceFromMirOrLocalProof(": 1,
        "fn updatePointerProvenanceAssignmentFromMirOrLocalProof": 1,
        "try self.updatePointerProvenanceAssignmentFromMirOrLocalProof(": 1,
        "std.mem.eql(u8, op, \"sum_checked\")": 0,
        "if (!std.mem.eql(u8, member.name.text, \"const_get\")) return null;": 0,
        "fn mirPointerProvenanceCoversDirectLocalUpdate": 1,
        "fn collectAggregateReturnPointerFieldSummaries": 0,
        "fn collectAggregateReturnPointerFieldsForFunction": 0,
        "fn collectSimpleControlFlowAggregateReturnPointerFields": 0,
        "fn trackSimpleAggregateReturn": 0,
        "fn derefUsesRaceTolerantLowering(": 1,
        "self.derefUsesRaceTolerantLowering(": 2,
        "fn pointerExprHasProvenLocalStorage(": 1,
        "fn qualifiedUnionConstructorType(": 0,
        "fn enumVariantPathType(": 0,
        "bitcastCallReturnType(call)": 0,
        "const source_ty = self.exprType(call.args[0]) orelse return error.UnsupportedLlvmEmission;": 0,
        "return call.type_args[0];": 0,
        "return simpleType(call.callee.*.span, \"PAddr\");": 0,
        "atomicCallMemberOp(call.callee.*)": 0,
        "maybeUninitCallMemberOp(call.callee.*)": 0,
        "reduceCallKind(call.callee.*)": 0,
        "mir.reflectionCallTargetKind(call)": 2,
        "mir.byteViewCallTargetKind(call)": 2,
        "mirCallTargetKindAt(call.callee.*.span) != .declassify": 1,
        "mirCallTargetKindAt(call.callee.*.span) == .declassify": 1,
        "mirCallTargetKindAt(call.callee.*.span) != .assume_noalias": 1,
        "mirCallTargetKindAt(call.callee.*.span) == .assume_noalias": 1,
    },
    "tests/spec/no_implicit_conversion.mc": {
        "EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE": 9,
    },
    "tests/spec/initialization.mc": {
        "EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE": 1,
    },
    "tests/spec/global_initializers.mc": {
        "EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE": 1,
    },
    "tests/spec/return_types.mc": {
        "EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE": 1,
    },
}


def duplicate_exact_count_files() -> list[str]:
    """Detect duplicate top-level file keys before Python dict parsing hides them."""
    source = Path(__file__).read_text(encoding="utf-8")
    tree = ast.parse(source)
    for node in tree.body:
        if not isinstance(node, ast.AnnAssign):
            continue
        if not isinstance(node.target, ast.Name) or node.target.id != "EXACT_COUNTS":
            continue
        if node.value is None:
            return []
        if not isinstance(node.value, ast.Dict):
            return []
        seen: set[str] = set()
        duplicates: list[str] = []
        for key in node.value.keys:
            if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
                continue
            if key.value in seen and key.value not in duplicates:
                duplicates.append(key.value)
            seen.add(key.value)
        return duplicates
    return []


def main() -> int:
    missing: list[str] = []
    checked = 0

    for duplicate in duplicate_exact_count_files():
        missing.append(f"EXACT_COUNTS: duplicate top-level file key {duplicate!r}")
        checked += 1

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

    for family, files in sorted(SEMANTIC_INFERENCE_FAMILIES.items()):
        for relative, anchors in sorted(files.items()):
            path = REPO_ROOT / relative
            try:
                text = path.read_text(encoding="utf-8")
            except FileNotFoundError:
                missing.append(f"{family}: {relative}: file missing")
                continue

            for anchor in anchors:
                checked += 1
                if anchor not in text:
                    missing.append(f"{family}: {relative}: missing anchor {anchor!r}")

    budget_families = BACKEND_AST_INFERENCE_BUDGET["families"]
    assert isinstance(budget_families, list)
    checked += 1
    if len(budget_families) != 8:
        missing.append(f"backend AST-inference budget: expected 8 registered families, found {len(budget_families)}")
    for family in budget_families:
        checked += 1
        if family not in SEMANTIC_INFERENCE_FAMILIES:
            missing.append(f"backend AST-inference budget: unknown family {family!r}")

    budget_docs = BACKEND_AST_INFERENCE_BUDGET["docs/typed-semantic-facts.md"]
    assert isinstance(budget_docs, list)
    budget_doc_path = REPO_ROOT / "docs/typed-semantic-facts.md"
    try:
        budget_doc = budget_doc_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        missing.append("backend AST-inference budget: docs/typed-semantic-facts.md file missing")
    else:
        for anchor in budget_docs:
            checked += 1
            if anchor not in budget_doc:
                missing.append(f"backend AST-inference budget: docs/typed-semantic-facts.md missing anchor {anchor!r}")

    for relative, anchors in sorted(SCALAR_DEREF_DEFAULT_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"scalar deref default audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"scalar deref default audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(ESCAPED_POINTER_BOUNDARY_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"escaped pointer boundary audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"escaped pointer boundary audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(RETURNED_POINTER_FACTS_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"returned pointer facts audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"returned pointer facts audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(AGGREGATE_RETURN_CFG_DECISION_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"aggregate-return CFG decision audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"aggregate-return CFG decision audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(BOUNDS_RANGE_FACT_FAMILY_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"bounds/range fact family audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"bounds/range fact family audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(INTEGER_DEFAULT_FACT_FAMILY_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"integer/default fact family audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"integer/default fact family audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(REPRESENTATION_FACT_HARDENING_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"representation fact hardening audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"representation fact hardening audit: {relative}: missing anchor {anchor!r}")

    if missing:
        print("semantic facts inventory anchor check failed:", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"semantic facts inventory anchors OK ({checked} anchors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
