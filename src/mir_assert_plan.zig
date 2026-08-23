//! Shared, syntax-free lowering plan for a single assertion expression.
//!
//! The plan deliberately admits only leaf parameters/integer literals, direct
//! zero-argument calls, and boolean/comparison trees.  Calls below a logical
//! short-circuit node are rejected: materializing them eagerly would change the
//! source program's evaluation semantics.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const max_nodes = 16;

pub const Location = struct {
    span_id: mir.SpanId,
    source: mir.SourcePoint,
};

pub const Binary = enum { logical_and, logical_or, eq, ne };

pub const Node = struct {
    location: Location,
    type_fact: mir.TargetTypeFact,
    operation: union(enum) {
        parameter: struct { name: []const u8, value_id: mir.ValueId },
        integer_literal: []const u8,
        direct_zero_arg_call: struct {
            callee_name: []const u8,
            callee_id: mir.SymbolId,
            result_fact: mir.TargetTypeFact,
        },
        binary: struct { op: Binary, left: usize, right: usize },
    },
};

pub const Plan = struct {
    nodes: [max_nodes]Node = undefined,
    count: usize = 0,
    root: usize = 0,
    assert_location: Location,
};

pub fn build(function: mir.Function) ?Plan {
    if (function.blocks.len != 2 or function.trap_edges.len != 1 or function.return_ty != .void) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const edge = function.trap_edges[0];
    if (edge.from_block != 0 or edge.trap_block != 1 or edge.kind != .Assert or edge.source != .assert_stmt or !edge.typed_span_id.isValid()) return null;
    const entry = function.blocks[0];
    const trap = function.blocks[1];
    if (entry.terminator != .fallthrough or entry.successors.len != 1 or entry.successors[0] != 1 or
        trap.instructions.len != 0 or trap.successors.len != 0 or trap.terminator != .trap_)
        return null;
    switch (trap.terminator) {
        .trap_ => |kind| if (kind != .Assert) return null,
        else => return null,
    }

    var assert_count: usize = 0;
    for (entry.instructions) |instruction| {
        if (instruction.kind == .assert_condition) assert_count += 1;
    }
    if (assert_count != 1) return null;
    const condition_fact = targetFactByKind(function, .assert_condition) orelse return null;
    if (condition_fact.result_ty != .bool or !condition_fact.typed_span_id.isValid()) return null;

    var plan: Plan = .{ .assert_location = .{ .span_id = edge.typed_span_id, .source = .{ .line = edge.line, .column = edge.column, .offset = edge.source_offset, .len = edge.source_len } } };
    plan.root = appendExpression(function, entry, condition_fact.typed_span_id, false, &plan, 0) orelse return null;
    if (plan.nodes[plan.root].type_fact.result_ty != .bool) return null;

    // Every executable operation must have been consumed by the tree. This
    // prevents a discarded call or a sibling expression from being silently
    // dropped while still admitting the assertion.
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param, .assert_condition, .target_type, .integer_literal_conversion, .expr => {},
        .binary, .call => if (!planHasNodeAt(plan, instruction.typed_span_id)) return null,
        else => return null,
    };
    return plan;
}

