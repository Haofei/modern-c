//! Syntax-free, fail-closed plan for a bounded nested conditional return.
//!
//! The admitted CFG is exactly `if !flag { return 5; } else if x > 10 {
//! return 6; } else { return 7; }`.  It carries MIR-owned value, span, type,
//! and literal identities so backends do not reopen the function AST body.

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

pub const Plan = struct {
    dispatch_block: mir.BlockId,
    nested_dispatch_block: mir.BlockId,
    flag: Value,
    flag_not_location: Location,
    x: Value,
    comparison_location: Location,
    comparison_limit: Integer,
    first_return: Integer,
    second_return: Integer,
    final_return: Integer,
    first_return_location: Location,
    second_return_location: Location,
    final_return_location: Location,
};

pub fn build(function: mir.Function) ?Plan {
    if (!effectsAreEmpty(function) or function.blocks.len != 7 or function.trap_edges.len != 0) return null;
    const entry = function.blocks[0];
    const after_outer = function.blocks[1];
    if (!entry.typed_id.isValid() or entry.successors.len != 2 or !emptyFallthrough(after_outer)) return null;
    const first_return_block = function.blocks[entry.successors[0]];
    const nested = function.blocks[entry.successors[1]];
    if (!first_return_block.typed_id.isValid() or !nested.typed_id.isValid()) return null;
    switch (entry.terminator) {
        .switch_ => {},
        else => return null,
    }
    const first_marker = switchMarker(entry) orelse return null;
    const flag_not = uniqueInstruction(entry, .unary) orelse return null;
    if (!std.mem.eql(u8, flag_not.detail, "logical_not") or !flag_not.typed_span_id.isValid() or !flag_not.typed_left_operand_span_id.isValid()) return null;
    const flag = valueAt(function, entry, flag_not.typed_left_operand_span_id) orelse return null;
    if (flag.ty.value_ty != .bool or !switchSubjectAt(function, entry, flag_not.typed_span_id) or !first_marker.typed_span_id.isValid()) return null;
    if (!entryHasExactOuterWork(entry, flag_not.typed_span_id)) return null;

    const first = integerReturn(function, first_return_block, first_marker.typed_span_id) orelse return null;
    const nested_marker = switchMarker(nested) orelse return null;
    const comparison = uniqueInstructionWith(nested, .binary, "gt", .value) orelse return null;
    if (!std.mem.eql(u8, comparison.detail, "gt") or !comparison.typed_span_id.isValid() or !comparison.typed_left_operand_span_id.isValid() or !comparison.typed_right_operand_span_id.isValid() or !switchSubjectAt(function, nested, comparison.typed_span_id)) return null;
    const x = valueAt(function, nested, comparison.typed_left_operand_span_id) orelse return null;
    const limit = integerAt(function, nested, comparison.typed_right_operand_span_id) orelse return null;
    if (!isSameInteger(x.ty.value_ty, limit.ty.value_ty) or !nestedHasExactWork(nested, comparison.typed_span_id)) return null;

    if (nested.successors.len != 2) return null;
    const second_return_block = function.blocks[nested.successors[0]];
    const final_return_block = function.blocks[nested.successors[1]];
    if (!second_return_block.typed_id.isValid() or !final_return_block.typed_id.isValid()) return null;
    if (!emptyJumpTo(function.blocks[4], 1)) return null;
    const second = integerReturn(function, second_return_block, nested_marker.typed_span_id) orelse return null;
    const final = integerReturn(function, final_return_block, nested_marker.typed_span_id) orelse return null;
    if (first.value != 5 or limit.value != 10 or second.value != 6 or final.value != 7) return null;
    if (!isSameInteger(first.ty.value_ty, x.ty.value_ty) or !isSameInteger(second.ty.value_ty, x.ty.value_ty) or !isSameInteger(final.ty.value_ty, x.ty.value_ty) or
        !sameType(first.ty, second.ty) or !sameType(second.ty, final.ty) or !sameValueType(function.return_ty, first.ty.value_ty)) return null;
    return .{
        .dispatch_block = entry.typed_id,
        .nested_dispatch_block = nested.typed_id,
        .flag = flag,
        .flag_not_location = location(function, flag_not) orelse return null,
        .x = x,
        .comparison_location = location(function, comparison) orelse return null,
        .comparison_limit = limit,
        .first_return = .{ .value = first.value, .ty = first.ty, .location = first.return_location },
        .second_return = .{ .value = second.value, .ty = second.ty, .location = second.return_location },
        .final_return = .{ .value = final.value, .ty = final.ty, .location = final.return_location },
        .first_return_location = first.return_location,
        .second_return_location = second.return_location,
        .final_return_location = final.return_location,
    };
}

