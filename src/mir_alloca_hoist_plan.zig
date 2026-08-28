//! Syntax-free bounded plan for the loop-local static-storage regression.
const std = @import("std");
const mir = @import("mir_model.zig");

pub const Location = struct { span_id: mir.SpanId, source: mir.SourcePoint };
pub const TypeRef = struct { id: mir.TypeId, value_ty: mir.ValueType };
pub const ValueRef = struct { id: mir.ValueId, name: []const u8, location: Location };
pub const Local = struct { value: ValueRef, type_ref: TypeRef, declaration: Location, initializer: Location };
pub const Trap = struct { block: mir.BlockId, kind: mir.TrapKind, source: mir.TrapSource, location: Location };
pub const IndexAccess = struct { base: ValueRef, index: ValueRef, element: TypeRef, bound: usize, location: Location, trap: Trap };
pub const CheckedBinary = struct { operation: []const u8, location: Location, left: Location, right: Location, trap: Trap };
pub const Cast = struct { location: Location, source: TypeRef, target: TypeRef };
pub const Literal = struct { value: usize, type_ref: TypeRef, location: Location };
pub const LoopLocalStorage = struct { local: Local, static_function_storage: bool = true, array_len: usize, loop_block: mir.BlockId };

pub const Plan = struct {
    entry_block: mir.BlockId,
    loop_block: mir.BlockId,
    return_block: mir.BlockId,
    sum: Local,
    index: Local,
    initial_sum: Literal,
    initial_index: Literal,
    iteration_limit: ValueRef,
    buffer_limit: ValueRef,
    bit_mask: Literal,
    increment_by: Literal,
    scratch: LoopLocalStorage,
    slot: Local,
    index_cast: Cast,
    slot_modulo: CheckedBinary,
    store: IndexAccess,
    store_cast: Cast,
    load: IndexAccess,
    load_cast: Cast,
    sum_add: CheckedBinary,
    increment: CheckedBinary,
    return_location: Location,
};

