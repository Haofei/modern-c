//! Bounded, syntax-free aggregate execution sequences.
//!
//! This admits two deliberately narrow MIR families: an uninitialized local
//! followed by aggregate/copy assignments and two calls feeding a binary
//! return, and a struct literal return whose fields are direct calls.  Every
//! edge comes from MIR identities/facts; no AST body is consulted.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const Location = struct { span_id: mir.SpanId, source: mir.SourcePoint };
pub const TypeRef = struct { id: mir.TypeId, value_ty: mir.ValueType };
pub const ValueRef = struct { id: mir.ValueId, name: []const u8, location: Location };
pub const Trap = struct {
    block_id: mir.BlockId,
    kind: mir.TrapKind,
    source: mir.TrapSource,
    location: Location,
};

pub const DirectCall = struct {
    callee: ValueRef,
    result: TypeRef,
    location: Location,
    argument: ValueRef,
};

pub const LocalStorage = struct { local: ValueRef, type_ref: TypeRef, initializer: Location };
pub const CopyIndexAssignment = struct {
    target: ValueRef,
    source_root: ValueRef,
    source_location: Location,
    source_type: TypeRef,
    index: usize,
    bound: usize,
    location: Location,
    bounds_trap: Trap,
};
pub const AggregateAssignment = struct {
    target: ValueRef,
    type_ref: TypeRef,
    location: Location,
    field_indices: [2]usize,
    literal_values: [2]usize,
    field_locations: [2]Location,
};
pub const BinaryReturn = struct {
    operation: []const u8,
    location: Location,
    left_call_step: usize,
    right_call_step: usize,
    return_location: Location,
    overflow_trap: Trap,
};

pub const AssignmentStep = union(enum) {
    local_uninit: LocalStorage,
    copy_index_assignment: CopyIndexAssignment,
    aggregate_assignment: AggregateAssignment,
    direct_call: DirectCall,
    binary_return: BinaryReturn,
};

pub const AggregateCallAfterAssignment = struct {
    steps: [7]AssignmentStep,
    count: usize,
};

pub const StructFieldCall = struct {
    field_index: usize,
    location: Location,
    call: DirectCall,
    representation_trap: ?Trap,
};
pub const StructLiteralDirectCalls = struct {
    result: TypeRef,
    location: Location,
    fields: [2]StructFieldCall,
    return_location: Location,
};

pub const Plan = union(enum) {
    aggregate_call_after_assignment: AggregateCallAfterAssignment,
    struct_literal_direct_calls: StructLiteralDirectCalls,
};

pub fn build(function: *const mir.Function) ?Plan {
    const entry = straightLineEntry(function) orelse return null;
    if (buildAssignmentSequence(function, entry)) |plan| return plan;
    if (buildStructLiteralCalls(function, entry)) |plan| return plan;
    return null;
}

fn buildAssignmentSequence(function: *const mir.Function, entry: mir.Block) ?Plan {
    if (function.trap_edges.len != 2) return null;
    var locals: [2]mir.Instruction = undefined;
    var assignments: [2]mir.Instruction = undefined;
    var calls: [2]mir.Instruction = undefined;
    var local_count: usize = 0;
    var assignment_count: usize = 0;
    var call_count: usize = 0;
    var binary: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .local => {
            if (local_count == locals.len) return null;
            locals[local_count] = instruction;
            local_count += 1;
        },
        .assign => {
            if (assignment_count == assignments.len) return null;
            assignments[assignment_count] = instruction;
            assignment_count += 1;
        },
        .call => {
            if (call_count == calls.len) return null;
            calls[call_count] = instruction;
            call_count += 1;
        },
        .binary => {
            if (binary != null) return null;
            binary = instruction;
        },
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        .param, .target_type, .expr, .index, .cmp_bounds, .integer_literal_conversion, .conversion_check, .assignment_check, .add_overflow => {},
        else => return null,
    };
    if (local_count != 2 or assignment_count != 2 or call_count != 2) return null;
    const row = localUninit(function, entry, locals[0]) orelse return null;
    const pair = localUninit(function, entry, locals[1]) orelse return null;
    const copy = copyIndexAssignment(function, entry, assignments[0], row.local) orelse return null;
    const aggregate = aggregateAssignment(function, entry, assignments[1], pair.local) orelse return null;
    const left = directCall(function, entry, calls[0]) orelse return null;
    const right = directCall(function, entry, calls[1]) orelse return null;
    const return_plan = binaryReturn(function, binary orelse return null, returned orelse return null, calls[0], calls[1]) orelse return null;
    return .{ .aggregate_call_after_assignment = .{ .steps = .{
        .{ .local_uninit = row },
        .{ .copy_index_assignment = copy },
        .{ .local_uninit = pair },
        .{ .aggregate_assignment = aggregate },
        .{ .direct_call = left },
        .{ .direct_call = right },
        .{ .binary_return = return_plan },
    }, .count = 7 } };
}