const IntegerReturn = struct { value: usize, ty: TypeRef, return_location: Location };

fn integerReturn(function: mir.Function, block: mir.Block, marker_span: mir.SpanId) ?IntegerReturn {
    if (!block.typed_id.isValid() or block.successors.len != 0 or block.terminator != .return_) return null;
    var return_instruction: ?mir.Instruction = null;
    var marker_count: usize = 0;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .expr => {
            if (std.mem.eql(u8, instruction.detail, "literal") and instruction.result_ty == .branch and instruction.typed_span_id.eql(marker_span)) {
                marker_count += 1;
            } else if (!std.mem.eql(u8, instruction.detail, "int")) return null;
        },
        .integer_literal_conversion, .target_type => {},
        .return_value => {
            if (return_instruction != null) return null;
            return_instruction = instruction;
        },
        else => return null,
    };
    if (marker_count != 1) return null;
    const returned = return_instruction orelse return null;
    const value = integerAt(function, block, returned.typed_value_operand_span_id) orelse return null;
    if (!sameValueType(returned.result_ty, value.ty.value_ty)) return null;
    return .{ .value = value.value, .ty = value.ty, .return_location = location(function, returned) orelse return null };
}

fn entryHasExactOuterWork(block: mir.Block, condition_span: mir.SpanId) bool {
    var params: usize = 0;
    var markers: usize = 0;
    var unary: usize = 0;
    var expressions: usize = 0;
    var target_types: usize = 0;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .param => params += 1,
        .binary => {
            if (std.mem.eql(u8, instruction.detail, "switch_subject") and instruction.result_ty == .branch) markers += 1 else return false;
        },
        .unary => {
            if (std.mem.eql(u8, instruction.detail, "logical_not") and instruction.typed_span_id.eql(condition_span)) unary += 1 else return false;
        },
        .expr => expressions += 1,
        .target_type => target_types += 1,
        else => return false,
    };
    return params == 2 and markers == 1 and unary == 1 and expressions == 1 and target_types == 3;
}

fn nestedHasExactWork(block: mir.Block, condition_span: mir.SpanId) bool {
    var markers: usize = 0;
    var comparison: usize = 0;
    var arm_marker: usize = 0;
    var expressions: usize = 0;
    var targets: usize = 0;
    var conversions: usize = 0;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .expr => {
            if (std.mem.eql(u8, instruction.detail, "literal") and instruction.result_ty == .branch) arm_marker += 1 else expressions += 1;
        },
        .binary => {
            if (std.mem.eql(u8, instruction.detail, "switch_subject") and instruction.result_ty == .branch) markers += 1 else if (std.mem.eql(u8, instruction.detail, "gt") and instruction.typed_span_id.eql(condition_span)) comparison += 1 else return false;
        },
        .target_type => targets += 1,
        .integer_literal_conversion => conversions += 1,
        else => return false,
    };
    return markers == 1 and comparison == 1 and arm_marker == 1 and expressions == 2 and targets == 4 and conversions == 1;
}

fn switchMarker(block: mir.Block) ?mir.Instruction {
    return uniqueInstructionWith(block, .binary, "switch_subject", .branch);
}

fn switchSubjectAt(function: mir.Function, block: mir.Block, span_id: mir.SpanId) bool {
    var found = false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .switch_subject or !fact.typed_span_id.eql(span_id)) continue;
        if (fact.result_ty != .bool or typeRef(function, fact) == null) return false;
        if (found) return false;
        found = true;
    }
    _ = block;
    return found;
}