pub fn build(function: *const mir.Function) ?Plan {
    if (function.blocks.len != 8 or function.trap_edges.len != 5) return null;
    const entry = function.blocks[0];
    const body = function.blocks[1];
    const after = function.blocks[2];
    if (!validBlock(entry) or !validBlock(body) or !validBlock(after) or !exactSuccessors(entry, &.{ 1, 2 }) or !exactSuccessors(body, &.{ 3, 4, 5, 6, 7, 0 })) return null;
    switch (entry.terminator) {
        .branch => |branch| if (branch.true_block != 1 or branch.false_block != 2) return null,
        else => return null,
    }
    switch (body.terminator) {
        .jump => |target| if (target != 0) return null,
        else => return null,
    }
    switch (after.terminator) {
        .return_ => |ty| if (!sameValueType(ty, function.return_ty)) return null,
        else => return null,
    }
    for (function.blocks[3..]) |block| if (!validBlock(block) or block.terminator != .trap_ or block.instructions.len != 0 or !exactSuccessors(block, &.{})) return null;
    const sum_i = nth(entry, .local, 0) orelse return null;
    const i_i = nth(entry, .local, 1) orelse return null;
    if (nth(entry, .local, 2) != null) return null;
    const sum = local(function, sum_i) orelse return null;
    const index = local(function, i_i) orelse return null;
    const initial_sum = literal(function, entry, sum_i.typed_value_operand_span_id, 0) orelse return null;
    const initial_index = literal(function, entry, i_i.typed_value_operand_span_id, 0) orelse return null;
    const condition = uniqueDetail(entry, .binary, "lt") orelse return null;
    const condition_left = valueAt(function, entry, condition.typed_left_operand_span_id) orelse return null;
    const limit = valueAt(function, entry, condition.typed_right_operand_span_id) orelse return null;
    if (!condition_left.id.eql(index.value.id)) return null;
    const scratch_i = nth(body, .local, 0) orelse return null;
    const slot_i = nth(body, .local, 1) orelse return null;
    if (nth(body, .local, 2) != null) return null;
    const scratch_local = local(function, scratch_i) orelse return null;
    const slot = local(function, slot_i) orelse return null;
    if (!uninitAt(body, scratch_i.typed_value_operand_span_id)) return null;
    const modulo_i = instructionAt(body, slot_i.typed_value_operand_span_id, .binary) orelse return null;
    if (!std.mem.eql(u8, modulo_i.detail, "mod")) return null;
    const index_cast = castAt(function, body, modulo_i.typed_left_operand_span_id) orelse return null;
    const modulo_right = valueAt(function, body, modulo_i.typed_right_operand_span_id) orelse return null;
    if (!modulo_i.typed_left_operand_span_id.eql(index_cast.location.span_id) or !sameType(index_cast.source, index.type_ref) or !sameType(index_cast.target, slot.type_ref) or !sameType(resultType(function, modulo_i) orelse return null, slot.type_ref)) return null;
    const modulo = checked(function, body, modulo_i, .DivideByZero) orelse return null;
    const assignments = collectAssignments(body) orelse return null;
    const store_i = assignments[0];
    const sum_assign = assignments[1];
    const inc_assign = assignments[2];
    const store_index_i = instructionAt(body, store_i.typed_target_operand_span_id, .index) orelse return null;
    const store = indexAccess(function, body, store_index_i, .Bounds) orelse return null;
    if (!store.base.id.eql(scratch_local.value.id) or !store.index.id.eql(slot.value.id) or store.bound != 256) return null;
    const store_cast = castAt(function, body, store_i.typed_value_operand_span_id) orelse return null;
    const bits = uniqueDetail(body, .binary, "bit_and") orelse return null;
    const bit_mask = literal(function, body, bits.typed_right_operand_span_id, 255) orelse return null;
    if (!std.mem.eql(u8, bits.detail, "bit_and") or !(valueAt(function, body, bits.typed_left_operand_span_id) orelse return null).id.eql(index.value.id) or !sameType(store_cast.source, resultType(function, bits) orelse return null) or !sameType(store_cast.target, store.element) or instructionPosition(body, store_cast.location.span_id) >= instructionPosition(body, bits.typed_span_id)) return null;
    const sum_binary = instructionAt(body, sum_assign.typed_value_operand_span_id, .binary) orelse return null;
    const sum_add = checked(function, body, sum_binary, .IntegerOverflow) orelse return null;
    if (!(valueAt(function, body, sum_assign.typed_target_operand_span_id) orelse return null).id.eql(sum.value.id) or !std.mem.eql(u8, sum_add.operation, "add") or !(valueAt(function, body, sum_add.left.span_id) orelse return null).id.eql(sum.value.id) or !sameType(resultType(function, sum_binary) orelse return null, sum.type_ref)) return null;
    const load_cast = castAt(function, body, sum_binary.typed_right_operand_span_id) orelse return null;
    const load_i = otherIndex(body, store_index_i) orelse return null;
    const load = indexAccess(function, body, load_i, .Bounds) orelse return null;
    if (!load.base.id.eql(scratch_local.value.id) or !load.index.id.eql(slot.value.id) or load.bound != 256 or !sameType(load_cast.source, load.element) or !sameType(load_cast.target, sum.type_ref) or instructionPosition(body, load_cast.location.span_id) >= instructionPosition(body, load_i.typed_span_id)) return null;
    const inc_binary = instructionAt(body, inc_assign.typed_value_operand_span_id, .binary) orelse return null;
    const increment = checked(function, body, inc_binary, .IntegerOverflow) orelse return null;
    const increment_by = literal(function, body, increment.right.span_id, 1) orelse return null;
    if (!(valueAt(function, body, inc_assign.typed_target_operand_span_id) orelse return null).id.eql(index.value.id) or !std.mem.eql(u8, increment.operation, "add") or !(valueAt(function, body, increment.left.span_id) orelse return null).id.eql(index.value.id) or !sameType(resultType(function, inc_binary) orelse return null, index.type_ref)) return null;
    const returned = unique(after, .return_value) orelse return null;
    if (!(valueAt(function, after, returned.typed_value_operand_span_id) orelse return null).id.eql(sum.value.id)) return null;
    return .{ .entry_block = entry.typed_id, .loop_block = body.typed_id, .return_block = after.typed_id, .sum = sum, .index = index, .initial_sum = initial_sum, .initial_index = initial_index, .iteration_limit = limit, .buffer_limit = modulo_right, .bit_mask = bit_mask, .increment_by = increment_by, .scratch = .{ .local = scratch_local, .array_len = 256, .loop_block = body.typed_id }, .slot = slot, .index_cast = index_cast, .slot_modulo = modulo, .store = store, .store_cast = store_cast, .load = load, .load_cast = load_cast, .sum_add = sum_add, .increment = increment, .return_location = location(function, returned.typed_span_id) orelse return null };
}