fn buildStructLiteralCalls(function: *const mir.Function, entry: mir.Block) ?Plan {
    const returned = uniqueInstruction(entry, .return_value) orelse return null;
    const literal = instructionOfKindAtSpan(entry, returned.typed_value_operand_span_id, .expr) orelse return null;
    const aggregate_type = aggregateConstructionAtSpan(entry, literal.typed_span_id) orelse return null;
    if (aggregate_type.aggregate_construction != .declared_struct or literal.typed_aggregate_operand_count != 2) return null;
    const result = typeRef(function, aggregate_type.typed_result_ty, aggregate_type.result_ty) orelse return null;
    var fields: [2]StructFieldCall = undefined;
    var trap_count: usize = 0;
    for (0..2) |index| {
        const span = literal.typed_aggregate_operand_span_ids[index];
        const field_index = literal.typed_aggregate_field_indices[index];
        if (!span.isValid() or field_index != index) return null;
        const call = instructionOfKindAtSpan(entry, span, .call) orelse return null;
        const representation_trap = trapFor(function, entry, span, .InvalidRepresentation, .representation_check);
        if (representation_trap != null) trap_count += 1;
        fields[index] = .{ .field_index = field_index, .location = location(function, span) orelse return null, .call = directCall(function, entry, call) orelse return null, .representation_trap = representation_trap };
    }
    if (trap_count != function.trap_edges.len) return null;
    if (!returned.typed_value_operand_span_id.eql(literal.typed_span_id)) return null;
    return .{ .struct_literal_direct_calls = .{
        .result = result,
        .location = location(function, literal.typed_span_id) orelse return null,
        .fields = fields,
        .return_location = location(function, returned.typed_span_id) orelse return null,
    } };
}

fn localUninit(function: *const mir.Function, entry: mir.Block, instruction: mir.Instruction) ?LocalStorage {
    const local = valueRef(function, instruction.typed_value_id orelse return null, instruction.typed_span_id) orelse return null;
    const initializer = instruction.typed_value_operand_span_id;
    const value = instructionOfKindAtSpan(entry, initializer, .expr) orelse return null;
    if (!std.mem.eql(u8, value.detail, "uninit")) return null;
    return .{ .local = local, .type_ref = typeRef(function, instruction.typed_result_ty, instruction.result_ty) orelse return null, .initializer = location(function, initializer) orelse return null };
}