fn valueAt(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?Value {
    const expression = uniqueInstructionAt(block, .expr, span_id) orelse return null;
    const id = expression.typed_value_id orelse return null;
    const name = valueName(function, id) orelse return null;
    if (!std.mem.eql(u8, expression.detail, name) or !hasParam(function.blocks[0], name) or !span_id.isValid()) return null;
    const fact = expressionFact(function, span_id) orelse return null;
    const ty = typeRef(function, fact) orelse return null;
    if (!sameValueType(expression.result_ty, ty.value_ty)) return null;
    return .{ .name = name, .id = id, .ty = ty, .location = location(function, expression) orelse return null };
}

fn integerAt(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?Integer {
    const expression = uniqueInstructionAt(block, .expr, span_id) orelse return null;
    const value = expression.constant_usize_value orelse return null;
    if (!std.mem.eql(u8, expression.detail, "int") or expression.typed_value_id != null) return null;
    const fact = expressionFact(function, span_id) orelse return null;
    const ty = typeRef(function, fact) orelse return null;
    if (!isSameInteger(ty.value_ty, ty.value_ty) or !hasIntegerFact(function, location(function, expression) orelse return null, value)) return null;
    return .{ .value = value, .ty = ty, .location = location(function, expression) orelse return null };
}

fn expressionFact(function: mir.Function, span_id: mir.SpanId) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .expression_result or !fact.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn hasIntegerFact(function: mir.Function, point: Location, value: usize) bool {
    var found = false;
    for (function.integer_facts) |fact| {
        if (fact.source.line != point.source.line or fact.source.column != point.source.column) continue;
        if ((std.fmt.parseInt(usize, fact.literal, 10) catch return false) != value) return false;
        found = true;
    }
    return found;
}

fn typeRef(function: mir.Function, fact: mir.TargetTypeFact) ?TypeRef {
    if (!fact.typed_result_ty.isValid() or fact.typed_result_ty.index() >= function.type_identities.len) return null;
    const identity = function.type_identities[fact.typed_result_ty.index()];
    if (!identity.id.eql(fact.typed_result_ty) or !std.mem.eql(u8, identity.spelling, fact.result_ty.name())) return null;
    return .{ .id = fact.typed_result_ty, .value_ty = fact.result_ty, .location = .{ .span_id = fact.typed_span_id, .source = fact.source } };
}

fn uniqueInstruction(block: mir.Block, kind: mir.Instruction.Kind) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != kind) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn uniqueInstructionWith(block: mir.Block, kind: mir.Instruction.Kind, detail: []const u8, result_ty: mir.ValueType) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != kind or !std.mem.eql(u8, instruction.detail, detail) or !sameValueType(instruction.result_ty, result_ty)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn uniqueInstructionAt(block: mir.Block, kind: mir.Instruction.Kind, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != kind or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn emptyFallthrough(block: mir.Block) bool {
    return block.typed_id.isValid() and block.instructions.len == 0 and block.successors.len == 0 and block.terminator == .fallthrough;
}

fn emptyJumpTo(block: mir.Block, target: usize) bool {
    return block.typed_id.isValid() and block.instructions.len == 0 and block.successors.len == 1 and block.successors[0] == target and switch (block.terminator) {
        .jump => |actual| actual == target,
        else => false,
    };
}

fn hasParam(block: mir.Block, name: []const u8) bool {
    var found = false;
    for (block.instructions) |instruction| {
        if (instruction.kind != .param or !std.mem.eql(u8, instruction.detail, name)) continue;
        if (found) return false;
        found = true;
    }
    return found;
}

fn effectsAreEmpty(function: mir.Function) bool {
    return function.bounds_facts.len == 0 and function.range_facts.len == 0 and function.pointer_provenance_facts.len == 0 and function.representation_facts.len == 0 and function.access_facts.len == 0 and function.call_target_facts.len == 0 and function.ownership_events.len == 0 and function.ownership_cleanup_plan.actions.len == 0 and function.ownership_cleanup_plan.cancellations.len == 0 and function.cleanup_cfg.edges.len == 0;
}

fn valueName(function: mir.Function, id: mir.ValueId) ?[]const u8 {
    if (!id.isValid() or id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[id.index()];
    return if (identity.id.eql(id)) identity.spelling else null;
}

fn location(function: mir.Function, instruction: mir.Instruction) ?Location {
    if (!instruction.typed_span_id.isValid() or instruction.typed_span_id.index() >= function.span_identities.len) return null;
    const identity = function.span_identities[instruction.typed_span_id.index()];
    return if (identity.id.eql(instruction.typed_span_id)) .{ .span_id = identity.id, .source = identity.source } else null;
}

fn sameType(left: TypeRef, right: TypeRef) bool {
    return left.id.eql(right.id) and sameValueType(left.value_ty, right.value_ty);
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}

fn isSameInteger(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == .integer and sameValueType(left, right);
}

fn sameSource(left: mir.SourcePoint, right: mir.SourcePoint) bool {
    return left.line == right.line and left.column == right.column and left.offset == right.offset and left.len == right.len and left.file_id == right.file_id;
}