fn local(function: *const mir.Function, i: mir.Instruction) ?Local {
    return .{ .value = valueRef(function, i.typed_value_id orelse return null, i.typed_span_id) orelse return null, .type_ref = typeRef(function, i.typed_result_ty, i.result_ty) orelse return null, .declaration = location(function, i.typed_span_id) orelse return null, .initializer = location(function, i.typed_value_operand_span_id) orelse return null };
}
fn castAt(function: *const mir.Function, block: mir.Block, span: mir.SpanId) ?Cast {
    const c = instructionAt(block, span, .expr) orelse return null;
    if (!std.mem.eql(u8, c.detail, "cast")) return null;
    const s = uniqueTarget(function, .explicit_cast_source, span) orelse return null;
    const t = uniqueTarget(function, .explicit_cast_target, span) orelse return null;
    return .{ .location = location(function, span) orelse return null, .source = typeRef(function, s.typed_result_ty, s.result_ty) orelse return null, .target = typeRef(function, t.typed_result_ty, t.result_ty) orelse return null };
}
fn indexAccess(function: *const mir.Function, block: mir.Block, i: mir.Instruction, kind: mir.TrapKind) ?IndexAccess {
    if (i.kind != .index or i.static_index_bound == null) return null;
    return .{ .base = valueAt(function, block, i.typed_base_operand_span_id) orelse return null, .index = valueAt(function, block, i.typed_index_operand_span_id) orelse return null, .element = typeRef(function, i.typed_result_ty, i.result_ty) orelse return null, .bound = i.static_index_bound.?, .location = location(function, i.typed_span_id) orelse return null, .trap = trap(function, block, i.typed_span_id, kind) orelse return null };
}
fn checked(function: *const mir.Function, block: mir.Block, i: mir.Instruction, kind: mir.TrapKind) ?CheckedBinary {
    if (i.kind != .binary or instructionAt(block, i.typed_span_id, .add_overflow) == null) return null;
    return .{ .operation = i.detail, .location = location(function, i.typed_span_id) orelse return null, .left = location(function, i.typed_left_operand_span_id) orelse return null, .right = location(function, i.typed_right_operand_span_id) orelse return null, .trap = trap(function, block, i.typed_span_id, kind) orelse return null };
}
fn trap(function: *const mir.Function, block: mir.Block, span: mir.SpanId, kind: mir.TrapKind) ?Trap {
    var found: ?Trap = null;
    for (function.trap_edges) |edge| {
        if (edge.from_block != block.id or !edge.typed_span_id.eql(span)) continue;
        if (edge.kind != kind or edge.source != expectedTrapSource(kind) or edge.trap_block >= function.blocks.len or found != null or !hasSuccessor(block, edge.trap_block)) return null;
        const target = function.blocks[edge.trap_block];
        if (!target.typed_id.isValid() or target.terminator != .trap_ or target.instructions.len != 0) return null;
        found = .{ .block = target.typed_id, .kind = kind, .source = edge.source, .location = location(function, span) orelse return null };
    }
    return found;
}
fn expectedTrapSource(kind: mir.TrapKind) mir.TrapSource {
    return switch (kind) {
        .Bounds => .bounds_check,
        .IntegerOverflow, .DivideByZero => .checked_arithmetic,
        else => unreachable,
    };
}
fn hasSuccessor(block: mir.Block, wanted: usize) bool {
    for (block.successors) |successor| if (successor == wanted) return true;
    return false;
}
fn validBlock(block: mir.Block) bool {
    return block.typed_id.isValid() and block.typed_id.index() == block.id;
}
fn exactSuccessors(block: mir.Block, expected: []const usize) bool {
    if (block.successors.len != expected.len or block.typed_successors.len != expected.len) return false;
    for (expected, 0..) |successor, n| if (block.successors[n] != successor or !block.typed_successors[n].isValid() or block.typed_successors[n].index() != successor) return false;
    return true;
}
fn collectAssignments(block: mir.Block) ?[3]mir.Instruction {
    var out: [3]mir.Instruction = undefined;
    var n: usize = 0;
    for (block.instructions) |i| if (i.kind == .assign) {
        if (n == 3) return null;
        out[n] = i;
        n += 1;
    };
    return if (n == 3) out else null;
}
fn nth(block: mir.Block, kind: mir.Instruction.Kind, wanted: usize) ?mir.Instruction {
    var n: usize = 0;
    for (block.instructions) |i| if (i.kind == kind) {
        if (n == wanted) return i;
        n += 1;
    };
    return null;
}
fn unique(block: mir.Block, kind: mir.Instruction.Kind) ?mir.Instruction {
    const first = nth(block, kind, 0) orelse return null;
    return if (nth(block, kind, 1) == null) first else null;
}
fn uniqueDetail(block: mir.Block, kind: mir.Instruction.Kind, detail: []const u8) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |i| if (i.kind == kind and std.mem.eql(u8, i.detail, detail)) {
        if (found != null) return null;
        found = i;
    };
    return found;
}
fn instructionAt(block: mir.Block, span: mir.SpanId, kind: mir.Instruction.Kind) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |i| if (i.kind == kind and i.typed_span_id.eql(span)) {
        if (found != null) return null;
        found = i;
    };
    return found;
}
fn otherIndex(block: mir.Block, first: mir.Instruction) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |i| if (i.kind == .index and !i.typed_span_id.eql(first.typed_span_id)) {
        if (found != null) return null;
        found = i;
    };
    return found;
}
fn instructionPosition(block: mir.Block, span: mir.SpanId) usize {
    for (block.instructions, 0..) |i, n| if (i.typed_span_id.eql(span)) return n;
    return std.math.maxInt(usize);
}
fn uniqueTarget(function: *const mir.Function, kind: mir.TargetTypeKind, span: mir.SpanId) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| if (fact.kind == kind and fact.typed_span_id.eql(span)) {
        if (found != null) return null;
        found = fact;
    };
    return found;
}
fn valueAt(function: *const mir.Function, block: mir.Block, span: mir.SpanId) ?ValueRef {
    const i = instructionAt(block, span, .expr) orelse return null;
    return valueRef(function, i.typed_value_id orelse return null, span);
}
fn valueRef(function: *const mir.Function, id: mir.ValueId, span: mir.SpanId) ?ValueRef {
    if (!id.isValid() or id.index() >= function.value_identities.len) return null;
    const x = function.value_identities[id.index()];
    return if (x.id.eql(id)) .{ .id = id, .name = x.spelling, .location = location(function, span) orelse return null } else null;
}
fn typeRef(function: *const mir.Function, id: mir.TypeId, ty: mir.ValueType) ?TypeRef {
    if (!id.isValid() or id.index() >= function.type_identities.len) return null;
    const x = function.type_identities[id.index()];
    return if (x.id.eql(id) and std.mem.eql(u8, x.spelling, ty.name())) .{ .id = id, .value_ty = ty } else null;
}
fn resultType(function: *const mir.Function, i: mir.Instruction) ?TypeRef {
    const fact = uniqueTarget(function, .expression_result, i.typed_span_id) orelse return null;
    return typeRef(function, fact.typed_result_ty, fact.result_ty);
}
fn location(function: *const mir.Function, span: mir.SpanId) ?Location {
    if (!span.isValid() or span.index() >= function.span_identities.len) return null;
    const x = function.span_identities[span.index()];
    return if (x.id.eql(span)) .{ .span_id = span, .source = x.source } else null;
}
fn uninitAt(block: mir.Block, span: mir.SpanId) bool {
    const i = instructionAt(block, span, .expr) orelse return false;
    return std.mem.eql(u8, i.detail, "uninit");
}
fn literal(function: *const mir.Function, block: mir.Block, span: mir.SpanId, expected: usize) ?Literal {
    const i = instructionAt(block, span, .expr) orelse return null;
    if (i.constant_usize_value == null or i.constant_usize_value.? != expected) return null;
    const fact = uniqueTarget(function, .expression_result, span) orelse return null;
    return .{ .value = expected, .type_ref = typeRef(function, fact.typed_result_ty, fact.result_ty) orelse return null, .location = location(function, span) orelse return null };
}
fn sameType(left: TypeRef, right: TypeRef) bool {
    return left.id.eql(right.id) and sameValueType(left.value_ty, right.value_ty);
}
fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.mem.eql(u8, left.name(), right.name());
}