fn copyIndexAssignment(function: *const mir.Function, entry: mir.Block, instruction: mir.Instruction, expected_target: ValueRef) ?CopyIndexAssignment {
    const target = valueAtSpan(function, entry, instruction.typed_target_operand_span_id) orelse return null;
    if (!target.id.eql(expected_target.id)) return null;
    const indexed = instructionOfKindAtSpan(entry, instruction.typed_value_operand_span_id, .index) orelse return null;
    if (indexed.constant_index_value == null or indexed.static_index_bound == null) return null;
    const root = valueAtSpan(function, entry, indexed.typed_base_operand_span_id) orelse return null;
    return .{ .target = target, .source_root = root, .source_location = location(function, indexed.typed_span_id) orelse return null, .source_type = typeRef(function, indexed.typed_result_ty, indexed.result_ty) orelse return null, .index = indexed.constant_index_value.?, .bound = indexed.static_index_bound.?, .location = location(function, instruction.typed_span_id) orelse return null, .bounds_trap = trapFor(function, entry, indexed.typed_span_id, .Bounds, .bounds_check) orelse return null };
}

fn aggregateAssignment(function: *const mir.Function, entry: mir.Block, instruction: mir.Instruction, expected_target: ValueRef) ?AggregateAssignment {
    const target = valueAtSpan(function, entry, instruction.typed_target_operand_span_id) orelse return null;
    if (!target.id.eql(expected_target.id)) return null;
    const literal = instructionOfKindAtSpan(entry, instruction.typed_value_operand_span_id, .expr) orelse return null;
    const aggregate_type = aggregateConstructionAtSpan(entry, literal.typed_span_id) orelse return null;
    if (aggregate_type.aggregate_construction != .declared_struct or literal.typed_aggregate_operand_count != 2) return null;
    var result: AggregateAssignment = .{ .target = target, .type_ref = typeRef(function, aggregate_type.typed_result_ty, aggregate_type.result_ty) orelse return null, .location = location(function, instruction.typed_span_id) orelse return null, .field_indices = undefined, .literal_values = undefined, .field_locations = undefined };
    for (0..2) |index| {
        const span = literal.typed_aggregate_operand_span_ids[index];
        const value = instructionOfKindAtSpan(entry, span, .expr) orelse return null;
        if (literal.typed_aggregate_field_indices[index] != index or value.constant_usize_value == null) return null;
        result.field_indices[index] = index;
        result.literal_values[index] = value.constant_usize_value.?;
        result.field_locations[index] = location(function, span) orelse return null;
    }
    return result;
}

fn directCall(function: *const mir.Function, entry: mir.Block, instruction: mir.Instruction) ?DirectCall {
    const callee_id = instruction.typed_value_id orelse return null;
    if (!instruction.typed_callee_span_id.isValid()) return null;
    const result_fact = uniqueDirectResult(function, instruction.typed_callee_span_id, instruction.detail) orelse return null;
    if (!sameType(result_fact.result_ty, instruction.result_ty)) return null;
    const argument_fact = uniqueDirectArgument(function, instruction.typed_callee_span_id, 0) orelse return null;
    if (countDirectArguments(function, instruction.typed_callee_span_id) != 1) return null;
    const argument = valueAtSpan(function, entry, argument_fact.typed_span_id) orelse return null;
    if (!argument.id.eql(argument_fact.typed_operand_value_id)) return null;
    return .{ .callee = valueRef(function, callee_id, instruction.typed_span_id) orelse return null, .result = typeRef(function, result_fact.typed_result_ty, result_fact.result_ty) orelse return null, .location = location(function, instruction.typed_span_id) orelse return null, .argument = argument };
}

fn binaryReturn(function: *const mir.Function, binary: mir.Instruction, returned: mir.Instruction, left: mir.Instruction, right: mir.Instruction) ?BinaryReturn {
    if (!binary.typed_left_operand_span_id.eql(left.typed_span_id) or !binary.typed_right_operand_span_id.eql(right.typed_span_id)) return null;
    if (!returned.typed_value_operand_span_id.eql(binary.typed_span_id)) return null;
    const overflow = instructionOfKindAtSpan(function.blocks[0], binary.typed_span_id, .add_overflow) orelse return null;
    if (!std.mem.eql(u8, overflow.detail, binary.detail)) return null;
    return .{ .operation = binary.detail, .location = location(function, binary.typed_span_id) orelse return null, .left_call_step = 4, .right_call_step = 5, .return_location = location(function, returned.typed_span_id) orelse return null, .overflow_trap = trapFor(function, function.blocks[0], binary.typed_span_id, .IntegerOverflow, .checked_arithmetic) orelse return null };
}

