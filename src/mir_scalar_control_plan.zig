//! Syntax-free, fail-closed scalar CFG plans.
//!
//! These plans intentionally cover only a local integer initialized from a
//! parameter, then updated through checked `+/- 1` control flow.  They retain
//! block, span, value, generation, and overflow-trap identities so consumers
//! never need to reopen a function body.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const Location = struct {
    span_id: mir.SpanId,
    source: mir.SourcePoint,
};

pub const Scalar = struct {
    name: []const u8,
    value_id: mir.ValueId,
    value_ty: mir.ValueType,
    location: Location,
};

pub const Local = struct {
    name: []const u8,
    value_id: mir.ValueId,
    value_ty: mir.ValueType,
    generation: u32,
    declaration: Location,
    initializer: Scalar,
};

pub const CheckedUpdate = struct {
    pub const Operation = enum { add, sub };

    operation: Operation,
    block_id: mir.BlockId,
    assignment: Location,
    operation_location: Location,
    literal_location: Location,
    trap_block: mir.BlockId,
    trap_location: Location,
    generation: u32,
};

const TypeFactRef = struct {
    value_ty: mir.ValueType,
    location: Location,
};

pub const Conditional = struct {
    local: Local,
    condition: Scalar,
    true_update: CheckedUpdate,
    false_update: ?CheckedUpdate,
    false_block: mir.BlockId,
    return_location: Location,
};

pub const CountDown = struct {
    local: Local,
    condition_location: Location,
    condition_zero_location: Location,
    body_block: mir.BlockId,
    after_block: mir.BlockId,
    update: CheckedUpdate,
    return_location: Location,
};

pub const Plan = union(enum) {
    conditional: Conditional,
    count_down: CountDown,
};

/// Return a plan only when every CFG edge, typed identity, local generation,
/// and checked-overflow trap is the exact bounded shape described above.
pub fn build(function: *const mir.Function) ?Plan {
    if (!effectsAreLimitedToCheckedOverflow(function) or !isInteger(function.return_ty) or function.blocks.len < 4) return null;
    return switch (function.blocks[0].terminator) {
        .switch_ => buildConditional(function),
        .branch => buildCountDown(function),
        else => null,
    };
}

fn buildConditional(function: *const mir.Function) ?Plan {
    if (function.blocks.len != 5 and function.blocks.len != 6) return null;
    const entry = function.blocks[0];
    const after = function.blocks[1];
    if (!entry.typed_id.isValid() or !after.typed_id.isValid() or entry.successors.len != 2) return null;
    const local = localInEntry(function, entry) orelse return null;
    const condition = boolSwitchCondition(function, entry) orelse return null;
    const returned = returnOfLocal(function, after, local) orelse return null;
    const true_block = function.blocks[entry.successors[0]];
    const false_block = function.blocks[entry.successors[1]];
    const true_update = checkedUpdate(function, true_block, after, local) orelse return null;
    if (!updateBranchesToAfter(true_block, after, true_update)) return null;
    const false_update = if (checkedUpdate(function, false_block, after, local)) |update|
        update
    else if (emptySwitchArm(function, false_block, after))
        null
    else
        return null;
    if (false_update) |update| if (!updateBranchesToAfter(false_block, after, update)) return null;
    const expected_traps: usize = if (false_update == null) 1 else 2;
    if (function.trap_edges.len != expected_traps) return null;
    var updates: [2]CheckedUpdate = undefined;
    updates[0] = true_update;
    const update_count: usize = if (false_update) |update| blk: {
        updates[1] = update;
        break :blk 2;
    } else 1;
    if (!localGenerationsMatch(function, local, updates[0..update_count])) return null;
    return .{ .conditional = .{
        .local = local,
        .condition = condition,
        .true_update = true_update,
        .false_update = false_update,
        .false_block = false_block.typed_id,
        .return_location = returned,
    } };
}

