const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const mir_model = @import("mir_model.zig");

pub const ConversionContext = enum {
    return_,
    initializer,
    assignment,
    call_arg,
    condition,
};

pub const IrqContextCallFinding = enum {
    unproven_call,
    blocking,
};

pub const MmioOperation = enum {
    read,
    write,
};

pub const MmioAccessInfo = struct {
    access: ast_query.MmioRegisterAccess,
    op: MmioOperation,
};

pub const ArithmeticDomain = enum {
    wrap,
    sat,
    serial,
    counter,
};

pub fn irqContextFindingName(finding: IrqContextCallFinding) []const u8 {
    return switch (finding) {
        .unproven_call => "irq_call",
        .blocking => "irq_blocking",
    };
}

pub fn irqContextDiagnostic(finding: IrqContextCallFinding) []const u8 {
    return switch (finding) {
        .unproven_call => "E_IRQ_CONTEXT_CALL",
        .blocking => "E_IRQ_CONTEXT_BLOCKING",
    };
}

pub fn contractAllowsUnchecked(contract: []const u8, callee: []const u8) bool {
    if (std.mem.eql(u8, contract, "no_overflow")) return noOverflowUncheckedOp(callee) != null;
    if (std.mem.eql(u8, contract, "noalias")) return std.mem.eql(u8, callee, "compiler.assume_noalias_unchecked");
    return false;
}

pub fn noOverflowUncheckedOp(callee: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, callee, "unchecked.add") or std.mem.eql(u8, callee, "unchecked_add")) return "add";
    if (std.mem.eql(u8, callee, "unchecked.sub") or std.mem.eql(u8, callee, "unchecked_sub")) return "sub";
    if (std.mem.eql(u8, callee, "unchecked.mul") or std.mem.eql(u8, callee, "unchecked_mul")) return "mul";
    return null;
}

pub fn hasAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .no_lang_trap => if (std.mem.eql(u8, name, "no_lang_trap")) return true,
        .naked => if (std.mem.eql(u8, name, "naked")) return true,
        .@"noinline" => if (std.mem.eql(u8, name, "noinline")) return true,
        .weak => if (std.mem.eql(u8, name, "weak")) return true,
        .named => |ident| if (std.mem.eql(u8, ident.text, name)) return true,
        .unsafe_contract, .backend_name, .origin, .section, .@"align" => {},
    };
    return false;
}

/// The diagnostic a nullability-conversion finding is reported as. The chain
/// this replaced had a fallback identical to its second arm, so a spelling it
/// did not know was reported as `nullable_to_nonnull`.
pub fn nullabilityDiagnostic(finding: mir_model.NullabilityFinding) []const u8 {
    return switch (finding) {
        .null_to_nonnull => "E_NULL_NON_NULL_POINTER",
        .nullable_to_nonnull => "E_NO_IMPLICIT_POINTER_CONVERSION",
    };
}

/// The diagnostic an implicit-conversion finding is reported as.
///
/// Several findings share one code on purpose: the four `*_c_void_conversion`
/// members are all `E_C_VOID_CONVERSION` and the four `*_pointer_conversion`
/// members are all `E_NO_IMPLICIT_POINTER_CONVERSION`. The context survives on
/// the finding because the verification-fact dump names it; only the
/// diagnostic collapses it. The `eql` chain this replaced could not tell that
/// deliberate sharing apart from its own `E_NO_IMPLICIT_CONVERSION` fallback.
pub fn conversionDiagnostic(finding: mir_model.ConversionFinding) []const u8 {
    return switch (finding) {
        .integer_literal_out_of_range => "E_INTEGER_LITERAL_OUT_OF_RANGE",
        .for_base_not_iterable => "E_FOR_BASE_NOT_ARRAY_OR_SLICE",
        .index_base_not_array_or_slice => "E_INDEX_BASE_NOT_ARRAY_OR_SLICE",
        .index_not_usize => "E_INDEX_NOT_USIZE",
        .condition_type_mismatch => "E_CONDITION_NOT_BOOL",
        .array_to_pointer_decay => "E_ARRAY_TO_POINTER_DECAY",
        .return_c_void_conversion,
        .initializer_c_void_conversion,
        .assignment_c_void_conversion,
        .call_arg_c_void_conversion,
        => "E_C_VOID_CONVERSION",
        .return_pointer_conversion,
        .initializer_pointer_conversion,
        .assignment_pointer_conversion,
        .call_arg_pointer_conversion,
        => "E_NO_IMPLICIT_POINTER_CONVERSION",
        .return_type_mismatch => "E_RETURN_TYPE_MISMATCH",
        .initializer_type_mismatch,
        .assignment_type_mismatch,
        .call_arg_type_mismatch,
        => "E_NO_IMPLICIT_CONVERSION",
    };
}

