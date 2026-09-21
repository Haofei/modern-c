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

pub fn nullabilityDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "null_to_nonnull")) return "E_NULL_NON_NULL_POINTER";
    if (std.mem.eql(u8, finding, "nullable_to_nonnull")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    return "E_NO_IMPLICIT_POINTER_CONVERSION";
}

pub fn conversionDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "integer_literal_out_of_range")) return "E_INTEGER_LITERAL_OUT_OF_RANGE";
    if (std.mem.eql(u8, finding, "for_base_not_iterable")) return "E_FOR_BASE_NOT_ARRAY_OR_SLICE";
    if (std.mem.eql(u8, finding, "index_base_not_array_or_slice")) return "E_INDEX_BASE_NOT_ARRAY_OR_SLICE";
    if (std.mem.eql(u8, finding, "index_not_usize")) return "E_INDEX_NOT_USIZE";
    if (std.mem.eql(u8, finding, "return_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "initializer_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "assignment_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "call_arg_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "condition_type_mismatch")) return "E_CONDITION_NOT_BOOL";
    if (std.mem.eql(u8, finding, "return_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "initializer_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "assignment_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "call_arg_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "return_type_mismatch")) return "E_RETURN_TYPE_MISMATCH";
    if (std.mem.eql(u8, finding, "array_to_pointer_decay")) return "E_ARRAY_TO_POINTER_DECAY";
    return "E_NO_IMPLICIT_CONVERSION";
}

pub fn aggregateDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "array_literal_length")) return "E_ARRAY_LITERAL_LENGTH";
    if (std.mem.eql(u8, finding, "struct_literal_duplicate_field")) return "E_DUPLICATE_STRUCT_LITERAL_FIELD";
    if (std.mem.eql(u8, finding, "struct_literal_unknown_field")) return "E_UNKNOWN_STRUCT_FIELD";
    if (std.mem.eql(u8, finding, "struct_literal_missing_field")) return "E_STRUCT_LITERAL_MISSING_FIELD";
    return "E_NO_IMPLICIT_CONVERSION";
}

pub fn resultFindingDiagnostic(finding: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, finding, "unhandled_result")) return "E_UNHANDLED_RESULT";
    if (std.mem.eql(u8, finding, "try_requires_result_or_nullable")) return "E_TRY_REQUIRES_RESULT_OR_NULLABLE";
    if (std.mem.eql(u8, finding, "try_payload_c_void_conversion")) return "E_C_VOID_CONVERSION";
    if (std.mem.eql(u8, finding, "try_payload_pointer_conversion")) return "E_NO_IMPLICIT_POINTER_CONVERSION";
    if (std.mem.eql(u8, finding, "try_payload_type_mismatch")) return "E_RETURN_TYPE_MISMATCH";
    if (std.mem.eql(u8, finding, "if_let_optional_required")) return "E_IF_LET_OPTIONAL_REQUIRED";
    if (std.mem.eql(u8, finding, "if_let_result_required")) return "E_IF_LET_RESULT_REQUIRED";
    if (std.mem.eql(u8, finding, "if_let_result_tag")) return "E_IF_LET_RESULT_TAG";
    if (std.mem.eql(u8, finding, "if_let_narrow_pattern")) return "E_IF_LET_NARROW_PATTERN";
    if (std.mem.eql(u8, finding, "switch_result_tag")) return "E_SWITCH_RESULT_TAG";
    if (std.mem.eql(u8, finding, "switch_result_required")) return "E_SWITCH_RESULT_REQUIRED";
    if (std.mem.eql(u8, finding, "switch_multi_binding_arm")) return "E_SWITCH_MULTI_BINDING_ARM";
    return null;
}

pub fn switchFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "duplicate_switch_case")) return "E_DUPLICATE_SWITCH_CASE";
    if (std.mem.eql(u8, finding, "unknown_enum_case")) return "E_UNKNOWN_ENUM_CASE";
    if (std.mem.eql(u8, finding, "closed_enum_switch_exhaustive")) return "E_CLOSED_ENUM_SWITCH_EXHAUSTIVE";
    if (std.mem.eql(u8, finding, "unknown_union_case")) return "E_UNKNOWN_UNION_CASE";
    if (std.mem.eql(u8, finding, "union_case_has_no_payload")) return "E_UNION_CASE_HAS_NO_PAYLOAD";
    if (std.mem.eql(u8, finding, "switch_literal_type_mismatch")) return "E_NO_IMPLICIT_CONVERSION";
    return "E_DUPLICATE_SWITCH_CASE";
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

pub fn ffiFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "c_void_deref")) return "E_C_VOID_DEREF";
    return "E_C_VOID_NO_LAYOUT";
}

pub fn usageFindingDiagnostic(finding: []const u8) []const u8 {
    if (std.mem.eql(u8, finding, "atomic_operation")) return "E_ATOMIC_OPERATION";
    if (std.mem.eql(u8, finding, "dma_operation")) return "E_DMA_OPERATION";
    if (std.mem.eql(u8, finding, "atomic_ordering")) return "E_ATOMIC_ORDERING";
    if (std.mem.eql(u8, finding, "mmio_ordering")) return "E_MMIO_ORDERING";
    if (std.mem.eql(u8, finding, "closed_enum_conversion")) return "E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION";
    if (std.mem.eql(u8, finding, "bitcast_type")) return "E_BITCAST_TYPE";
    if (std.mem.eql(u8, finding, "dma_cache_mode")) return "E_DMA_CACHE_MODE";
    if (std.mem.eql(u8, finding, "local_address_escape")) return "E_LOCAL_ADDRESS_ESCAPE";
    return "E_OPERATOR_OPERAND";
}