fn buildCountDown(function: *const mir.Function) ?Plan {
    if (function.blocks.len != 4) return null;
    const entry = function.blocks[0];
    const branch = switch (entry.terminator) {
        .branch => |value| value,
        else => return null,
    };
    if (!entry.typed_id.isValid() or entry.successors.len != 2 or entry.successors[0] != branch.true_block or entry.successors[1] != branch.false_block) return null;
    if (branch.true_block >= function.blocks.len or branch.false_block >= function.blocks.len) return null;
    const body = function.blocks[branch.true_block];
    const after = function.blocks[branch.false_block];
    if (!body.typed_id.isValid() or !after.typed_id.isValid()) return null;
    const local = localInEntry(function, entry) orelse return null;
    const condition = whileNotZeroCondition(function, entry, local) orelse return null;
    const update = checkedUpdate(function, body, after, local) orelse return null;
    if (update.operation != .sub or body.successors.len != 2 or body.successors[0] != update.trap_block.index() or body.successors[1] != body.id or !isJumpTo(body.terminator, body.id)) return null;
    const returned = returnOfLocal(function, after, local) orelse return null;
    if (function.trap_edges.len != 1 or !localGenerationsMatch(function, local, &.{update})) return null;
    return .{ .count_down = .{
        .local = local,
        .condition_location = condition.operation,
        .condition_zero_location = condition.zero,
        .body_block = body.typed_id,
        .after_block = after.typed_id,
        .update = update,
        .return_location = returned,
    } };
}

fn effectsAreLimitedToCheckedOverflow(function: *const mir.Function) bool {
    if (function.bounds_facts.len != 0 or function.range_facts.len != 0 or function.pointer_provenance_facts.len != 0 or
        function.representation_facts.len != 0 or function.access_facts.len != 0 or function.call_target_facts.len != 0 or
        function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return false;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return false;
    return true;
}

fn localInEntry(function: *const mir.Function, entry: mir.Block) ?Local {
    var local_instruction: ?mir.Instruction = null;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .expr, .binary, .integer_literal_conversion => {},
        .local => {
            if (local_instruction != null) return null;
            local_instruction = instruction;
        },
        else => return null,
    };
    const local = local_instruction orelse return null;
    const local_id = local.typed_value_id orelse return null;
    const initial_span = local.typed_value_operand_span_id;
    if (!local_id.isValid() or !initial_span.isValid() or local.typed_target_operand_span_id.isValid() or !isInteger(local.result_ty)) return null;
    const initializer_instruction = expressionAt(entry, initial_span) orelse return null;
    const initializer_id = initializer_instruction.typed_value_id orelse return null;
    const initializer_name = valueName(function, initializer_id) orelse return null;
    if (!initializer_id.isValid() or !isInteger(initializer_instruction.result_ty) or !sameType(local.result_ty, initializer_instruction.result_ty) or !hasParameter(entry, initializer_name)) return null;
    const declaration = location(function, local) orelse return null;
    const initializer_location = location(function, initializer_instruction) orelse return null;
    const generation = localGeneration(function, local_id, .init, entry.typed_id, initializer_location) orelse return null;
    if ((localGeneration(function, local_id, .storage_live, entry.typed_id, declaration) orelse return null) != generation) return null;
    return .{
        .name = local.detail,
        .value_id = local_id,
        .value_ty = local.result_ty,
        .generation = generation,
        .declaration = declaration,
        .initializer = .{
            .name = initializer_name,
            .value_id = initializer_id,
            .value_ty = initializer_instruction.result_ty,
            .location = initializer_location,
        },
    };
}