fn straightLineEntry(function: *const mir.Function) ?mir.Block {
    if (function.blocks.len == 0) return null;
    const entry = function.blocks[0];
    if (!entry.typed_id.isValid() or entry.terminator != .return_) return null;
    for (entry.successors) |successor| {
        var trap = false;
        for (function.trap_edges) |edge| {
            if (edge.from_block == 0 and edge.trap_block == successor) trap = true;
        }
        if (!trap) return null;
    }
    return entry;
}

fn trapFor(function: *const mir.Function, from: mir.Block, span: mir.SpanId, kind: mir.TrapKind, source: mir.TrapSource) ?Trap {
    var found: ?Trap = null;
    for (function.trap_edges) |edge| {
        if (edge.from_block != from.id or !edge.typed_span_id.eql(span)) continue;
        if (edge.kind != kind or edge.source != source or edge.trap_block >= function.blocks.len or found != null) return null;
        const block = function.blocks[edge.trap_block];
        if (!block.typed_id.isValid() or block.terminator != .trap_ or block.instructions.len != 0 or block.successors.len != 0) return null;
        found = .{ .block_id = block.typed_id, .kind = kind, .source = source, .location = location(function, span) orelse return null };
    }
    return found;
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
fn instructionOfKindAtSpan(block: mir.Block, span: mir.SpanId, kind: mir.Instruction.Kind) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != kind or !instruction.typed_span_id.eql(span)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}
fn aggregateConstructionAtSpan(block: mir.Block, span: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .target_type or !instruction.typed_span_id.eql(span) or instruction.aggregate_construction == null) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}
fn uniqueDirectResult(function: *const mir.Function, span: mir.SpanId, owner: []const u8) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_result or !fact.typed_span_id.eql(span)) continue;
        if (fact.target_owner == null or !std.mem.eql(u8, fact.target_owner.?, owner) or found != null) return null;
        found = fact;
    }
    return found;
}
fn uniqueDirectArgument(function: *const mir.Function, callee: mir.SpanId, index: usize) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_argument or !fact.typed_callee_span_id.eql(callee) or fact.target_index != index) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}
fn countDirectArguments(function: *const mir.Function, callee: mir.SpanId) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.kind == .direct_call_argument and fact.typed_callee_span_id.eql(callee)) count += 1;
    }
    return count;
}
fn valueAtSpan(function: *const mir.Function, block: mir.Block, span: mir.SpanId) ?ValueRef {
    const instruction = instructionOfKindAtSpan(block, span, .expr) orelse return null;
    return valueRef(function, instruction.typed_value_id orelse return null, span);
}
fn valueRef(function: *const mir.Function, id: mir.ValueId, span: mir.SpanId) ?ValueRef {
    if (!id.isValid() or id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[id.index()];
    if (!identity.id.eql(id)) return null;
    return .{ .id = id, .name = identity.spelling, .location = location(function, span) orelse return null };
}
fn typeRef(function: *const mir.Function, id: mir.TypeId, value_ty: mir.ValueType) ?TypeRef {
    if (!id.isValid() or id.index() >= function.type_identities.len) return null;
    const identity = function.type_identities[id.index()];
    if (!identity.id.eql(id) or !std.mem.eql(u8, identity.spelling, value_ty.name())) return null;
    return .{ .id = id, .value_ty = value_ty };
}
fn location(function: *const mir.Function, span: mir.SpanId) ?Location {
    if (!span.isValid() or span.index() >= function.span_identities.len) return null;
    const identity = function.span_identities[span.index()];
    return if (identity.id.eql(span)) .{ .span_id = span, .source = identity.source } else null;
}
fn sameType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}
