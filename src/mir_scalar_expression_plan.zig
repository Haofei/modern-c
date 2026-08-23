//! Syntax-free, fail-closed plans for two bounded scalar expression shapes.
//!
//! These plans retain the MIR identities that order each operation.  Backends
//! therefore do not reopen an AST body to distinguish a local cast/shift from
//! a checked add, or a direct call from the following bitwise comparison.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const Location = struct {
    span_id: mir.SpanId,
    source: mir.SourcePoint,
};

pub const TypeRef = struct {
    id: mir.TypeId,
    value_ty: mir.ValueType,
    location: Location,
};

pub const Value = struct {
    name: []const u8,
    id: mir.ValueId,
    ty: TypeRef,
    location: Location,
};

pub const Integer = struct {
    value: usize,
    ty: TypeRef,
    location: Location,
};

pub const HighWord = struct {
    parameter: Value,
    local: Value,
    shift_location: Location,
    shift_result: TypeRef,
    shift_amount: Integer,
    cast_location: Location,
    cast_source: TypeRef,
    cast_target: TypeRef,
    increment_location: Location,
    increment: Integer,
    return_location: Location,
};

pub const FlagSet = struct {
    address: Value,
    mask: Value,
    call_location: Location,
    callee_name: []const u8,
    callee_id: mir.ValueId,
    call_result: TypeRef,
    call_argument: TypeRef,
    and_location: Location,
    and_result: TypeRef,
    compare_location: Location,
    compare_result: TypeRef,
    zero: Integer,
    return_location: Location,
};

pub const Plan = union(enum) {
    high_word: HighWord,
    flag_set: FlagSet,
};

/// Admit only the exact bounded expressions documented by the plan types.
/// Any unknown instruction, fact, edge, identity, or cleanup shape remains
/// outside shared lowering.
pub fn build(function: mir.Function) ?Plan {
    return buildHighWord(function) orelse buildFlagSet(function);
}

fn buildHighWord(function: mir.Function) ?Plan {
    if (!clean(function) or function.blocks.len != 3 or function.trap_edges.len != 2) return null;
    const entry = function.blocks[0];
    if (entry.terminator != .return_ or entry.successors.len != 2) return null;
    if (!isExactTrap(function.blocks[1], .InvalidShift) or !isExactTrap(function.blocks[2], .IntegerOverflow)) return null;

    var local: ?mir.Instruction = null;
    var shift: ?mir.Instruction = null;
    var add: ?mir.Instruction = null;
    var shift_check: ?mir.Instruction = null;
    var add_check: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    var params: usize = 0;
    var exprs: usize = 0;
    var target_types: usize = 0;
    var integer_conversions: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param => params += 1,
        .local => {
            if (local != null) return null;
            local = instruction;
        },
        .binary => {
            if (std.mem.eql(u8, instruction.detail, "shr") and shift == null) shift = instruction else if (std.mem.eql(u8, instruction.detail, "add") and add == null) add = instruction else return null;
        },
        .add_overflow => {
            if (std.mem.eql(u8, instruction.detail, "shr") and shift_check == null) shift_check = instruction else if (std.mem.eql(u8, instruction.detail, "add") and add_check == null) add_check = instruction else return null;
        },
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        .expr => exprs += 1,
        .target_type => target_types += 1,
        .integer_literal_conversion => integer_conversions += 1,
        else => return null,
    };
    if (params != 1 or exprs != 5 or target_types != 10 or integer_conversions != 2) return null;

    const local_instruction = local orelse return null;
    const shift_instruction = shift orelse return null;
    const add_instruction = add orelse return null;
    const shift_overflow = shift_check orelse return null;
    const add_overflow = add_check orelse return null;
    const return_instruction = returned orelse return null;
    if (!shift_instruction.typed_span_id.isValid() or !add_instruction.typed_span_id.isValid() or
        !shift_instruction.typed_left_operand_span_id.isValid() or !shift_instruction.typed_right_operand_span_id.isValid() or
        !add_instruction.typed_left_operand_span_id.isValid() or !add_instruction.typed_right_operand_span_id.isValid() or
        !shift_overflow.typed_span_id.eql(shift_instruction.typed_span_id) or
        !add_overflow.typed_span_id.eql(add_instruction.typed_span_id)) return null;

    const local_id = local_instruction.typed_value_id orelse return null;
    const local_name = valueName(function, local_id) orelse return null;
    if (!std.mem.eql(u8, local_instruction.detail, local_name) or
        !local_instruction.typed_value_operand_span_id.isValid() or
        !return_instruction.typed_value_operand_span_id.eql(add_instruction.typed_span_id)) return null;
    const cast_span = local_instruction.typed_value_operand_span_id;
    const cast = expression(function, entry, cast_span) orelse return null;
    if (!std.mem.eql(u8, cast.detail, "cast") or !sameSource(cast, local_instruction)) return null;

    const parameter = valueAt(function, entry, shift_instruction.typed_left_operand_span_id) orelse return null;
    const shift_amount = integerAt(function, entry, shift_instruction.typed_right_operand_span_id) orelse return null;
    const add_left = valueAt(function, entry, add_instruction.typed_left_operand_span_id) orelse return null;
    const increment = integerAt(function, entry, add_instruction.typed_right_operand_span_id) orelse return null;
    if (!add_left.id.eql(local_id) or !std.mem.eql(u8, add_left.name, local_name) or
        !integerFactMatches(function, shift_amount) or !integerFactMatches(function, increment)) return null;

    const local_ty = expressionType(function, add_instruction.typed_left_operand_span_id) orelse return null;
    const shift_ty = expressionType(function, shift_instruction.typed_span_id) orelse return null;
    const cast_result = expressionType(function, cast_span) orelse return null;
    const cast_source = targetType(function, .explicit_cast_source, cast_span) orelse return null;
    const cast_target = targetType(function, .explicit_cast_target, cast_span) orelse return null;
    const add_result = expressionType(function, add_instruction.typed_span_id) orelse return null;
    const return_result = expressionType(function, return_instruction.typed_value_operand_span_id) orelse return null;
    if (!sameType(local_ty, cast_target) or !sameType(local_ty, cast_result) or !sameType(local_ty, add_result) or
        !sameType(local_ty, return_result) or !sameType(shift_ty, cast_source) or
        !sameType(parameter.ty, shift_ty) or !sameType(shift_amount.ty, shift_ty) or
        !sameType(increment.ty, local_ty) or !sameValueType(local_instruction.result_ty, local_ty.value_ty) or
        !sameValueType(return_instruction.result_ty, local_ty.value_ty)) return null;

    if (!hasTrapEdge(function, entry.id, function.blocks[1].id, .InvalidShift, .checked_shift, shift_instruction.typed_span_id) or
        !hasTrapEdge(function, entry.id, function.blocks[2].id, .IntegerOverflow, .checked_arithmetic, add_instruction.typed_span_id)) return null;

    return .{ .high_word = .{
        .parameter = parameter,
        .local = .{ .name = local_name, .id = local_id, .ty = local_ty, .location = location(local_instruction) },
        .shift_location = location(shift_instruction),
        .shift_result = shift_ty,
        .shift_amount = shift_amount,
        .cast_location = location(cast),
        .cast_source = cast_source,
        .cast_target = cast_target,
        .increment_location = location(add_instruction),
        .increment = increment,
        .return_location = location(return_instruction),
    } };
}