fn boolSwitchCondition(function: *const mir.Function, entry: mir.Block) ?Scalar {
    const marker = uniqueInstruction(entry, .binary) orelse return null;
    if (marker.result_ty != .branch or !std.mem.eql(u8, marker.detail, "switch_subject")) return null;
    const fact = uniqueTypeFactInBlock(function, entry, .switch_subject) orelse return null;
    if (fact.value_ty != .bool) return null;
    const expression = expressionAt(entry, fact.location.span_id) orelse return null;
    const value_id = expression.typed_value_id orelse return null;
    const name = valueName(function, value_id) orelse return null;
    if (!value_id.isValid() or expression.result_ty != .bool or !hasParameter(entry, name)) return null;
    return .{ .name = name, .value_id = value_id, .value_ty = .bool, .location = fact.location };
}

const WhileCondition = struct { operation: Location, zero: Location };

fn whileNotZeroCondition(function: *const mir.Function, entry: mir.Block, local: Local) ?WhileCondition {
    var marker: ?mir.Instruction = null;
    var comparison: ?mir.Instruction = null;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .binary => {
            if (std.mem.eql(u8, instruction.detail, "while")) {
                if (marker != null or instruction.result_ty != .branch) return null;
                marker = instruction;
            } else if (std.mem.eql(u8, instruction.detail, "ne")) {
                if (comparison != null) return null;
                comparison = instruction;
            } else return null;
        },
        else => {},
    };
    if (marker == null) return null;
    const operation = comparison orelse return null;
    const fact = uniqueTypeFactInBlock(function, entry, .loop_condition) orelse return null;
    if (fact.value_ty != .bool or !operation.typed_left_operand_span_id.isValid() or !operation.typed_right_operand_span_id.isValid()) return null;
    const left = expressionAt(entry, operation.typed_left_operand_span_id) orelse return null;
    const right = expressionAt(entry, operation.typed_right_operand_span_id) orelse return null;
    if (!expressionIsValue(left, local) or !literalAt(right, 0) or !sameType(left.result_ty, local.value_ty)) return null;
    return .{ .operation = location(function, operation) orelse return null, .zero = location(function, right) orelse return null };
}

fn checkedUpdate(function: *const mir.Function, block: mir.Block, after: mir.Block, local: Local) ?CheckedUpdate {
    _ = after;
    if (!block.typed_id.isValid() or block.successors.len != 2) return null;
    var assignment: ?mir.Instruction = null;
    var operation: ?mir.Instruction = null;
    var overflow: ?mir.Instruction = null;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .expr => {},
        .assign => {
            if (assignment != null) return null;
            assignment = instruction;
        },
        .binary => {
            if (operation != null or (!std.mem.eql(u8, instruction.detail, "add") and !std.mem.eql(u8, instruction.detail, "sub"))) return null;
            operation = instruction;
        },
        .add_overflow => {
            if (overflow != null) return null;
            overflow = instruction;
        },
        .target_type, .integer_literal_conversion => {},
        else => return null,
    };
    const store = assignment orelse return null;
    const binary = operation orelse return null;
    const check = overflow orelse return null;
    if (!store.typed_target_operand_span_id.isValid() or !store.typed_value_operand_span_id.eql(binary.typed_span_id) or
        !binary.typed_left_operand_span_id.isValid() or !binary.typed_right_operand_span_id.isValid() or
        !check.typed_span_id.eql(binary.typed_span_id) or !sameType(store.result_ty, local.value_ty) or !sameType(binary.result_ty, .value)) return null;
    const target = expressionAt(block, store.typed_target_operand_span_id) orelse return null;
    const left = expressionAt(block, binary.typed_left_operand_span_id) orelse return null;
    const right = expressionAt(block, binary.typed_right_operand_span_id) orelse return null;
    if (!expressionIsValue(target, local) or !expressionIsValue(left, local) or !literalAt(right, 1) or !sameType(left.result_ty, local.value_ty)) return null;
    const trap = overflowTrap(function, block, binary) orelse return null;
    const operation_location = location(function, binary) orelse return null;
    const generation = localGeneration(function, local.value_id, .reinit, block.typed_id, operation_location) orelse return null;
    return .{
        .operation = if (std.mem.eql(u8, binary.detail, "add")) .add else .sub,
        .block_id = block.typed_id,
        .assignment = location(function, store) orelse return null,
        .operation_location = operation_location,
        .literal_location = location(function, right) orelse return null,
        .trap_block = trap.block,
        .trap_location = trap.location,
        .generation = generation,
    };
}