fn appendExpression(function: mir.Function, block: mir.Block, span_id: mir.SpanId, inside_logical: bool, plan: *Plan, depth: usize) ?usize {
    if (!span_id.isValid() or depth >= max_nodes or plan.count >= max_nodes) return null;
    for (plan.nodes[0..plan.count], 0..) |node, index| if (node.location.span_id.eql(span_id)) return index;
    const type_fact = targetFactBySpan(function, .expression_result, span_id) orelse return null;
    const instruction = expressionInstructionAt(function, block, span_id) orelse return null;
    const index = plan.count;
    plan.count += 1;
    plan.nodes[index] = .{ .location = .{ .span_id = span_id, .source = instructionSource(instruction) }, .type_fact = type_fact, .operation = undefined };
    switch (instruction.kind) {
        .binary => {
            const op: Binary = if (std.mem.eql(u8, instruction.detail, "logical_and")) .logical_and else if (std.mem.eql(u8, instruction.detail, "logical_or")) .logical_or else if (std.mem.eql(u8, instruction.detail, "eq")) .eq else if (std.mem.eql(u8, instruction.detail, "ne")) .ne else return null;
            if (!instruction.typed_left_operand_span_id.isValid() or !instruction.typed_right_operand_span_id.isValid()) return null;
            const logical = op == .logical_and or op == .logical_or;
            const left = appendExpression(function, block, instruction.typed_left_operand_span_id, inside_logical or logical, plan, depth + 1) orelse return null;
            const right = appendExpression(function, block, instruction.typed_right_operand_span_id, inside_logical or logical, plan, depth + 1) orelse return null;
            if (logical) {
                if (type_fact.result_ty != .bool or plan.nodes[left].type_fact.result_ty != .bool or plan.nodes[right].type_fact.result_ty != .bool) return null;
            } else {
                if (type_fact.result_ty != .bool or std.meta.activeTag(plan.nodes[left].type_fact.result_ty) != .integer or !sameValueType(plan.nodes[left].type_fact.result_ty, plan.nodes[right].type_fact.result_ty)) return null;
            }
            plan.nodes[index].operation = .{ .binary = .{ .op = op, .left = left, .right = right } };
        },
        .call => {
            if (inside_logical or !instruction.typed_callee_span_id.isValid()) return null;
            const result = targetFactBySpan(function, .direct_call_result, instruction.typed_callee_span_id) orelse return null;
            const callee_name = result.target_owner orelse return null;
            const callee_id = result.typed_target_owner_id;
            if (!callee_id.isValid() or !sameValueType(result.result_ty, type_fact.result_ty) or callHasArguments(function, instruction.typed_callee_span_id)) return null;
            plan.nodes[index].operation = .{ .direct_zero_arg_call = .{ .callee_name = callee_name, .callee_id = callee_id, .result_fact = result } };
        },
        .expr => {
            if (instruction.typed_value_id) |value_id| {
                const name = valueIdentityName(function, value_id) orelse return null;
                if (!std.mem.eql(u8, name, instruction.detail)) return null;
                plan.nodes[index].operation = .{ .parameter = .{ .name = name, .value_id = value_id } };
            } else if (std.mem.eql(u8, instruction.detail, "int")) {
                const literal = integerLiteralAt(function, instructionSource(instruction)) orelse return null;
                plan.nodes[index].operation = .{ .integer_literal = literal };
            } else return null;
        },
        else => return null,
    }
    return index;
}

fn expressionInstructionAt(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .binary and instruction.kind != .call and instruction.kind != .expr) continue;
        if (!spanExists(function, span_id) or !instruction.typed_span_id.isValid() or !instruction.typed_span_id.eql(span_id)) continue;
        // The callee marker has its own span and must not compete with the call
        // expression. Prefer the value-producing call at the enclosing span.
        if (instruction.kind == .expr and found != null) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn targetFactByKind(function: mir.Function, kind: mir.TargetTypeKind) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn targetFactBySpan(function: mir.Function, kind: mir.TargetTypeKind, span_id: mir.SpanId) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or !spanExists(function, span_id) or !fact.typed_span_id.isValid() or !fact.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn callHasArguments(function: mir.Function, callee_span_id: mir.SpanId) bool {
    for (function.target_type_facts) |fact| {
        if (fact.kind == .direct_call_argument and fact.typed_callee_span_id.isValid() and fact.typed_callee_span_id.eql(callee_span_id)) return true;
    }
    return false;
}

fn integerLiteralAt(function: mir.Function, source: mir.SourcePoint) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (function.integer_facts) |fact| {
        if (!sameSource(fact.source, source)) continue;
        if (found != null) return null;
        found = fact.literal;
    }
    return found;
}

fn valueIdentityName(function: mir.Function, value_id: mir.ValueId) ?[]const u8 {
    if (!value_id.isValid() or value_id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[value_id.index()];
    return if (identity.id.eql(value_id)) identity.spelling else null;
}

fn spanExists(function: mir.Function, span_id: mir.SpanId) bool {
    if (!span_id.isValid() or span_id.index() >= function.span_identities.len) return false;
    return function.span_identities[span_id.index()].id.eql(span_id);
}

fn planHasNodeAt(plan: Plan, span_id: mir.SpanId) bool {
    for (plan.nodes[0..plan.count]) |node| if (node.location.span_id.eql(span_id)) return true;
    return false;
}

fn instructionSource(instruction: mir.Instruction) mir.SourcePoint {
    return .{ .line = instruction.line, .column = instruction.column, .offset = instruction.source_offset, .len = instruction.source_len };
}

fn sameSource(left: mir.SourcePoint, right: mir.SourcePoint) bool {
    // Literal facts intentionally carry only source line/column today; the
    // expression node's opaque SpanId still owns exact identity for the plan.
    return left.line == right.line and left.column == right.column;
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}
