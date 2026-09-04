#!/usr/bin/env python3
"""Verify anchors for the typed semantic facts Phase 1 inventory.

This script is intentionally read-only and stdlib-only. It checks for stable
function/type/output anchors used by docs/typed-semantic-facts.md so inventory
drift fails closed instead of silently leaving stale evidence in the docs.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

SEMANTIC_INFERENCE_FAMILIES: dict[str, dict[str, list[str]]] = {
    "c-expression-type-inference": {
        "docs/typed-semantic-facts.md": ["| `c-expression-type-inference` |"],
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
        "src/lower_c_reflect.zig": [
            "pub fn emitReflectionCall",
            ".reflection_size",
            ".reflection_repr",
        ],
        "src/lower_c_memory.zig": [
            "pub fn emitByteViewCall",
            ".byte_view_as_bytes",
            ".byte_view_equal",
            "mir.dmaCallFactInfo(kind)",
        ],
        "src/lower_c_mmio.zig": [
            "pub fn emitMmioMapCall",
            ".mmio_map",
            "ctx.mir_target_type(ctx.emit_ctx, .mmio_map_payload",
            "ctx.mir_call_target_kind(ctx.emit_ctx, callee.span) != expected",
            "ctx.mir_target_type(ctx.emit_ctx, .mmio_struct",
            "ctx.mir_target_type(ctx.emit_ctx, .mmio_storage",
            "ctx.mir_target_type(ctx.emit_ctx, .mmio_value",
            "ctx.mir_target_type(ctx.emit_ctx, .mmio_result",
        ],
        "src/lower_c_convert.zig": [
            "mir.conversionCallTargetKindForName(op)",
            "ctx.mir_call_target_kind(ctx.emit_ctx, call.callee.*.span) != expected_target",
        ],
        "src/lower_c_try.zig": [
            "ctx.call_ctx.mir_call_target_kind(ctx.call_ctx.emit_ctx, expr.span)",
        ],
        "src/lower_c_collect.zig": [],
    },
    "c-bounds-range-consumption": {
        "docs/typed-semantic-facts.md": ["| `c-bounds-range-consumption` |"],
    },
    "c-pointer-provenance-consumption": {
        "docs/typed-semantic-facts.md": ["| `c-pointer-provenance-consumption` |"],
    },
    "c-direct-global-race-helpers": {
        "docs/typed-semantic-facts.md": ["| `c-direct-global-race-helpers` |"],
        "src/lower_c_global.zig": [
            "pub fn appendGlobalLoadExpr(",
            "pub fn appendGlobalStorePrefix(",
            "pub fn globalAssignmentTarget(",
        ],
    },
    "llvm-representation-fact-consumption": {
        "docs/typed-semantic-facts.md": ["| `llvm-representation-fact-consumption` |"],
        "src/mir.zig": ["pub fn validateRepresentationFactsForLowering"],
        "src/verified_program.zig": ["try mir.validateLoweringAdmission(typed_mir.*)"],
        "src/lower_llvm.zig": ["VerifiedProgram.init(module_mir"],
    },
    "mir-pointer-provenance-producers": {
        "docs/typed-semantic-facts.md": ["| `mir-pointer-provenance-producers` |"],
        "src/mir.zig": [
            "fn recordPointerProvenanceForLocalInitializer",
            "fn appendPointerFieldProvenanceFact",
            "fn recordPointerProvenanceAddressEscape",
        ],
    },
    "mir-aggregate-return-producers": {
        "docs/typed-semantic-facts.md": ["| `mir-aggregate-return-producers` |"],
        "src/mir.zig": [
            "fn appendAggregateReturnPointerFact",
            "fn collectSequentialSwitchAggregateReturnLiteralPathsFrom",
            "max_aggregate_return_literal_paths",
        ],
    },
    "mir-bounds-range-producers": {
        "docs/typed-semantic-facts.md": ["| `mir-bounds-range-producers` |"],
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
        "Current backend AST-inference budget: **5 registered families**.",
        "| `c-expression-type-inference` | Backend AST inference budget |",
        "| `c-type-shape-classification` | Backend AST inference budget |",
        "| `c-abi-aggregate-lowering` | Backend AST inference budget |",
        "| `c-direct-global-race-helpers` | Backend AST inference budget |",
        "| `c-pointer-provenance-consumption` | Backend AST inference budget |",
    ],
    "families": [
        "c-expression-type-inference",
        "c-type-shape-classification",
        "c-abi-aggregate-lowering",
        "c-direct-global-race-helpers",
        "c-pointer-provenance-consumption",
    ],
}

# T3 is a disposition gate, not a claim that every backend query disappeared.
# Every family in the finite backend budget must have one explicit terminal
# policy. A family may later migrate to MIR, but it may not regress to an
# unclassified cleanup item in the meantime.
BACKEND_AST_INFERENCE_DISPOSITIONS: dict[str, str] = {
    "c-expression-type-inference": "conservative-or-diagnosed",
    "c-type-shape-classification": "accepted-target-policy",
    "c-abi-aggregate-lowering": "diagnosed-unsupported",
    "c-direct-global-race-helpers": "accepted-target-policy",
    "c-pointer-provenance-consumption": "conservative-fallback",
}

RETIRED_LOWER_C_INFER_PATH = "src/lower_c_infer.zig"

T3_DISPOSITION_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### T3 final backend inference dispositions",
        "| `c-expression-type-inference` | `conservative-or-diagnosed` |",
        "| `c-type-shape-classification` | `accepted-target-policy` |",
        "| `c-abi-aggregate-lowering` | `diagnosed-unsupported` |",
        "| `c-direct-global-race-helpers` | `accepted-target-policy` |",
        "| `c-pointer-provenance-consumption` | `conservative-fallback` |",
    ],
}

# T4 file-surface audit. This is intentionally an exact inventory of non-test
# backend modules (tests are excluded). Adding a backend module must classify it
# in the same patch; overlapping semantic decisions within a registered module
# remain governed by the seven-family budget and the detailed anchors above.
T4_BACKEND_FILE_AUTHORITY: dict[str, list[str]] = {
    "registered-semantic-family": [
        "src/ast_query.zig",
        "src/lower_c_aggregate.zig",
        "src/lower_c_emitter.zig",
        "src/lower_c_expr.zig",
        "src/lower_c_global.zig",
        "src/lower_c_info.zig",
        "src/lower_c_layout.zig",
        "src/lower_c_shape.zig",
        "src/lower_c_target.zig",
        "src/lower_c_type.zig",
    ],
    "mir-fact-consumer": [
        "src/lower_c.zig",
        "src/lower_c_access.zig",
        "src/lower_c_arith.zig",
        "src/lower_c_atomic.zig",
        "src/lower_c_builtin_emit.zig",
        "src/lower_c_call.zig",
        "src/lower_c_collect.zig",
        "src/lower_c_convert.zig",
        "src/lower_c_domain.zig",
        "src/lower_c_memory.zig",
        "src/lower_c_mmio.zig",
        "src/lower_c_reflect.zig",
        "src/lower_c_special.zig",
        "src/lower_c_switch.zig",
        "src/lower_c_try.zig",
        "src/lower_llvm_atomic.zig",
        "src/lower_llvm_reflect.zig",
    ],
    "mechanics-only": [
        "src/lower_c_asm.zig",
        "src/lower_c_const.zig",
        "src/lower_c_defs.zig",
        "src/lower_c_dispatch.zig",
        "src/lower_c_flow.zig",
        "src/lower_c_inspect.zig",
        "src/lower_c_map.zig",
        "src/lower_c_model.zig",
        "src/lower_c_names.zig",
        "src/lower_c_op.zig",
        "src/lower_c_overlay.zig",
        "src/lower_c_runtime.zig",
        "src/lower_llvm_model.zig",
        "src/lower_llvm.zig",
        "src/lower_llvm_lookup.zig",
        "src/lower_llvm_op.zig",
        "src/lower_llvm_prelude.zig",
        "src/lower_llvm_query.zig",
        "src/lower_llvm_shape.zig",
        "src/lower_llvm_text.zig",
        "src/lower_llvm_type.zig",
    ],
}

T4_AUTHORITY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### T4 backend semantic-authority audit",
        "| Registered semantic family |",
        "| MIR/fact consumer |",
        "| Mechanics-only |",
    ],
}

P4_PROVENANCE_POLICY_PARITY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### P4 C/LLVM provenance policy parity",
        "| Unknown scalar dereference |",
        "| Escaped pointer |",
        "| Higher-order/exported return |",
        "| Aggregate return outside bounded CFG |",
        "| Unsupported scalar/aggregate leaf |",
    ],
    "src/lower_c_tests.zig": [
        "lower-c aggregate-return nested call control fails closed",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM escaped pointer provenance lowers conservatively",
        "LLVM aggregate-return nested call control fails closed",
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
}

ESCAPED_POINTER_BOUNDARY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "### Escaped pointer boundary audit",
        "| Direct pointer argument escape |",
        "| Aggregate address escape |",
        "| Function-pointer callback escape |",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM escaped pointer provenance lowers conservatively",
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
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM aggregate-return nested call control fails closed",
        "LLVM aggregate-return path overflow switches fail closed",
        "LLVM aggregate-return mixed pointer-mutating while prefix fails closed",
        "LLVM aggregate-return dereference writes fail closed",
    ],
}

EXTERN_AGGREGATE_ABI_BOUNDARY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "| `c-abi-aggregate-lowering` |",
        "Explicit `extern \"C\"` declarations and unmarked exports reject every currently unclassified by-value family",
    ],
    "src/sema.zig": [
        "fn checkExternExportStructAbi(",
        "E_EXTERN_STRUCT_BY_VALUE",
        "fn externAbiTypeNeedsClassification(",
    ],
    "src/sema_tests.zig": [
        "test \"explicit C ABI rejects unclassified values and MC ABI permits them\"",
        "countDiagnosticCode(&reporter, \"E_EXTERN_STRUCT_BY_VALUE\")",
    ],
    "tests/c_emit/bad/extern_struct_param_by_value.mc": ["E_EXTERN_STRUCT_BY_VALUE"],
    "tests/c_emit/bad/extern_struct_return_by_value.mc": ["E_EXTERN_STRUCT_BY_VALUE"],
    "tests/c_emit/bad/export_struct_param_by_value.mc": ["E_EXTERN_STRUCT_BY_VALUE"],
    "tests/c_emit/bad/export_struct_return_by_value.mc": ["E_EXTERN_STRUCT_BY_VALUE"],
    "tests/c_emit/bad/export_generic_struct_by_value.mc": ["E_EXTERN_STRUCT_BY_VALUE"],
    "tests/c_emit/bad/extern_array_by_value.mc": ["E_EXTERN_STRUCT_BY_VALUE"],
    "tests/c_emit/bad/extern_optional_by_value.mc": ["E_EXTERN_STRUCT_BY_VALUE"],
}

C_AGGREGATE_GLOBAL_REPRESENTATION_POLICY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "C aggregate-global representation is an accepted internal target policy",
    ],
    "src/lower_c_info.zig": [
        "pub const AggregateGlobalCShape = enum",
        "pub fn aggregateGlobalCShape(",
        "pub fn isAggregateGlobalType(",
    ],
    "src/lower_c_tests.zig": [
        'test "lower-c materialized aggregate globals use the C aggregate representation policy"',
    ],
}

STRUCT_LITERAL_CONSTRUCTION_FACT_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "source struct literals carry a MIR-owned construction class",
    ],
    "src/mir_model.zig": [
        "pub const AggregateConstructionKind = enum",
        "aggregate_construction: ?AggregateConstructionKind = null",
    ],
    "src/mir.zig": [
        "fn structLiteralConstructionKind(",
        "aggregate_construction={s}",
    ],
    "src/mir_tests.zig": [
        "aggregate_construction=declared_struct",
        "aggregate_construction=packed_bits",
        "aggregate_construction=c_union",
    ],
    "src/lower_c_tests.zig": [
        'test "lower-c struct literal construction class is MIR-owned"',
    ],
    "src/lower_llvm_tests.zig": [
        'test "LLVM struct literal construction class is MIR-owned"',
    ],
}

BOUNDS_RANGE_FACT_FAMILY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "| MIR no-overflow range facts |",
        "| MIR bounds facts |",
        "| MIR check-elision source points |",
        "| `c-bounds-range-consumption` |",
    ],
    "src/mir_model.zig": [
        "pub const RangeFact = struct",
        "pub const BoundsFact = struct",
        "bounds_facts: []BoundsFact",
        "range_facts: []RangeFact",
        "elided_bounds: []SpanId",
    ],
    "src/mir.zig": [
        '"mir range_fact',
        '"mir bounds_fact',
        '"mir elided_bounds_fact',
        "try self.bounds_facts.append",
        "fn addRangeFactForUncheckedCall",
        "fn addAggregateRangeFactForUncheckedExpr",
        "pub fn validateRangeFactsForLowering",
    ],
    "src/mir_tests.zig": [
        "MIR dump emits non-elided bounds facts",
        "MIR dump exposes elided bounds facts",
        "MIR records no_overflow range facts for unchecked add contract",
    ],
    "src/lower_c_tests.zig": [
        "lower-c unchecked arithmetic requires MIR no-overflow range fact",
        "appendCheckedCTestWithRetargetedRangeFacts",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM unchecked arithmetic requires MIR no-overflow range fact",
        "appendLlvmTestWithRetargetedRangeFacts",
    ],
}

INTEGER_DEFAULT_FACT_FAMILY_AUDIT: dict[str, list[str]] = {
    "docs/typed-semantic-facts.md": [
        "| MIR integer literal facts |",
        "target-typed integer literal conversion",
        "validateLoweringAdmission",
    ],
    "src/mir_model.zig": [
        "integer_literal_conversion",
        "pub const IntegerFact = struct",
        "pub const ConstGetFact = struct",
        "pub const TargetTypeFact = struct",
        "integer_facts: []IntegerFact",
        "const_get_facts: []ConstGetFact",
        "target_type_facts: []TargetTypeFact",
    ],
    "src/mir.zig": [
        '"mir integer_fact',
        '"mir const_get_fact',
        '"mir target_type_fact',
        "fn addIntegerLiteralFact(",
        "pub fn validateIntegerFactsForLowering(",
        "fn targetTypeFactTypedIdentitiesValid(",
        "pub fn integerFactTargetType(",
        "fn integerFactTypedIdentitiesValid(",
        "fn integerFactLiteralText(",
    ],
    "src/mir_tests.zig": [
        "MIR dump emits target-typed integer literal facts",
        "mir integer_fact fn=integer_literals literal=255 target_type=u8 target_type_id=",
        "MIR target-type admission rejects target fact identity table drift",
    ],
    "src/lower_c.zig": [
        "VerifiedProgram.init(typed_mir",
    ],
    "src/verified_program.zig": [
        "try mir.validateLoweringAdmission(typed_mir.*)",
    ],
    "src/lower_llvm.zig": [
        "VerifiedProgram.init(module_mir",
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
        "VerifiedProgram.init(typed_mir",
    ],
    "src/verified_program.zig": [
        "try mir.validateLoweringAdmission(typed_mir.*)",
    ],
    "src/lower_llvm.zig": [
        "VerifiedProgram.init(module_mir",
    ],
    "src/lower_c_tests.zig": [
        "lower-c rejects prebuilt MIR with missing representation facts",
        "lower-c rejects prebuilt MIR with stale representation facts",
        "lower-c rejects prebuilt MIR with extra stale representation facts",
        "lower-c rejects prebuilt MIR with missing Result try payload representation facts",
        "lower-c rejects prebuilt MIR with stale Result try payload representation facts",
        "fn appendStaleRepresentationFactForFunction",
    ],
    "src/lower_llvm_tests.zig": [
        "LLVM rejects prebuilt MIR with missing representation facts",
        "LLVM rejects prebuilt MIR with stale representation facts",
        "LLVM rejects prebuilt MIR with extra stale representation facts",
        "LLVM rejects prebuilt MIR with missing Result try payload representation facts",
        "LLVM rejects prebuilt MIR with stale Result try payload representation facts",
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
        "Target-typed `atomic.init(value)` now carries an exact MIR-owned call identity",
        "MIR switch subject type facts",
        "MIR `if let` subject type facts",
    ],
    "src/ir_inspection.zig": [
        "pub fn appendLowerIr",
        "pub fn appendFacts",
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
        'std.mem.eql(u8, command, "inspect-ir")',
        'std.mem.eql(u8, command, "lower-mir")',
    ],
    "src/driver_inspect.zig": [
        "try ir.appendFactsFromResolvedSources",
        "try ir.appendLowerIrFromResolvedSources",
    ],
    "src/driver_check.zig": [
        "try session.buildVerifiedProgramFromResolvedDecls(resolved.decls, &diag, optimize, &module_mir, error.LowerMirFailed)",
        "try mir.appendDumpFromMir",
    ],
    "src/numeric.zig": [
        "pub fn parseIntegerLiteral(raw",
        "if (index == digit_start or index + 1 == digit_end or previous_separator) return null;",
        "magnitude = std.math.mul(u128, magnitude, radix) catch return null;",
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
        "typed_value_id: ?ValueId = null",
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
        "atomic_init_payload,",
        "atomic_init_result,",
        "range_facts: []RangeFact",
        "bounds_facts: []BoundsFact",
        "integer_facts: []IntegerFact",
        "pointer_provenance_facts: []PointerProvenanceFact",
        "representation_facts: []RepresentationFact",
        "elided_bounds: []SpanId",
    ],
    "src/mir.zig": [
        "pub fn appendDumpOpt",
        "pub fn appendDumpFromMir",
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
        "fn atomicInitCallTarget(",
        "appendOwnedTargetTypeFact(.atomic_init_payload",
        "appendOwnedTargetTypeFact(.atomic_init_result",
        "pub fn validateIntegerFactsForLowering",
        "pub fn validateConstGetFactsForLowering",
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
        "reject_bind_initializer",
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
    "src/lower_c_domain.zig": [
        "mir.domainCallFactInfo(kind)",
        "ctx.mir_target_type(ctx.emit_ctx, .domain_result",
        "ctx.mir_target_type(ctx.emit_ctx, .domain_interval",
    ],
    "src/lower_c_builtin_emit.zig": [
        "lower_c_arith.uncheckedCallInfo(ctx.arith, node)",
        "return error.UnsupportedCEmission",
    ],
    "src/lower_c.zig": [
        "VerifiedProgram.init(typed_mir",
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
        "VerifiedProgram.init(module_mir",
        "fn emitExecutableMirFunction(self: *LlvmEmitter, fact: mir.CallableEmissionFact",
        "mir_executable_llvm.renderWithCallAbiAndOptions",
    ],
}

EXACT_COUNTS: dict[str, dict[str, int]] = {
    "src/backend.zig": {
        '@import("ast.zig")': 0,
        'const mir = @import("mir.zig")': 0,
        'const artifact_model = @import("artifact_model.zig")': 0,
        'const diagnostics = @import("diagnostics.zig")': 0,
        'const legacy_backend_syntax = @import("legacy_backend_syntax.zig")': 0,
        'const codegen_request = @import("codegen_request.zig")': 1,
        "pub const Profile = codegen_options.Profile": 1,
        "pub const Checks = codegen_options.Checks": 1,
        "pub const TargetArch = codegen_options.TargetArch": 1,
        "pub const LowerOptions = codegen_options.LowerOptions": 1,
        "pub const targetArchFromName = codegen_options.targetArchFromName": 1,
        "pub const Profile = enum": 0,
        "pub const Checks = struct": 0,
        "pub const TargetArch = enum": 0,
        "pub const LowerOptions = struct": 0,
        "pub const LowerError = lower_error.LowerError": 1,
        "pub const lowerErrorFromAny = lower_error.lowerErrorFromAny": 1,
        "pub const LowerRequest = codegen_request.LowerRequest": 1,
        "pub const EmitMapRequest = codegen_request.EmitMapRequest": 1,
        "pub const LowerError = std.mem.Allocator.Error || error": 0,
        "pub fn lowerErrorFromAny": 0,
        "pub const SourceSpellingView = verified_program.SourceSpellingView": 0,
        "pub const RuntimeHookFacts = verified_program.RuntimeHookFacts": 1,
        "pub const trap_hook_names = verified_program.trap_hook_names": 1,
        "pub const sanitizer_hook_names = verified_program.sanitizer_hook_names": 1,
        "pub const VerifiedProgram = verified_program.VerifiedProgram": 1,
        "pub const SourceSpellingView = struct": 0,
        "pub const VerifiedProgram = struct": 0,
        "pub const LegacyDeclarationSlice = legacy_backend_syntax.LegacyDeclarationSlice": 0,
        "pub const SourceMapRowsView = legacy_backend_syntax.SourceMapRowsView": 0,
        "pub const LegacyDeclarationSlice = struct": 0,
        "pub const SourceMapRows = struct": 0,
        "syntax_module: ast.Module": 0,
        "decls: []const ast.Decl": 0,
        "declaration_metadata: LegacyDeclarationSlice": 0,
        "source_map_rows: SourceMapRowsView": 0,
        "source_map: SourceMapRowsView": 0,
        "source_map_rows: source_map_rows.SourceMapRows": 0,
        "source_map: legacy_backend_syntax.SourceMapRowsView": 0,
        "request: LowerRequest": 2,
        "request: EmitMapRequest": 2,
        "pub fn init(\n        syntax_module: ast.Module": 0,
        "pub fn initFromDecls(": 0,
        "pub fn init(\n        typed_mir: *const mir.Module": 0,
        ".decls = self.syntax_module.decls": 0,
        ".decls = self.decls": 0,
        ".decls = syntax_module.decls": 0,
        ".decls = decls": 0,
        ".declaration_metadata = LegacyDeclarationSlice.forDecls(decls)": 0,
        ".source_map_rows = SourceMapRowsView.forDecls(decls)": 0,
        "pub fn declarationMetadata(self: VerifiedProgram) LegacyDeclarationSlice": 0,
        "return self.declaration_metadata;": 0,
        "pub fn syntaxForLegacyDeclarationMetadata(self: VerifiedProgram) ast.Module": 0,
        "pub fn syntaxForSourceMapMechanics(self: VerifiedProgram) ast.Module": 0,
        "pub fn sourceMapMechanics(self: VerifiedProgram) SourceMapRowsView": 0,
        "return self.source_map_rows;": 0,
    },
    "src/codegen_request.zig": {
        '@import("early_declaration_metadata.zig")': 0,
        '@import("declaration_artifacts.zig")': 1,
        '@import("source_map_rows.zig")': 0,
        "early_declaration_metadata: early_declaration_metadata.EarlyDeclarationMetadataView": 0,
        "early_declaration_metadata: early_declaration_metadata.EarlyDeclarationArtifacts": 0,
        "declaration_artifacts: declaration_artifacts.EarlyDeclarationArtifacts": 0,
        "declaration_artifacts: declaration_artifacts.CodegenDeclarationArtifacts": 0,
        "declaration_artifacts: CgDeclArtifacts": 0,
        "function_bodies: CodegenFunctionBodyArtifacts": 0,
        "source_map_rows: source_map_rows.SourceMapRows": 0,
        "source_map_artifacts: []const declaration_artifacts.SourceMapArtifact": 0,
        "source_map_artifacts: []const SourceMapArtifact": 1,
        "source_map_rows: source_map_rows.SourceMapRowsView": 0,
    },
    "src/main.zig": {
        '@import("early_declaration_metadata.zig")': 0,
        '@import("declaration_artifacts.zig")': 0,
        '@import("driver_codegen_inputs.zig")': 0,
        "early_declaration_metadata.EarlyDeclarationArtifacts.collectFromDecls": 0,
        "declaration_artifacts.EarlyDeclarationArtifacts.collectFromDecls": 0,
        "driver_codegen_inputs.DeclarationArtifacts": 0,
        "fn buildDriverBackendInputs(": 0,
        "fn buildDriverCArtifactInputs(": 0,
        "try driver_codegen_inputs.buildBackendInputs(": 0,
        "try driver_codegen_inputs.buildCArtifactInputs(": 0,
    },
    "src/driver_codegen.zig": {
        '@import("driver_codegen_inputs.zig")': 1,
        "driver_codegen_inputs.DeclarationArtifacts": 5,
        "try driver_codegen_inputs.buildBackendInputs(": 3,
        "try driver_codegen_inputs.buildCArtifactInputs(": 2,
    },
    "src/codegen_options.zig": {
        'const artifact_model = @import("artifact_model.zig")': 1,
        'const diagnostics = @import("diagnostics.zig")': 1,
        "pub const Profile = enum": 1,
        "pub const Checks = struct": 1,
        "pub const TargetArch = enum": 1,
        "pub const LowerOptions = struct": 1,
        "pub fn targetArchFromName": 1,
        "source_sha256: ?artifact_model.Sha256Digest = null": 1,
    },
    "src/lower_error.zig": {
        "pub const LowerError = std.mem.Allocator.Error || error": 1,
        "pub fn lowerErrorFromAny": 1,
        "InternalLoweringFailure": 3,
        "test \"lowering errors are mapped to the domain error set\"": 1,
    },
    "src/verified_program.zig": {
        "pub const SourceSpellingView = struct": 0,
        "pub const RuntimeHookFacts = struct": 1,
        "pub const VerifiedProgram = struct": 1,
        "runtime_hooks: RuntimeHookFacts": 1,
        "RuntimeHookFacts.fromMir(typed_mir.*)": 1,
        "pub fn init(\n        typed_mir: *const mir.Module": 1,
        "pub fn initFromDecls(": 0,
        "pub fn functionSpelling(self: SourceSpellingView": 0,
        "pub fn definesFunctionSpelling(self: SourceSpellingView": 0,
        "VerifiedProgram exposes narrow runtime hook facts": 1,
    },
    "src/declaration_artifacts.zig": {
        '@import("ast.zig")': 1,
        '@import("early_declaration_metadata.zig")': 0,
        "pub const SyntaxDeclarationSlice = []const ast.Decl": 0,
        "pub const EarlyDeclarationMetadataView = struct": 0,
        "pub const EarlyDeclarationArtifacts = struct": 1,
        "pub const CodegenDeclarationArtifacts = struct": 0,
        "pub fn codegen(self: EarlyDeclarationArtifacts) CodegenDeclarationArtifacts": 0,
        "decls: []const ast.Decl": 0,
        "pub fn collectFromSyntaxDecls(": 0,
        "fn collectFromSyntaxDecls(allocator: std.mem.Allocator, syntax_items: []const ast.Decl) !EarlyDeclarationArtifacts": 0,
        "pub fn collectFromResolvedDecls(": 1,
        "pub fn collectFromModuleDeclsForTests(": 0,
        "[]const module_parser.ResolvedDecl": 1,
        "pub fn collectFromDecls(allocator: std.mem.Allocator, decls: []const ast.Decl) !EarlyDeclarationArtifacts": 0,
        "pub const SourceMapArtifact = union(enum)": 1,
        "pub const CallableValueArtifact = union(enum)": 0,
        "pub const FunctionArtifact = struct": 0,
        "fn_decl: ast.FnDecl": 0,
        "    fn_decl: ast.FnDecl,": 0,
        "abi: ?[]const u8": 0,
        "params: []ast.Param": 0,
        "return_type: ?ast.TypeExpr": 0,
        "has_explicit_abi: bool": 0,
        "signature: codegen_attrs.FunctionSignatureFacts": 0,
        "body_facts: codegen_attrs.FunctionBodyFacts": 0,
        "pub fn fromDecl(fn_decl: ast.FnDecl, attrs: []const ast.Attr, is_extern: bool) FunctionArtifact": 0,
        "pub fn fromDecl(allocator: std.mem.Allocator, def_id: mir.DefId, fn_decl: ast.FnDecl, attrs: []const ast.Attr, is_extern: bool, function_mir: ?mir.Function) !FunctionArtifact": 0,
        "pub fn toDecl(self: FunctionArtifact) ast.FnDecl": 0,
        "pub fn comptimeFnDeclFromArtifact(function: FunctionArtifact) ast.FnDecl": 0,
        "function_artifacts: []const FunctionArtifact": 0,
        "decl_artifacts: []const DeclArtifact": 0,
        "decl_artifacts: []const GlobalArtifact": 0,
        "pub const DeclArtifact = union(enum)": 0,
        "pub const GlobalArtifact = struct": 0,
        "global: ast.GlobalDecl": 0,
        "global: ast.GlobalDecl,": 0,
        "name: ast.Ident": 1,
        "ty: ?ast.TypeExpr": 0,
        "init: ?ast.Expr": 0,
        "pub fn fromDecl(global: ast.GlobalDecl, checked: ?mir.CheckedGlobalFact) GlobalArtifact": 0,
        "pub fn toDecl(self: GlobalArtifact) ast.GlobalDecl": 0,
        "fn globalDeclFromArtifact(global: GlobalArtifact) ast.GlobalDecl": 0,
        "global_artifacts: []const ast.GlobalDecl": 0,
        "global_artifacts: []const GlobalArtifact": 0,
        "global.toDecl()": 0,
        "globalDeclFromArtifact(global)": 0,
        "try function_artifacts.append(allocator, .{ .fn_decl = fn_decl, .attrs = decl.attrs, .is_extern = false })": 0,
        "try function_artifacts.append(allocator, .{ .fn_decl = fn_decl, .attrs = decl.attrs, .is_extern = true })": 0,
        "try function_artifacts.append(allocator, FunctionArtifact.fromDecl(fn_decl, decl.attrs, false))": 0,
        "try function_artifacts.append(allocator, FunctionArtifact.fromDecl(fn_decl, decl.attrs, true))": 0,
        "try global_artifacts.append(allocator, global)": 0,
        "try global_artifacts.append(allocator, .{ .global = global })": 0,
        "try global_artifacts.append(allocator, GlobalArtifact.fromDecl(global))": 0,
        "try decl_artifacts.append(allocator, .{ .function = FunctionArtifact.fromDecl(fn_decl, decl.attrs, false) })": 0,
        "try decl_artifacts.append(allocator, .{ .function = FunctionArtifact.fromDecl(fn_decl, decl.attrs, true) })": 0,
        "const function = try FunctionArtifact.fromDecl(allocator, def_id, fn_decl, decl.attrs, false,": 0,
        "const function = try FunctionArtifact.fromDecl(allocator, def_id, fn_decl, decl.attrs, true,": 0,
        # Definitions must have checked plans; source-map rows are retained
        # independently and no AST global payload reaches codegen.
        "const checked = globalByName(typed_mir, global.name.text);": 0,
        "if (checked == null or typed_mir.checkedGlobalInitializer(checked.?) == null) {": 0,
        "try decl_artifacts.append(allocator, GlobalArtifact.fromDecl(global, checked));": 0,
        "callable_value_artifacts": 0,
        "pub const TraitArtifact = union(enum)": 0,
        "trait_artifacts: []const TraitArtifact": 0,
        "pub const TraitDeclArtifact = struct": 0,
        "pub const ImplTraitArtifact = struct": 0,
        "trait_decl_artifacts: []const TraitDeclArtifact": 0,
        "impl_trait_artifacts: []const ImplTraitArtifact": 0,
        "trait_decl: ast.TraitDecl": 0,
        "impl_trait: ast.ImplTrait": 0,
        "pub fn toDecl(self: TraitDeclArtifact) ast.TraitDecl": 0,
        "pub fn toDecl(self: ImplTraitArtifact) ast.ImplTrait": 0,
        "try trait_artifacts.append": 0,
        "try trait_decl_artifacts.append(allocator, TraitDeclArtifact.fromDecl(trait_decl))": 0,
        "try impl_trait_artifacts.append(allocator, ImplTraitArtifact.fromDecl(impl_trait))": 0,
        "try decl_artifacts.append(allocator, .{ .trait_decl = TraitDeclArtifact.fromDecl(trait_decl) })": 0,
        "try decl_artifacts.append(allocator, .{ .impl_trait = ImplTraitArtifact.fromDecl(impl_trait) })": 0,
        "try callable_value_artifacts.append(allocator, .{ .trait_decl = trait_decl })": 0,
        "try callable_value_artifacts.append(allocator, .{ .impl_trait = impl_trait })": 0,
        "pub const TypeArtifact = union(enum)": 0,
        "type_artifacts: []const TypeArtifact": 0,
        "type_alias_artifacts: []const ast.TypeAlias": 0,
        "struct_artifacts: []const ast.StructDecl": 0,
        "enum_artifacts: []const ast.EnumDecl": 0,
        "union_artifacts: []const ast.UnionDecl": 0,
        "packed_bits_artifacts: []const ast.PackedBitsDecl": 0,
        "overlay_union_artifacts: []const ast.OverlayUnionDecl": 0,
        "type_decl_artifacts: []const TypeDeclArtifact": 0,
        "pub const TypeDeclArtifact = union(enum)": 0,
        "pub const TransitionalTypeDeclArtifact = union(enum)": 0,
        "try type_artifacts.append": 0,
        "try type_alias_artifacts.append(allocator, alias)": 0,
        "try struct_artifacts.append(allocator, struct_decl)": 0,
        "try enum_artifacts.append(allocator, enum_decl)": 0,
        "try union_artifacts.append(allocator, union_decl)": 0,
        "try packed_bits_artifacts.append(allocator, packed_bits_decl)": 0,
        "try overlay_union_artifacts.append(allocator, overlay_union)": 0,
        "try type_decl_artifacts.append(allocator, .{ .type_alias = alias })": 0,
        "try type_decl_artifacts.append(allocator, .{ .struct_decl = struct_decl })": 0,
        "try type_decl_artifacts.append(allocator, .{ .enum_decl = enum_decl })": 0,
        "try type_decl_artifacts.append(allocator, .{ .union_decl = union_decl })": 0,
        "try type_decl_artifacts.append(allocator, .{ .packed_bits_decl = packed_bits_decl })": 0,
        "try type_decl_artifacts.append(allocator, .{ .overlay_union_decl = overlay_union })": 0,
        "try decl_artifacts.append(allocator, .{ .type_decl = .{ .type_alias = alias } })": 0,
        "try decl_artifacts.append(allocator, .{ .type_decl = .{ .struct_decl = struct_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .type_decl = .{ .enum_decl = enum_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .type_decl = .{ .union_decl = union_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .type_decl = .{ .packed_bits_decl = packed_bits_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .type_decl = .{ .overlay_union_decl = overlay_union } })": 0,
        "try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .type_alias = alias } })": 0,
        "try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .struct_decl = struct_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .enum_decl = enum_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .union_decl = union_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .packed_bits_decl = packed_bits_decl } })": 0,
        "try decl_artifacts.append(allocator, .{ .transitional_type_decl = .{ .overlay_union_decl = overlay_union } })": 0,
        "body: ast.Block": 0,
        "opaque_decl: ast.Ident": 0,
        ".opaque_decl => {},": 0,
    },
    "src/driver_codegen_inputs.zig": {
        '@import("ast.zig")': 0,
        '@import("declaration_artifacts.zig")': 1,
        "pub const DeclarationArtifacts = declaration_artifacts.EarlyDeclarationArtifacts": 1,
        "pub fn buildBackendInputs(": 1,
        "pub fn buildCArtifactInputs(": 1,
        "module: ast.Module": 0,
        "session.buildVerifiedProgram(module": 0,
        "session.buildVerifiedProgramFromDecls(decls": 0,
        "session.buildVerifiedProgramFromResolvedDecls(resolved_decls": 1,
        "session.buildMirFromResolvedDecls(resolved_decls": 1,
        "DeclarationArtifacts.collectFromDecls(session.allocator, module.decls)": 0,
        "DeclarationArtifacts.collectFromSyntaxDecls(session.allocator, module.decls)": 0,
        "DeclarationArtifacts.collectFromResolvedDecls(session.allocator, resolved_decls, module_mir)": 2,
        "DeclarationArtifacts.collectFromResolvedDecls(session.allocator, fallback_decls)": 0,
    },
    "src/lower_llvm_prelude.zig": {
        "fn moduleDefinesHook(source_spelling: backend.SourceSpellingView": 0,
        "source_spelling.functionSpelling(function)": 0,
        "source_spelling.definesFunctionSpelling(module_mir, hook)": 0,
        "pub fn emitTrapDecl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), runtime_hooks: backend.RuntimeHookFacts": 1,
        "pub fn emitExternalRuntimeDecls(allocator: std.mem.Allocator, out: *std.ArrayList(u8), runtime_hooks: backend.RuntimeHookFacts": 1,
        "runtime_hooks.definesTrapHook(index)": 2,
        "runtime_hooks.definesSanitizerHook(index)": 2,
    },
    "src/mir.zig": {
        '@import("module_parser.zig")': 1,
        "pub fn buildOptFromResolvedDecls(": 1,
        "fn buildOptFromDeclItems(": 1,
        "fn declFromBuildItem(": 1,
        "fn syntaxDeclsFromResolved(": 0,
        "appendTargetTypeFact(.assert_condition": 1,
        "appendTargetTypeFact(.loop_condition": 1,
        "appendTargetTypeFact(.switch_subject": 1,
        "appendTargetTypeFact(.if_let_subject": 1,
        "appendTargetTypeFact(.try_operand": 1,
        "appendTargetTypeFact(.for_iterable": 1,
        "appendTargetTypeFact(.for_element": 1,
        "appendOwnedTargetTypeFact(.direct_call_result": 1,
        ".direct_call_argument,": 1,
        "appendTargetTypeFact(.indirect_call_callee": 1,
        "fn indirectCallTarget(": 1,
        "fn appendOwnedTargetTypeFact(": 1,
        "fn addSelfTypedExpressionFact(": 1,
        "qualified_union_result": 1,
        "enum_variant_path_result": 1,
        "fn reflectionCallTarget(": 1,
        "appendTargetTypeFact(.reflection_target": 1,
        "appendTargetTypeFact(.reflection_result": 1,
        "fn byteViewCallTarget(": 1,
        "appendTargetTypeFact(.byte_view_source": 1,
        "appendTargetTypeFact(.byte_view_result": 1,
        "fn vaCallTarget(": 1,
        "fn vaCallFactInfo(": 0,
        "appendTargetTypeFact(.va_cursor": 1,
        "appendTargetTypeFact(.va_payload": 1,
        "appendTargetTypeFact(.va_result": 1,
        "addCallTargetFact(va.kind": 0,
        "fn discardCallTargetKind(": 1,
        "appendTargetTypeFact(.discard_argument": 1,
        "pub fn explicitTrapCallTargetKind(": 1,
        "pub fn explicitTrapHelperForTarget(": 1,
        "fn rawCallTarget(": 1,
        "fn rawLoadCallValueType(": 0,
        "fn rawPtrCallValueType(": 0,
        "fn rawStoreCallValueType(": 0,
        "appendTargetTypeFact(.raw_address": 1,
        "appendTargetTypeFact(.raw_payload": 1,
        "appendTargetTypeFact(.raw_result": 1,
        "try self.appendTargetTypeFact(.paddr_coercion_source": 2,
        "fn paddrCoercionSourceTypeExpr(": 1,
        "fn semanticEscapeSourceTypeExpr(": 1,
        "try self.appendTargetTypeFact(source_kind, target.source_type_expr": 1,
        "try self.appendTargetTypeFact(result_kind, target.result_type_expr": 1,
        "appendTargetTypeFact(.atomic_payload": 1,
        "fn atomicInitCallTarget(": 1,
        "appendOwnedTargetTypeFact(.atomic_init_payload": 1,
        "appendOwnedTargetTypeFact(.atomic_init_result": 1,
        "appendTargetTypeFact(.maybe_uninit_payload": 1,
        "appendTargetTypeFact(.reduce_source": 1,
        "appendTargetTypeFact(.reduce_element": 1,
        "fn enumRawCallTarget(": 1,
        "addCallTargetFact(.enum_raw": 1,
        "appendTargetTypeFact(.enum_raw_source": 1,
        "appendTargetTypeFact(.enum_raw_result": 1,
        "pub fn domainCallFactInfo(": 1,
        "pub const DeferCleanupRef": 1,
        "pub fn deferCleanupRefAtSource": 1,
        "pub fn deferCleanupRefValid": 1,
        "pub fn buildDeferCleanupEdgeTable": 1,
        "pub fn deferCleanupEdgeTableValid": 1,
        "pub fn deferCleanupEdgeTableContainsRef": 1,
        "pub fn buildOwnershipCleanupEdgeTable": 1,
        "pub fn ownershipCleanupEdgeTableValid": 1,
        "pub fn buildCleanupCfg(": 1,
        "pub fn buildCleanupCfgFromEdgeTables": 1,
        "pub fn cleanupCfgValid": 1,
        "pub fn dmaCallFactInfo(": 1,
        "fn domainCallTarget(": 1,
        "fn dmaCallTarget(": 1,
        "fn rawManyOffsetCallTarget(": 1,
        "fn mmioCallTarget(": 1,
        "fn mmioMapCallTarget(": 1,
        "try self.addCallTargetFact(target.kind": 11,
        "fn conversionCallResultValueType(": 1,
        "try self.addCallTargetFact(conversion.kind, conversion_result_ty": 1,
        "try self.addCallTargetFact(target, .never": 1,
        "const assignment_target_ty = self.typeForAssignmentTarget(node.target);": 0,
        "fn instructionRequiresKnownLoweringType(": 1,
        "instructionRequiresKnownLoweringType(instruction) and valueTypeIsUnknownPlaceholder": 1,
        "fn targetTypedCallResultValueType(": 1,
        "fn qualifiedUnionConstructorCallValueType(": 1,
        "appendTargetTypeFact(.domain_type": 1,
        "appendTargetTypeFact(.domain_payload": 1,
        "appendTargetTypeFact(.domain_result": 1,
        "appendTargetTypeFact(.domain_interval": 1,
        "fn constGetCallTarget(": 1,
        "fn addConstGetInstr(": 1,
        "try self.addCallTargetFact(.const_get, target.result_ty, expr.span);": 0,
        "try self.addCallTargetFact(.const_get, target.result_ty, node.callee.*.span);": 1,
        "appendTargetTypeFact(.const_get_base": 1,
        "appendTargetTypeFact(.const_get_result": 1,
        "appendTargetTypeFact(.dma_buffer": 1,
        "appendTargetTypeFact(.dma_payload": 1,
        "appendTargetTypeFact(.dma_result": 1,
        "try self.addCallTargetFact(target.kind, target.result_ty, expr.span);": 0,
        "try self.addCallTargetFact(target.kind, target.result_ty, node.callee.*.span);": 11,
        "addCallTargetFact(.raw_many_offset": 1,
        "appendTargetTypeFact(.raw_many_offset_base": 1,
        "appendTargetTypeFact(.raw_many_offset_element": 1,
        "appendTargetTypeFact(.raw_many_offset_result": 1,
        "appendTargetTypeFact(.mmio_map_source": 1,
        "appendTargetTypeFact(.mmio_map_payload": 1,
        "appendTargetTypeFact(.mmio_map_result": 1,
        "appendTargetTypeFact(.mmio_struct": 1,
        "appendTargetTypeFact(.mmio_storage": 1,
        "appendTargetTypeFact(.mmio_value": 1,
        "appendTargetTypeFact(.mmio_result": 1,
        "fn mmioRegisterStorageTypeExprAlias(": 1,
        "fn mmioReceiverReadTypeExpr(": 0,
        "const_get_facts.append": 1,
        "pub fn validateConstGetFactsForLowering(": 1,
        "fn countConstGetCallTargetsAtSource(": 1,
        "fn countConstGetInstructionsAtSource(": 1,
        "fn countTargetTypeInstructionsAtSource(": 1,
        '"mir const_get_fact': 1,
        "fn generatedGenericTypeExpr(": 1,
        "try self.addCallTargetFact(owned_kind, result_ty": 1,
        "try self.addCallTargetFact(fact_kind, call_ty, expr.span);": 0,
        "try self.addCallTargetFact(fact_kind, call_ty, node.callee.*.span);": 3,
        "try self.addCallTargetFact(.enum_raw, target.result_ty, expr.span);": 0,
        "try self.addCallTargetFact(.enum_raw, target.result_ty, node.callee.*.span);": 1,
        "try self.addCallTargetFact(conversion.kind, conversion_result_ty, expr.span);": 0,
        "try self.addCallTargetFact(conversion.kind, conversion_result_ty, node.callee.*.span);": 1,
        "try self.addCallTargetFact(target, .void, expr.span);": 0,
        "try self.addCallTargetFact(target, .void, node.callee.*.span);": 1,
        "try self.addCallTargetFact(target, .never, expr.span);": 1,
        "try self.addCallTargetFact(target, .never, node.callee.*.span);": 0,
        "try self.addCallTargetFact(.cpu_pause, cpu_pause_ty, expr.span);": 0,
        "try self.addCallTargetFact(.cpu_pause, cpu_pause_ty, node.callee.*.span);": 1,
        "try self.addCallTargetFact(fence_kind, .void, expr.span);": 0,
        "try self.addCallTargetFact(fence_kind, .void, node.callee.*.span);": 1,
        "pub fn resultConstructorFactInfo(": 1,
        ".result_ok => .{ .target_kind = .result_ok": 1,
        ".result_err => .{ .target_kind = .result_err": 1,
        "fn countMatchingCallTargetInstructionsForInstruction(": 1,
        "fn countMatchingCallTargetFactsForFact(": 1,
        "fn matchingCallTargetFactsAgreeForInstruction(": 1,
        ".bind => .bind,": 1,
    },
    "src/numeric.zig": {
        "pub fn parseIntegerLiteral(raw": 1,
        "magnitude = std.math.mul(u128, magnitude, radix) catch return null;": 1,
    },
    "src/eval.zig": {
        "pub fn runTrapExpectation(": 0,
        "pub fn runTrapExpectationFromDecls(": 1,
        "pub fn collectConstGlobalsWithOptions(": 0,
        "pub fn collectConstGlobalsFromDeclsWithOptions(": 1,
        "pub fn collectConstGlobalsFromDeclItemsWithOptions(": 1,
        "fn collectConstGlobalsFromDeclItemsWithScope(": 1,
        "for (module.decls) |decl|": 0,
        "module: ?ast.Module": 0,
        "decls: ?[]const ast.Decl": 1,
        "pub const ComptimeDeclarations = struct": 1,
        "declarations: ?ComptimeDeclarations = null": 1,
        "pub fn collectConstGlobalsFromDeclarationsWithOptions(": 1,
        "scope.module = module": 0,
        "scope.decls = decls": 0,
        "scope.declarations = declarations": 1,
        "scope.module orelse": 0,
        "scope.decls orelse": 0,
        "scope.declarations orelse": 3,
        "call_scope.module = scope.module": 0,
        "call_scope.decls = scope.decls": 0,
        "call_scope.declarations = scope.declarations": 1,
        "callee_scope.module = scope.module": 0,
        "callee_scope.decls = scope.decls": 0,
        "callee_scope.declarations = scope.declarations": 1,
        "return collectConstGlobalsFromDeclsWithOptions(allocator, module, module.decls": 0,
        "return collectConstGlobalsFromDeclsWithOptions(allocator, module.decls": 0,
    },
    "src/mir_source_bridge.zig": {
        "Transitional AST-span to MIR-source-point bridge.": 1,
        "pub fn sourcePointMatchesSpan(": 0,
        "pub fn sourcePointFromOptionalSpan(": 1,
        "pub fn isSourceSpan(": 1,
        "pub fn firstCallTargetKindAt(": 1,
        "pub fn uniqueCallTargetKindAt(": 1,
        "pub fn hasCallTargetKindAt(": 1,
        "pub const TargetTypeLookupKey = mir_facts_view.TargetTypeLookupKey": 1,
        "pub fn targetTypeFactById(": 1,
        "pub fn targetTypeFactAtWithModuleFallback(": 0,
        "pub fn targetTypeFactAtCurrentSpan(": 1,
        "pub fn targetTypeFactMatchingType(": 0,
        "pub fn atomicInitPayloadTypeAt(": 1,
        "pub fn targetTypeFactAtOwnedWithModuleFallback(": 0,
        "pub fn targetTypeFactAtOwnedCurrentSpan(": 1,
        "pub fn uniqueConstGetIndexAt(": 1,
        "pub fn pointerFactMatchesAt(": 1,
        "pub fn aggregatePointerFieldFactMatchesAt(": 1,
        "pub fn pointerFactIsCallInvalidationAt(": 1,
        "pub fn pointerFactMatchesSubjectFieldAt(": 1,
        "pub fn pointerFactIsLiveGlobal(": 1,
        "pub fn pointerFactIsLiveLocal(": 1,
        "pub fn pointerFactLiveState(": 1,
    },
    "src/syntax_bridge.zig": {
        "Transitional backend syntax-shape bridge.": 1,
        "pub fn deferExprForRefInBlock(": 0,
    },
    "src/mir_model.zig": {
        "mutability: ast.Mutability": 0,
    },
    "src/lower_c.zig": {
        "VerifiedProgram.init(typed_mir": 1,
        "program.syntax_module": 0,
        "program.syntaxForLegacyDeclarationMetadata()": 0,
        "program.declarationMetadata().syntaxForLegacyLowering()": 0,
        "program.declarationMetadata(),": 0,
        "LegacyDeclarationSlice.forLegacySyntax(module)": 0,
        "LegacyDeclarationSlice.forDecls(module.decls)": 0,
        "LegacyDeclarationSlice.forDecls(module.decls).earlyDeclarationMetadata()": 0,
        "EarlyDeclarationMetadataView.forDecls(module.decls)": 0,
        "EarlyDeclarationArtifacts.collectFromDecls(allocator, module.decls)": 0,
        'const declaration_artifacts = @import("declaration_artifacts.zig")': 0,
        "declarations.syntaxForLegacyLowering()": 0,
        "declarations.syntaxForCEarlyDeclarationMetadata()": 0,
        "declarations.syntaxForLlvmEarlyDeclarationMetadata()": 0,
        "declarations": 0,
        "early_metadata: legacy_backend_syntax.EarlyDeclarationMetadataView": 0,
        "early_metadata: early_declaration_metadata.EarlyDeclarationMetadataView": 0,
        "early_metadata: declaration_artifacts.EarlyDeclarationArtifacts": 0,
        "early_metadata.syntaxForEarlyDeclarationScan()": 0,
        "early_metadata.declsForEarlyDeclarationScan()": 0,
        "early_metadata.moduleForComptimeEvaluation()": 0,
        "program.syntaxForSourceMapMechanics()": 0,
        "program.sourceMapMechanics()": 0,
        "SourceMapRowsView.forLegacySyntax(module)": 0,
        "SourceMapRowsView.forDecls(module.decls)": 0,
        "SourceMapRows.collectFromDecls(allocator, module.decls)": 0,
        "SourceMapRows.collectFromArtifacts(allocator, early_metadata.decl_artifacts)": 0,
        "SourceMapRows.collectFromArtifacts(allocator, early_metadata.decl_artifacts, early_metadata.decl_origins)": 0,
        "SourceMapRows.collectFromSourceArtifacts(allocator, early_metadata.source_map_artifacts)": 0,
        "program.source_spelling": 0,
        "program.runtime_hooks": 1,
        "VerifiedProgram.init(module": 0,
        "VerifiedProgram.initFromDecls(module.decls": 0,
        "fn appendCProfileWithVerifiedProgram(": 1,
        "try lower_c_runtime.appendHeaderAndSanitizerHooks(allocator, program.source_spelling": 0,
        "try lower_c_runtime.appendHeaderAndSanitizerHooks(allocator, program.runtime_hooks": 1,
    },
    "src/lower_c_map.zig": {
        "try mapper.emitModule(module);": 0,
        "fn emitModule(self: *SourceMapEmitter, module: ast.Module) !void": 0,
        "try mapper.collectRowArtifacts(module);": 0,
        "try mapper.collectRowArtifactsFromDecls(decls);": 0,
        "try mapper.collectRowArtifacts(source_map.artifacts);": 0,
        "try mapper.collectRowArtifacts(source_map_artifacts);": 1,
        "try mapper.collectRowArtifacts(artifacts.source_map_artifacts);": 0,
        "try mapper.emitCollectedRows();": 1,
        "fn collectRowArtifacts(self: *SourceMapEmitter, module: ast.Module) !void": 0,
        "fn collectRowArtifactsFromDecls(self: *SourceMapEmitter, decls: []const ast.Decl) !void": 0,
        "fn collectRowArtifacts(self: *SourceMapEmitter, artifacts: []const source_map_rows.RowArtifact) !void": 0,
        "fn collectRowArtifacts(self: *SourceMapEmitter, artifacts: []const declaration_artifacts.SourceMapArtifact) !void": 1,
        "fn emitCollectedRows(self: *SourceMapEmitter) !void": 1,
        "fn emitFunctionMirRows(self: *SourceMapEmitter, symbol: []const u8) !void": 1,
        "fn sourceMapKindForMirInstruction(function: mir.Function, instruction: mir.Instruction) ?[]const u8": 1,
        "fn expressionResultSourceMapKind(function: mir.Function, instruction: mir.Instruction) []const u8": 1,
        "fn emitBlock(self: *SourceMapEmitter": 0,
        "fn emitStmt(self: *SourceMapEmitter": 0,
        "fn emitExprTree(self: *SourceMapEmitter": 0,
        "fn emitNestedExpr(self: *SourceMapEmitter": 0,
        "fn emitExprChildren(self: *SourceMapEmitter": 0,
        "try self.decl_row_artifacts.append(self.allocator, decl);": 0,
        "try self.decl_row_artifacts.append(self.allocator, artifact);": 1,
        "for (self.decl_row_artifacts.items) |decl|": 0,
        "for (self.decl_row_artifacts.items) |artifact|": 1,
        "source_map.syntaxForRowEnumeration()": 0,
        "source_map.declsForRowEnumeration()": 0,
    },
    "src/lower_c_runtime.zig": {
        "fn moduleDefinesHook(source_spelling: backend.SourceSpellingView": 0,
        "source_spelling.functionSpelling(function)": 0,
        "source_spelling.definesFunctionSpelling(module_mir, hook)": 0,
        "runtime_hooks.definesSanitizerHook(index)": 1,
        "pub fn appendHeaderAndSanitizerHooks(": 1,
    },
    "src/ast_query.zig": {
        "pub fn addressOfIdentName": 1,
        "test \"address-of local shape recognizes grouped identifiers only\"": 1,
        "pub fn dropPointerLocalReleaseCall": 1,
        "test \"drop pointer release call recognizes direct address locals only\"": 1,
        "pub fn dropPointerReleaseParamTypeName": 1,
        "test \"drop pointer release parameter accepts named and generic mut pointers only\"": 1,
    },
    "src/mir_ownership_authority.zig": {
        "pub const AutoDropLocalCleanup": 1,
        "pub const OwnershipCleanupActionRef": 1,
        "root_value_id: mir.ValueId = .invalid": 1,
        "resource_type_symbol_id: mir.SymbolId = .invalid": 1,
        "drop_glue_symbol_id: mir.SymbolId = .invalid": 1,
        "auto_drop_event_index: usize = std.math.maxInt(usize)": 1,
        "explicit_drop_event_index: usize = std.math.maxInt(usize)": 1,
        "storage_dead_event_index: usize = std.math.maxInt(usize)": 1,
        "pub fn autoDropLocalCleanupFromActionRef": 1,
        "pub fn explicitDropLocalCleanup": 1,
        "pub fn explicitDropLocalCleanupFromActionRef": 1,
    },
    "src/backend_cleanup.zig": {
        "defer_ref: mir.DeferCleanupRef": 1,
        "pub const CleanupEdgeKind": 1,
        "pub const CleanupRef": 1,
        "pub const CleanupEdgePlan": 1,
        "pub fn buildCleanupEdgePlan": 1,
        "pub fn validateFunctionCleanupAuthority": 1,
        "fn localNameForValueId": 1,
        "fn sourceMatches": 1,
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
        "fn checkVaCall(": 1,
        "fn vaCursorArgumentValid(": 1,
        "E_VA_START_CONTEXT": 1,
        "fn checkTrapKind(": 1,
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
    "src/builtin_syntax.zig": {
        "pub fn knownContractCalleeName(": 1,
        "pub fn reflectionCallKind(": 1,
        "pub fn isAssumeNoaliasCall(": 0,
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
        "pub fn isDropCall(": 0,
        "pub fn isAssumeNoaliasCall(": 0,
        "fn bitcastTargetType(": 0,
        "pub fn reflectionCallKind(": 0,
        "pub const ReflectionCallKind": 0,
        "ast_query.isPhysCall(call.callee.*)": 0,
    },
    # The ordinary C backend now consumes executable MIR. Keep a compact
    # no-resurrection ratchet for the retired AST function-body authority.
    "src/lower_c_emitter.zig": {
        "fn emitStmt(": 0,
        "fn emitBlockItems(": 0,
        "fn emitExpr(": 0,
        "fn emitFunctionBody(": 0,
        "fn arithContext(": 0,
        "fn accessEmitContext(": 0,
        "fn tryReplacementEmitContext(": 0,
        "backend_cleanup.buildCleanupEdgePlan": 0,
        "mir_ownership_authority.autoDropLocalCleanupFromActionRef": 0,
    },
    "src/lower_llvm.zig": {
        "fn emitExpr(self: *LlvmEmitter": 0,
        "fn emitBlock(self: *LlvmEmitter": 0,
        "fn emitStmt(self: *LlvmEmitter": 0,
        '@import("backend_cleanup.zig")': 0,
        '@import("mir_ownership_authority.zig")': 0,
        '@import("syntax_bridge.zig")': 0,
        "fn emitExecutableMirFunction(self: *LlvmEmitter, fact: mir.CallableEmissionFact": 1,
        "mir_executable_llvm.renderWithCallAbiAndOptions": 1,
        "fn emitCollectedGlobals(self: *LlvmEmitter)": 1,
        "fn emitCollectedCallableDeclarations(self: *LlvmEmitter)": 1,
    },
    "src/lower_llvm_op.zig": {
        "trapHelperForCall(": 0,
    },
    "src/lower_llvm_atomic.zig": {
        "isAtomicInitCall": 0,
        "isAtomicInitExpr": 0,
        "atomicInitValue": 0,
    },
    "src/mir_tests.zig": {
        "MIR owns DMA call identities and complete types": 1,
        "MIR owns runtime assert condition types": 1,
        "MIR owns ordinary direct call result and argument types": 1,
        "MIR records typed call target facts for atomic member calls": 1,
        "MIR owns discard call identities and argument types": 1,
        "MIR lowering admission rejects unknown call-target result facts": 1,
        "MIR assign instructions carry known lowering types": 1,
        "MIR lowering admission rejects unknown assign instruction types": 1,
        "MIR lowering admission rejects unknown contextual call instruction types": 1,
        "MIR lowering admission rejects unknown qualified union constructor call instruction types": 1,
    },
    "src/lower_c_tests.zig": {
        "lower-c runtime hook suppression uses MIR source spelling view": 0,
        "lower-c runtime hook suppression uses VerifiedProgram runtime hook facts": 1,
        "lower-c DMA calls consume MIR identities and complete types": 1,
        "lower-c runtime asserts require MIR bool condition types": 1,
        "lower-c ordinary direct calls require MIR result and argument types": 1,
        "lower-c atomic init requires MIR identity and complete types": 1,
        "lower-c discard calls require MIR identity and argument type facts": 0,
    },
    "src/lower_llvm_tests.zig": {
        "LLVM runtime hook suppression uses MIR source spelling view": 0,
        "LLVM runtime hook suppression uses VerifiedProgram runtime hook facts": 1,
        "LLVM DMA calls consume MIR identities and complete types": 1,
        "LLVM runtime asserts require MIR bool condition types": 1,
        "LLVM ordinary direct calls require MIR result and argument types": 1,
        "LLVM atomic init requires MIR identity and complete types": 1,
        "LLVM discard calls require MIR identity and argument type facts": 0,
    },
    "tests/spec/no_implicit_conversion.mc": {
        "EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE": 9,
    },
    "tests/spec/initialization.mc": {
        "EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE": 1,
    },
    "tests/spec/global_initializers.mc": {
        "EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE": 1,
        "EXPECT_ERROR: E_GLOBAL_INITIALIZER_NOT_STATIC": 2,
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


def duplicate_semantic_family_files() -> list[tuple[str, str]]:
    """Detect duplicate file keys inside an inference family before dict parsing hides them."""
    source = Path(__file__).read_text(encoding="utf-8")
    tree = ast.parse(source)
    for node in tree.body:
        if not isinstance(node, ast.AnnAssign):
            continue
        if not isinstance(node.target, ast.Name) or node.target.id != "SEMANTIC_INFERENCE_FAMILIES":
            continue
        if not isinstance(node.value, ast.Dict):
            return []
        duplicates: list[tuple[str, str]] = []
        for family_key, family_value in zip(node.value.keys, node.value.values):
            if not isinstance(family_key, ast.Constant) or not isinstance(family_key.value, str):
                continue
            if not isinstance(family_value, ast.Dict):
                continue
            seen: set[str] = set()
            for file_key in family_value.keys:
                if not isinstance(file_key, ast.Constant) or not isinstance(file_key.value, str):
                    continue
                pair = (family_key.value, file_key.value)
                if file_key.value in seen and pair not in duplicates:
                    duplicates.append(pair)
                seen.add(file_key.value)
        return duplicates
    return []


def zig_top_level_functions(relative: str) -> dict[str, bool]:
    """Return top-level Zig function names and whether each is public.

    This intentionally uses a conservative line-based parser for the current
    code style: top-level helpers in this repository start at column 0 with
    either `fn name(` or `pub fn name(`. Nested helpers are indented and do not
    participate in the backend-inference surface budget.
    """
    text = (REPO_ROOT / relative).read_text(encoding="utf-8")
    functions: dict[str, bool] = {}
    for match in re.finditer(r"^(pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", text, re.MULTILINE):
        functions[match.group(2)] = match.group(1) is not None
    return functions


def main() -> int:
    missing: list[str] = []
    checked = 0

    for duplicate in duplicate_exact_count_files():
        missing.append(f"EXACT_COUNTS: duplicate top-level file key {duplicate!r}")
        checked += 1
    for family, duplicate in duplicate_semantic_family_files():
        missing.append(f"SEMANTIC_INFERENCE_FAMILIES: {family}: duplicate file key {duplicate!r}")
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

    for relative, counts in sorted(EXACT_COUNTS.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"EXACT_COUNTS: {relative}: file missing")
            continue

        for needle, expected in counts.items():
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
    if len(budget_families) != 5:
        missing.append(f"backend AST-inference budget: expected 5 registered families, found {len(budget_families)}")
    for family in budget_families:
        checked += 1
        if family not in SEMANTIC_INFERENCE_FAMILIES:
            missing.append(f"backend AST-inference budget: unknown family {family!r}")

    checked += 1
    if set(budget_families) != set(BACKEND_AST_INFERENCE_DISPOSITIONS):
        missing.append("T3 disposition audit: disposition keys do not exactly match the backend AST-inference budget")

    checked += 1
    if (REPO_ROOT / RETIRED_LOWER_C_INFER_PATH).exists():
        missing.append(f"retired lower_c_infer module: {RETIRED_LOWER_C_INFER_PATH} must stay deleted")

    for relative, anchors in sorted(T3_DISPOSITION_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"T3 disposition audit: {relative}: file missing")
            continue
        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"T3 disposition audit: {relative}: missing anchor {anchor!r}")

    backend_files = {"src/ast_query.zig"}
    source_dir = REPO_ROOT / "src"
    backend_files.update(
        path.relative_to(REPO_ROOT).as_posix()
        for pattern in ("lower_c.zig", "lower_c_*.zig", "lower_llvm.zig", "lower_llvm_*.zig")
        for path in source_dir.glob(pattern)
        if not path.name.endswith("_tests.zig")
    )
    classified_files = {relative for files in T4_BACKEND_FILE_AUTHORITY.values() for relative in files}
    checked += 1
    if backend_files != classified_files:
        missing.append(
            "T4 backend authority audit: exact file set differs; "
            f"unclassified={sorted(backend_files - classified_files)!r}, "
            f"stale={sorted(classified_files - backend_files)!r}"
        )
    classified_entries = [relative for files in T4_BACKEND_FILE_AUTHORITY.values() for relative in files]
    checked += 1
    if len(classified_entries) != len(classified_files):
        missing.append("T4 backend authority audit: a backend file has multiple top-level classifications")
    for relative, anchors in sorted(T4_AUTHORITY_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"T4 backend authority audit: {relative}: file missing")
            continue
        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"T4 backend authority audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(P4_PROVENANCE_POLICY_PARITY_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"P4 provenance policy parity audit: {relative}: file missing")
            continue
        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"P4 provenance policy parity audit: {relative}: missing anchor {anchor!r}")

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

    for relative, anchors in sorted(EXTERN_AGGREGATE_ABI_BOUNDARY_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"extern aggregate ABI boundary audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"extern aggregate ABI boundary audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(C_AGGREGATE_GLOBAL_REPRESENTATION_POLICY_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"C aggregate-global representation policy audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"C aggregate-global representation policy audit: {relative}: missing anchor {anchor!r}")

    for relative, anchors in sorted(STRUCT_LITERAL_CONSTRUCTION_FACT_AUDIT.items()):
        path = REPO_ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            missing.append(f"struct-literal construction fact audit: {relative}: file missing")
            continue

        for anchor in anchors:
            checked += 1
            if anchor not in text:
                missing.append(f"struct-literal construction fact audit: {relative}: missing anchor {anchor!r}")

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

    print(
        "semantic facts inventory anchors OK "
        f"({checked} anchors, retired lower_c_infer file absent)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