fn updateBranchesToAfter(block: mir.Block, after: mir.Block, update: CheckedUpdate) bool {
    return block.successors[0] == update.trap_block.index() and block.successors[1] == after.id and isJumpTo(block.terminator, after.id);
}

fn emptySwitchArm(function: *const mir.Function, block: mir.Block, after: mir.Block) bool {
    if (!block.typed_id.isValid() or block.successors.len != 1 or block.successors[0] != after.id or !isJumpTo(block.terminator, after.id)) return false;
    const marker = uniqueInstruction(block, .expr) orelse return false;
    return marker.result_ty == .branch and std.mem.eql(u8, marker.detail, "literal") and location(function, marker) != null;
}

fn returnOfLocal(function: *const mir.Function, block: mir.Block, local: Local) ?Location {
    if (!block.typed_id.isValid() or block.successors.len != 0 or !isReturn(block.terminator)) return null;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .target_type, .expr, .return_value => {},
        else => return null,
    };
    const returned = uniqueInstruction(block, .return_value) orelse return null;
    if (!returned.typed_value_operand_span_id.isValid() or !sameType(returned.result_ty, local.value_ty) or !sameType(returned.result_ty, function.return_ty)) return null;
    const expression = expressionAt(block, returned.typed_value_operand_span_id) orelse return null;
    if (!expressionIsValue(expression, local)) return null;
    return location(function, returned);
}

const Trap = struct { block: mir.BlockId, location: Location };

fn overflowTrap(function: *const mir.Function, from: mir.Block, operation: mir.Instruction) ?Trap {
    var found: ?Trap = null;
    for (function.trap_edges) |edge| {
        if (edge.from_block != from.id) continue;
        if (edge.kind != .IntegerOverflow or edge.source != .checked_arithmetic or !edge.typed_span_id.eql(operation.typed_span_id) or edge.trap_block >= function.blocks.len) return null;
        const trap_block = function.blocks[edge.trap_block];
        if (!trap_block.typed_id.isValid() or !isOverflowTrap(trap_block.terminator) or trap_block.instructions.len != 0 or trap_block.successors.len != 0 or found != null) return null;
        found = .{ .block = trap_block.typed_id, .location = locationForSpan(function, edge.typed_span_id) orelse return null };
    }
    return found;
}

fn localGenerationsMatch(function: *const mir.Function, local: Local, updates: []const CheckedUpdate) bool {
    var storage_live: usize = 0;
    var initialized: usize = 0;
    var reinitialized: usize = 0;
    for (function.ownership_events) |event| {
        if (!event.place.root_value_id.eql(local.value_id) or event.place.projection_count != 0) return false;
        switch (event.kind) {
            .storage_live => {
                if (event.block_id.eql(function.blocks[0].typed_id) and event.generation == local.generation) storage_live += 1 else return false;
            },
            .init => {
                if (event.block_id.eql(function.blocks[0].typed_id) and event.generation == local.generation) initialized += 1 else return false;
            },
            .reinit => {
                var matches = false;
                for (updates) |update| {
                    if (event.block_id.eql(update.block_id) and event.generation == update.generation) matches = true;
                }
                if (!matches) return false;
                reinitialized += 1;
            },
            else => return false,
        }
    }
    return storage_live == 1 and initialized == 1 and reinitialized == updates.len;
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

fn expressionAt(block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .expr or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn expressionIsValue(instruction: mir.Instruction, value: Local) bool {
    return instruction.kind == .expr and instruction.typed_value_id != null and instruction.typed_value_id.?.eql(value.value_id) and
        std.mem.eql(u8, instruction.detail, value.name) and sameType(instruction.result_ty, value.value_ty);
}

fn literalAt(instruction: mir.Instruction, value: usize) bool {
    return instruction.kind == .expr and instruction.typed_value_id == null and instruction.constant_usize_value == value and
        std.mem.eql(u8, instruction.detail, "int");
}

fn uniqueTypeFact(function: *const mir.Function, kind: mir.TargetTypeKind, span_id: mir.SpanId) ?TypeFactRef {
    var found: ?TypeFactRef = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or !fact.typed_span_id.eql(span_id) or !fact.typed_result_ty.isValid()) continue;
        if (fact.typed_result_ty.index() >= function.type_identities.len or fact.typed_span_id.index() >= function.span_identities.len or found != null) return null;
        const ty = function.type_identities[fact.typed_result_ty.index()];
        const span = function.span_identities[fact.typed_span_id.index()];
        if (!ty.id.eql(fact.typed_result_ty) or !std.mem.eql(u8, ty.spelling, fact.result_ty.name()) or !span.id.eql(fact.typed_span_id) or !sourceEquivalent(span.source, fact.source)) return null;
        found = .{ .value_ty = fact.result_ty, .location = .{ .span_id = fact.typed_span_id, .source = fact.source } };
    }
    return found;
}