fn buildFlagSet(function: mir.Function) ?Plan {
    if (!clean(function) or function.blocks.len != 1 or function.trap_edges.len != 0) return null;
    const entry = function.blocks[0];
    if (entry.terminator != .return_ or entry.successors.len != 0) return null;

    var call: ?mir.Instruction = null;
    var and_: ?mir.Instruction = null;
    var compare: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    var params: usize = 0;
    var exprs: usize = 0;
    var target_types: usize = 0;
    var integer_conversions: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param => params += 1,
        .call => {
            if (call != null) return null;
            call = instruction;
        },
        .binary => {
            if (std.mem.eql(u8, instruction.detail, "bit_and") and and_ == null) and_ = instruction else if (std.mem.eql(u8, instruction.detail, "ne") and compare == null) compare = instruction else return null;
        },
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        .expr => exprs += 1,
        .target_type => target_types += 1,
        .integer_literal_conversion => integer_conversions += 1,
        else => return null,
    };
    if (params != 2 or exprs != 4 or target_types != 9 or integer_conversions != 1) return null;

    const call_instruction = call orelse return null;
    const and_instruction = and_ orelse return null;
    const compare_instruction = compare orelse return null;
    const return_instruction = returned orelse return null;
    const callee_id = call_instruction.typed_value_id orelse return null;
    const callee_name = valueName(function, callee_id) orelse return null;
    if (!std.mem.eql(u8, call_instruction.detail, callee_name) or !call_instruction.typed_span_id.isValid() or
        !call_instruction.typed_callee_span_id.isValid() or
        !operandsMatch(and_instruction, call_instruction.typed_span_id, null) or
        !operandsMatch(compare_instruction, and_instruction.typed_span_id, null) or
        !return_instruction.typed_value_operand_span_id.eql(compare_instruction.typed_span_id)) return null;

    const call_argument_span = directArgumentSpan(function, call_instruction.typed_callee_span_id, 0) orelse return null;
    const address = valueAt(function, entry, call_argument_span) orelse return null;
    const mask = valueAt(function, entry, and_instruction.typed_right_operand_span_id) orelse return null;
    const zero = integerAt(function, entry, compare_instruction.typed_right_operand_span_id) orelse return null;
    if (!integerFactMatches(function, zero)) return null;
    const call_result = targetType(function, .direct_call_result, call_instruction.typed_callee_span_id) orelse return null;
    const call_argument = targetType(function, .direct_call_argument, call_argument_span) orelse return null;
    const and_result = expressionType(function, and_instruction.typed_span_id) orelse return null;
    const compare_result = expressionType(function, compare_instruction.typed_span_id) orelse return null;
    const return_result = expressionType(function, return_instruction.typed_value_operand_span_id) orelse return null;
    if (!sameType(address.ty, call_argument) or !sameType(call_result, and_result) or !sameType(mask.ty, and_result) or
        !sameType(zero.ty, and_result) or !sameType(compare_result, return_result) or
        !sameValueType(return_instruction.result_ty, compare_result.value_ty)) return null;

    return .{ .flag_set = .{
        .address = address,
        .mask = mask,
        .call_location = location(call_instruction),
        .callee_name = callee_name,
        .callee_id = callee_id,
        .call_result = call_result,
        .call_argument = call_argument,
        .and_location = location(and_instruction),
        .and_result = and_result,
        .compare_location = location(compare_instruction),
        .compare_result = compare_result,
        .zero = zero,
        .return_location = location(return_instruction),
    } };
}