/// The diagnostic an aggregate-literal finding is reported as. The `eql`
/// chain this replaced fell through to `E_NO_IMPLICIT_CONVERSION`, a code
/// from a different family entirely, for a spelling it did not know.
pub fn aggregateDiagnostic(finding: mir_model.AggregateFinding) []const u8 {
    return switch (finding) {
        .array_literal_length => "E_ARRAY_LITERAL_LENGTH",
        .struct_literal_duplicate_field => "E_DUPLICATE_STRUCT_LITERAL_FIELD",
        .struct_literal_unknown_field => "E_UNKNOWN_STRUCT_FIELD",
        .struct_literal_missing_field => "E_STRUCT_LITERAL_MISSING_FIELD",
    };
}

/// The diagnostic a `Result` control-flow finding is reported as, or null
/// for the one member that is an observation rather than a refusal.
///
/// The `eql` chain this replaced returned null for *anything* it did not
/// recognise, so "no diagnostic" and "no mapping" were one answer. Here the
/// only null is `try_handled`, deliberately.
pub fn resultDiagnostic(finding: mir_model.ResultFinding) ?[]const u8 {
    return switch (finding) {
        .try_handled => null,
        .unhandled_result => "E_UNHANDLED_RESULT",
        .try_requires_result_or_nullable => "E_TRY_REQUIRES_RESULT_OR_NULLABLE",
        .try_payload_c_void_conversion => "E_C_VOID_CONVERSION",
        .try_payload_pointer_conversion => "E_NO_IMPLICIT_POINTER_CONVERSION",
        .try_payload_type_mismatch => "E_RETURN_TYPE_MISMATCH",
        .if_let_optional_required => "E_IF_LET_OPTIONAL_REQUIRED",
        .if_let_result_required => "E_IF_LET_RESULT_REQUIRED",
        .if_let_result_tag => "E_IF_LET_RESULT_TAG",
        .if_let_narrow_pattern => "E_IF_LET_NARROW_PATTERN",
        .switch_result_tag => "E_SWITCH_RESULT_TAG",
        .switch_result_required => "E_SWITCH_RESULT_REQUIRED",
        .switch_multi_binding_arm => "E_SWITCH_MULTI_BINDING_ARM",
    };
}

/// The diagnostic a switch-coverage finding is reported as. The chain this
/// replaced ended by returning `E_DUPLICATE_SWITCH_CASE` for an unmatched
/// spelling -- the same answer as a real duplicate case.
pub fn switchDiagnostic(finding: mir_model.SwitchFinding) []const u8 {
    return switch (finding) {
        .duplicate_switch_case => "E_DUPLICATE_SWITCH_CASE",
        .unknown_enum_case => "E_UNKNOWN_ENUM_CASE",
        .closed_enum_switch_exhaustive => "E_CLOSED_ENUM_SWITCH_EXHAUSTIVE",
        .unknown_union_case => "E_UNKNOWN_UNION_CASE",
        .union_case_has_no_payload => "E_UNION_CASE_HAS_NO_PAYLOAD",
        .switch_literal_type_mismatch => "E_NO_IMPLICIT_CONVERSION",
    };
}

/// The diagnostic an assignment-target finding is reported as.
///
/// The `eql` chain this replaced had a third answer, `E_INVALID_ASSIGNMENT_TARGET`,
/// for a spelling neither branch matched. No builder site ever produced one,
/// so the code was unreachable through this path; sema still reports it, which
/// is where it belongs.
pub fn assignmentDiagnostic(finding: mir_model.AssignmentFinding) []const u8 {
    return switch (finding) {
        .assign_to_immutable_local => "E_ASSIGN_TO_IMMUTABLE_LOCAL",
        .assign_through_const_view => "E_ASSIGN_THROUGH_CONST_VIEW",
    };
}