fn uniqueTypeFactInBlock(function: *const mir.Function, block: mir.Block, kind: mir.TargetTypeKind) ?TypeFactRef {
    var found: ?TypeFactRef = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .target_type or !std.mem.eql(u8, instruction.detail, @tagName(kind))) continue;
        const fact = uniqueTypeFact(function, kind, instruction.typed_span_id) orelse return null;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn location(function: *const mir.Function, instruction: mir.Instruction) ?Location {
    return locationForSpan(function, instruction.typed_span_id);
}

fn locationForSpan(function: *const mir.Function, span_id: mir.SpanId) ?Location {
    if (!span_id.isValid() or span_id.index() >= function.span_identities.len) return null;
    const identity = function.span_identities[span_id.index()];
    if (!identity.id.eql(span_id)) return null;
    return .{ .span_id = span_id, .source = identity.source };
}

fn localGeneration(function: *const mir.Function, value_id: mir.ValueId, kind: mir.OwnershipEventKind, block_id: mir.BlockId, source: Location) ?u32 {
    var found: ?u32 = null;
    for (function.ownership_events) |event| {
        if (event.kind != kind or !event.place.root_value_id.eql(value_id) or !event.block_id.eql(block_id) or !sourceEquivalent(event.source, source.source)) continue;
        if (found != null) return null;
        found = event.generation;
    }
    return found;
}

fn valueName(function: *const mir.Function, id: mir.ValueId) ?[]const u8 {
    if (!id.isValid() or id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[id.index()];
    return if (identity.id.eql(id)) identity.spelling else null;
}

fn hasParameter(block: mir.Block, name: []const u8) bool {
    for (block.instructions) |instruction| if (instruction.kind == .param and std.mem.eql(u8, instruction.detail, name)) return true;
    return false;
}

fn isJumpTo(terminator: mir.Terminator, target: usize) bool {
    return switch (terminator) {
        .jump => |actual| actual == target,
        else => false,
    };
}

fn isReturn(terminator: mir.Terminator) bool {
    return switch (terminator) {
        .return_ => true,
        else => false,
    };
}

fn isOverflowTrap(terminator: mir.Terminator) bool {
    return switch (terminator) {
        .trap_ => |kind| kind == .IntegerOverflow,
        else => false,
    };
}

fn isInteger(value_ty: mir.ValueType) bool {
    return switch (value_ty) {
        .integer => true,
        else => false,
    };
}

fn sameType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}

fn sourceEquivalent(a: mir.SourcePoint, b: mir.SourcePoint) bool {
    return a.line == b.line and a.column == b.column and a.offset == b.offset and a.len == b.len;
}