fn clean(function: mir.Function) bool {
    if (function.bounds_facts.len != 0 or function.access_facts.len != 0 or function.pointer_provenance_facts.len != 0 or
        function.representation_facts.len != 0 or function.ownership_cleanup_plan.actions.len != 0 or
        function.ownership_cleanup_plan.cancellations.len != 0) return false;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return false;
    return true;
}

fn isExactTrap(block: mir.Block, kind: mir.TrapKind) bool {
    return block.instructions.len == 0 and block.successors.len == 0 and switch (block.terminator) {
        .trap_ => |actual| actual == kind,
        else => false,
    };
}

fn hasTrapEdge(function: mir.Function, from: usize, trap: usize, kind: mir.TrapKind, source: mir.TrapSource, span_id: mir.SpanId) bool {
    var count: usize = 0;
    for (function.trap_edges) |edge| {
        if (edge.from_block == from and edge.trap_block == trap and edge.kind == kind and edge.source == source and edge.typed_span_id.eql(span_id)) count += 1;
    }
    return count == 1;
}

fn location(instruction: mir.Instruction) Location {
    return .{ .span_id = instruction.typed_span_id, .source = .{
        .line = instruction.line,
        .column = instruction.column,
        .offset = instruction.source_offset,
        .len = instruction.source_len,
    } };
}

fn sameSource(left: mir.Instruction, right: mir.Instruction) bool {
    return left.typed_span_id.eql(right.typed_value_operand_span_id);
}

fn valueName(function: mir.Function, id: mir.ValueId) ?[]const u8 {
    for (function.value_identities) |identity| if (identity.id.eql(id)) return identity.spelling;
    return null;
}

fn expression(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .expr or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    _ = function;
    return found;
}

fn valueAt(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?Value {
    const instruction = expression(function, block, span_id) orelse return null;
    const id = instruction.typed_value_id orelse return null;
    const name = valueName(function, id) orelse return null;
    const ty = expressionType(function, span_id) orelse return null;
    if (!std.mem.eql(u8, instruction.detail, name)) return null;
    return .{ .name = name, .id = id, .ty = ty, .location = location(instruction) };
}

fn integerAt(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?Integer {
    const instruction = expression(function, block, span_id) orelse return null;
    const value = instruction.constant_usize_value orelse return null;
    if (!std.mem.eql(u8, instruction.detail, "int")) return null;
    const conversion = conversionAt(block, span_id) orelse return null;
    return .{ .value = value, .ty = .{
        .id = conversion.typed_result_ty,
        .value_ty = conversion.result_ty,
        .location = location(conversion),
    }, .location = location(instruction) };
}

fn conversionAt(block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .integer_literal_conversion or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn integerFactMatches(function: mir.Function, integer: Integer) bool {
    var count: usize = 0;
    for (function.integer_facts) |fact| {
        if (!sameValueType(fact.target_ty, integer.ty.value_ty)) continue;
        if (fact.source.line != integer.location.source.line or fact.source.column != integer.location.source.column) continue;
        count += 1;
    }
    return count == 1;
}

fn directArgumentSpan(function: mir.Function, callee_span: mir.SpanId, index: usize) ?mir.SpanId {
    var found: ?mir.SpanId = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_argument or fact.target_index != index or !fact.typed_callee_span_id.eql(callee_span)) continue;
        if (!fact.typed_span_id.isValid() or found != null) return null;
        found = fact.typed_span_id;
    }
    return found;
}

fn expressionType(function: mir.Function, span_id: mir.SpanId) ?TypeRef {
    return targetType(function, .expression_result, span_id);
}

fn targetType(function: mir.Function, kind: mir.TargetTypeKind, span_id: mir.SpanId) ?TypeRef {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or !fact.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = fact;
    }
    const fact = found orelse return null;
    return .{ .id = fact.typed_result_ty, .value_ty = fact.result_ty, .location = .{ .span_id = fact.typed_span_id, .source = fact.source } };
}

fn operandsMatch(instruction: mir.Instruction, left: mir.SpanId, right: ?mir.SpanId) bool {
    return instruction.typed_left_operand_span_id.eql(left) and if (right) |expected|
        instruction.typed_right_operand_span_id.eql(expected)
    else
        instruction.typed_right_operand_span_id.isValid();
}

fn sameType(left: TypeRef, right: TypeRef) bool {
    return left.id.eql(right.id) and sameValueType(left.value_ty, right.value_ty);
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}