/// The diagnostic an arithmetic-domain finding is reported as. The `eql`
/// chain this replaced ended by returning `E_ARITH_POLICY_MIX` for anything
/// unrecognised, which was the same answer as a real `arith_policy_mix`.
pub fn arithmeticDomainDiagnostic(finding: mir_model.ArithmeticDomainFinding) []const u8 {
    return switch (finding) {
        .arith_policy_mix => "E_ARITH_POLICY_MIX",
        .arith_domain_division => "E_ARITH_DOMAIN_DIVISION",
        .bitwise_arith_domain_operand => "E_BITWISE_ARITH_DOMAIN_OPERAND",
        .ordered_arith_domain_operand => "E_ORDERED_ARITH_DOMAIN_OPERAND",
        .serial_operation => "E_SERIAL_OPERATION",
        .counter_operation => "E_COUNTER_OPERATION",
        .conversion_operation => "E_CONVERSION_OPERATION",
    };
}

/// The diagnostic an operator-operand finding is reported as.
///
/// This replaced `operatorFindingDiagnostic`, an `eql` chain over the
/// `operator_check` instruction's `detail` string whose final `return` was
/// both the `operator_operand` finding and the answer for a spelling nothing
/// produced. A total switch over the enum makes the two distinguishable and
/// makes a new finding a compile error here rather than a silent fallback.
pub fn operatorDiagnostic(finding: mir_model.OperatorFinding) []const u8 {
    return switch (finding) {
        .unsigned_negation => "E_UNSIGNED_NEGATION",
        .bitwise_signed_operand => "E_BITWISE_SIGNED_OPERAND",
        .bitwise_bool_operand => "E_BITWISE_BOOL_OPERAND",
        .bitwise_pointer_operand => "E_BITWISE_POINTER_OPERAND",
        .bool_operator_operand => "E_BOOL_OPERATOR_OPERAND",
        .signed_unsigned_mix => "E_SIGNED_UNSIGNED_MIX",
        .integer_promotion => "E_NO_IMPLICIT_INTEGER_PROMOTION",
        .float_binary_conversion => "E_NO_IMPLICIT_CONVERSION",
        .pointer_arith_single_object => "E_POINTER_ARITH_SINGLE_OBJECT",
        .pointer_ordering => "E_POINTER_ORDERING",
        .operator_operand => "E_OPERATOR_OPERAND",
    };
}

pub fn addressDerefDiagnostic(kind: mir_model.AddressClass) []const u8 {
    return switch (kind) {
        .paddr => "E_PADDR_DEREF",
        .vaddr => "E_VADDR_DEREF",
        .dma_addr => "E_DMA_ADDR_DEREF",
        .user_ptr => "E_USER_PTR_DEREF",
        .mmio_ptr => "E_MMIO_PTR_DEREF",
        .phys_ptr => "E_PHYS_PTR_DEREF",
    };
}

pub fn addressClassMismatchDiagnostic(target: mir_model.AddressClass, source: mir_model.AddressClass) []const u8 {
    if (source == .dma_addr and target == .paddr) return "E_DMA_ADDR_NOT_PADDR";
    if (source == .dma_addr and target == .vaddr) return "E_DMA_ADDR_NOT_VADDR";
    return "E_ADDRESS_CLASS_MISMATCH";
}

/// The diagnostic a `c_void` FFI finding is reported as. The chain this
/// replaced named only one of the two and returned the other as its
/// fallback, so "no layout" and "unrecognised" were the same answer.
pub fn ffiDiagnostic(finding: mir_model.FfiFinding) []const u8 {
    return switch (finding) {
        .c_void_deref => "E_C_VOID_DEREF",
        .c_void_no_layout => "E_C_VOID_NO_LAYOUT",
    };
}

/// The diagnostic a typed-resource usage finding is reported as.
///
/// The `eql` chain this replaced ended in `E_OPERATOR_OPERAND`, a code from
/// the operator family, and one of its arms -- `dma_operation` -- had no
/// producer at all, so the mapping outlived its finding without anything
/// saying so. `E_DMA_OPERATION` is kept as a member here because it is a real
/// diagnostic code that sema still reports; what has gone is the pretence
/// that the MIR builder can reach it.
pub fn usageDiagnostic(finding: mir_model.UsageFinding) []const u8 {
    return switch (finding) {
        .atomic_operation => "E_ATOMIC_OPERATION",
        .dma_operation => "E_DMA_OPERATION",
        .atomic_ordering => "E_ATOMIC_ORDERING",
        .mmio_ordering => "E_MMIO_ORDERING",
        .closed_enum_conversion => "E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION",
        .bitcast_type => "E_BITCAST_TYPE",
        .dma_cache_mode => "E_DMA_CACHE_MODE",
        .local_address_escape => "E_LOCAL_ADDRESS_ESCAPE",
    };
}
