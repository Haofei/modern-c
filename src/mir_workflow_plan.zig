//! Narrow, syntax-free plans for ordered local workflows.
//!
//! The admitted forms are intentionally fixed: a local `BinOp` whose sole
//! function field is addressed for a three-argument direct dispatch, and a
//! scoped local workflow with one producing call, one void consumer, and a
//! return of the outer local.  All links are MIR identities or facts.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const Location = struct { span_id: mir.SpanId, source: mir.SourcePoint };
pub const TypeRef = struct { id: mir.TypeId, value_ty: mir.ValueType };
pub const ValueRef = struct { id: mir.ValueId, name: []const u8, location: Location };
pub const SymbolRef = struct { id: mir.SymbolId, name: []const u8, location: Location };

pub const LocalStorage = struct {
    value: ValueRef,
    type_ref: TypeRef,
    declaration: Location,
    initializer: Location,
};

pub const AddressOf = struct {
    type_ref: TypeRef,
    location: Location,
    operand: ValueRef,
};

const AddressAccess = struct {
    result_ty: mir.ValueType,
    operand_span_id: mir.SpanId,
};

pub const CallArgumentValue = union(enum) {
    value: ValueRef,
    integer_literal: struct { value: usize, location: Location },
    address_of: AddressOf,
};

pub const CallArgument = struct {
    index: usize,
    type_ref: TypeRef,
    location: Location,
    value: CallArgumentValue,
};

pub const DirectCall = struct {
    callee: ValueRef,
    result: TypeRef,
    location: Location,
    args: [3]CallArgument,
    arg_count: usize,
};

pub const LocalVtableCall = struct {
    local: LocalStorage,
    function_field_index: usize,
    function_symbol: ValueRef,
    function_field_location: Location,
    dispatch: DirectCall,
    return_location: Location,
};

pub const ScopedBlock = struct {
    outer: LocalStorage,
    outer_initializer: ValueRef,
    inner: LocalStorage,
    inner_call: DirectCall,
    consume_call: DirectCall,
    inner_scope_last_use: Location,
    return_location: Location,
};

pub const ClosureBind = struct {
    capture: AddressOf,
    target: SymbolRef,
    target_param_count: usize,
    target_return: TypeRef,
    closure: ValueRef,
    closure_type: TypeRef,
    closure_param_count: usize,
    closure_return: TypeRef,
    location: Location,
};

pub const ClosureIndirectCall = struct {
    closure: ValueRef,
    result: TypeRef,
    location: Location,
    argument: ValueRef,
};

pub const ClosureCall = struct {
    environment: LocalStorage,
    bind: ClosureBind,
    call: ClosureIndirectCall,
};

pub const Plan = union(enum) {
    local_vtable_call: LocalVtableCall,
    scoped_block: ScopedBlock,
    call_closure: ClosureCall,
};

pub fn build(function: *const mir.Function) ?Plan {
    if (voidEntry(function)) |entry| if (buildCallClosure(function, entry)) |plan| return plan;
    const entry = straightLineEntry(function) orelse return null;
    if (buildLocalVtableCall(function, entry)) |plan| return plan;
    if (buildScopedBlock(function, entry)) |plan| return plan;
    return null;
}

fn buildCallClosure(function: *const mir.Function, entry: mir.Block) ?Plan {
    if (function.trap_edges.len != 0) return null;
    if (!hasOnly(entry, &.{ .param, .local, .target_type, .expr, .integer_literal_conversion, .call, .call_target, .indirect_call, .representation_check, .representation_use })) return null;
    var locals: [2]mir.Instruction = undefined;
    var local_count: usize = 0;
    var indirect: ?mir.Instruction = null;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .local => {
            if (local_count == 2) return null;
            locals[local_count] = instruction;
            local_count += 1;
        },
        .indirect_call => {
            if (indirect != null) return null;
            indirect = instruction;
        },
        else => {},
    };
    if (local_count != 2) return null;
    const environment = localStorage(function, entry, locals[0]) orelse return null;
    const environment_literal = instructionAt(entry, locals[0].typed_value_operand_span_id, .expr) orelse return null;
    const environment_type = aggregateTypeAt(entry, environment_literal.typed_span_id) orelse return null;
    if (environment_type.aggregate_construction != .declared_struct or environment_literal.typed_aggregate_operand_count != 1 or environment_literal.typed_aggregate_field_indices[0] != 0) return null;
    const environment_value = instructionAt(entry, environment_literal.typed_aggregate_operand_span_ids[0], .expr) orelse return null;
    if (environment_value.constant_usize_value != 0) return null;
    const bind_fact = uniqueBindFact(function, locals[1].typed_value_id orelse return null) orelse return null;
    if (!bindFactValidForPlan(function, entry, bind_fact, environment, locals[1])) return null;
    const capture: AddressOf = .{ .type_ref = typeRef(function, bind_fact.capture_ty, typeForId(function, bind_fact.capture_ty) orelse return null) orelse return null, .location = location(function, bind_fact.capture_span_id) orelse return null, .operand = valueRef(function, bind_fact.capture_value_id, bind_fact.capture_operand_span_id) orelse return null };
    const target = symbolRef(function, bind_fact.typed_target_fn_symbol_id, bind_fact.target_fn, bind_fact.target_span_id) orelse return null;
    const bind = ClosureBind{ .capture = capture, .target = target, .target_param_count = bind_fact.target_param_count, .target_return = typeRef(function, bind_fact.target_return_ty, typeForId(function, bind_fact.target_return_ty) orelse return null) orelse return null, .closure = valueRef(function, bind_fact.closure_value_id, bind_fact.closure_span_id) orelse return null, .closure_type = typeRef(function, bind_fact.closure_ty, typeForId(function, bind_fact.closure_ty) orelse return null) orelse return null, .closure_param_count = bind_fact.closure_param_count, .closure_return = typeRef(function, bind_fact.closure_return_ty, typeForId(function, bind_fact.closure_return_ty) orelse return null) orelse return null, .location = location(function, bind_fact.closure_span_id) orelse return null };
    if (!bind.capture.operand.id.eql(environment.value.id)) return null;
    const call_instruction = indirect orelse return null;
    const call = closureIndirectCall(function, entry, call_instruction, bind) orelse return null;
    return .{ .call_closure = .{ .environment = environment, .bind = bind, .call = call } };
}

fn buildLocalVtableCall(function: *const mir.Function, entry: mir.Block) ?Plan {
    if (function.trap_edges.len != 0 or !hasOnly(entry, &.{ .param, .local, .target_type, .expr, .call, .representation_check, .representation_use, .return_value })) return null;
    const local_instruction = uniqueInstruction(entry, .local) orelse return null;
    const local = localStorage(function, entry, local_instruction) orelse return null;
    const literal = instructionAt(entry, local_instruction.typed_value_operand_span_id, .expr) orelse return null;
    const aggregate = aggregateTypeAt(entry, literal.typed_span_id) orelse return null;
    if (aggregate.aggregate_construction != .declared_struct or literal.typed_aggregate_operand_count != 1 or literal.typed_aggregate_field_indices[0] != 0) return null;
    const field_span = literal.typed_aggregate_operand_span_ids[0];
    const function_symbol = valueAt(function, entry, field_span) orelse return null;
    const dispatch_instruction = uniqueInstruction(entry, .call) orelse return null;
    const dispatch = directCall(function, entry, dispatch_instruction, 3) orelse return null;
    const address = switch (dispatch.args[0].value) {
        .address_of => |value| value,
        else => return null,
    };
    if (!address.operand.id.eql(local.value.id)) return null;
    const x = switch (dispatch.args[1].value) {
        .value => |value| value,
        else => return null,
    };
    const y = switch (dispatch.args[2].value) {
        .value => |value| value,
        else => return null,
    };
    if (!x.id.isValid() or !y.id.isValid() or x.id.eql(y.id)) return null;
    const returned = uniqueInstruction(entry, .return_value) orelse return null;
    if (!returned.typed_value_operand_span_id.eql(dispatch_instruction.typed_span_id) or !(returned.typed_value_id orelse return null).eql(dispatch_instruction.typed_value_id orelse return null)) return null;
    return .{ .local_vtable_call = .{
        .local = local,
        .function_field_index = 0,
        .function_symbol = function_symbol,
        .function_field_location = location(function, field_span) orelse return null,
        .dispatch = dispatch,
        .return_location = location(function, returned.typed_span_id) orelse return null,
    } };
}

fn buildScopedBlock(function: *const mir.Function, entry: mir.Block) ?Plan {
    if (function.trap_edges.len != 0 or !hasOnly(entry, &.{ .param, .local, .target_type, .expr, .call, .integer_literal_conversion, .return_value })) return null;
    var locals: [2]mir.Instruction = undefined;
    var calls: [2]mir.Instruction = undefined;
    var local_count: usize = 0;
    var call_count: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .local => {
            if (local_count == 2) return null;
            locals[local_count] = instruction;
            local_count += 1;
        },
        .call => {
            if (call_count == 2) return null;
            calls[call_count] = instruction;
            call_count += 1;
        },
        else => {},
    };
    if (local_count != 2 or call_count != 2) return null;
    const outer = localStorage(function, entry, locals[0]) orelse return null;
    const outer_initializer = valueAt(function, entry, locals[0].typed_value_operand_span_id) orelse return null;
    const inner = localStorage(function, entry, locals[1]) orelse return null;
    if (!locals[1].typed_value_operand_span_id.eql(calls[0].typed_span_id)) return null;
    const inner_call = directCall(function, entry, calls[0], 2) orelse return null;
    const first = switch (inner_call.args[0].value) {
        .value => |value| value,
        else => return null,
    };
    const second = switch (inner_call.args[1].value) {
        .integer_literal => |value| value,
        else => return null,
    };
    if (!first.id.eql(outer_initializer.id) or second.value != 1) return null;
    const consume_call = directCall(function, entry, calls[1], 1) orelse return null;
    const consumed = switch (consume_call.args[0].value) {
        .value => |value| value,
        else => return null,
    };
    if (!consumed.id.eql(inner.value.id)) return null;
    const returned = uniqueInstruction(entry, .return_value) orelse return null;
    const returned_value = valueAt(function, entry, returned.typed_value_operand_span_id) orelse return null;
    if (!returned_value.id.eql(outer.value.id) or !(returned.typed_value_id orelse return null).eql(outer.value.id)) return null;
    return .{ .scoped_block = .{
        .outer = outer,
        .outer_initializer = outer_initializer,
        .inner = inner,
        .inner_call = inner_call,
        .consume_call = consume_call,
        .inner_scope_last_use = consume_call.args[0].location,
        .return_location = location(function, returned.typed_span_id) orelse return null,
    } };
}

fn localStorage(function: *const mir.Function, _: mir.Block, instruction: mir.Instruction) ?LocalStorage {
    return .{
        .value = valueRef(function, instruction.typed_value_id orelse return null, instruction.typed_span_id) orelse return null,
        .type_ref = typeRef(function, instruction.typed_result_ty, instruction.result_ty) orelse return null,
        .declaration = location(function, instruction.typed_span_id) orelse return null,
        .initializer = location(function, instruction.typed_value_operand_span_id) orelse return null,
    };
}

fn directCall(function: *const mir.Function, entry: mir.Block, instruction: mir.Instruction, arg_count: usize) ?DirectCall {
    if (arg_count > 3 or !instruction.typed_callee_span_id.isValid()) return null;
    const result_fact = uniqueCallResult(function, instruction.typed_callee_span_id, instruction.detail) orelse return null;
    if (!sameType(result_fact.result_ty, instruction.result_ty) or directArgumentCount(function, instruction.typed_callee_span_id) != arg_count) return null;
    var args: [3]CallArgument = undefined;
    for (0..arg_count) |index| args[index] = callArgument(function, entry, uniqueCallArgument(function, instruction.typed_callee_span_id, index) orelse return null, index) orelse return null;
    return .{ .callee = valueRef(function, instruction.typed_value_id orelse return null, instruction.typed_span_id) orelse return null, .result = typeRef(function, result_fact.typed_result_ty, result_fact.result_ty) orelse return null, .location = location(function, instruction.typed_span_id) orelse return null, .args = args, .arg_count = arg_count };
}

fn callArgument(function: *const mir.Function, entry: mir.Block, fact: mir.TargetTypeFact, index: usize) ?CallArgument {
    const type_ref = typeRef(function, fact.typed_result_ty, fact.result_ty) orelse return null;
    const argument_location = location(function, fact.typed_span_id) orelse return null;
    if (addressFactAt(function, fact.typed_span_id)) |access| {
        if (std.meta.activeTag(access.result_ty) != std.meta.activeTag(fact.result_ty)) return null;
        const operand = valueAt(function, entry, access.operand_span_id) orelse return null;
        return .{ .index = index, .type_ref = type_ref, .location = argument_location, .value = .{ .address_of = .{ .type_ref = type_ref, .location = argument_location, .operand = operand } } };
    }
    const expression = instructionAt(entry, fact.typed_span_id, .expr) orelse return null;
    if (fact.typed_operand_value_id.isValid()) {
        const value = valueRef(function, fact.typed_operand_value_id, fact.typed_span_id) orelse return null;
        if (!(expression.typed_value_id orelse return null).eql(value.id)) return null;
        return .{ .index = index, .type_ref = type_ref, .location = argument_location, .value = .{ .value = value } };
    }
    if (expression.constant_usize_value == null) return null;
    return .{ .index = index, .type_ref = type_ref, .location = argument_location, .value = .{ .integer_literal = .{ .value = expression.constant_usize_value.?, .location = argument_location } } };
}

fn uniqueBindFact(function: *const mir.Function, closure: mir.ValueId) ?mir.BindThunkFact {
    var found: ?mir.BindThunkFact = null;
    for (function.bind_thunk_facts) |fact| {
        if (!fact.closure_value_id.eql(closure)) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn bindFactValidForPlan(function: *const mir.Function, entry: mir.Block, fact: mir.BindThunkFact, environment: LocalStorage, closure_local: mir.Instruction) bool {
    if (!fact.capture_value_id.isValid() or !fact.capture_value_id.eql(environment.value.id) or !fact.closure_value_id.isValid() or !fact.closure_value_id.eql(closure_local.typed_value_id orelse return false) or !fact.capture_ty.isValid() or !fact.target_capture_ty.isValid() or !fact.capture_ty.eql(fact.target_capture_ty) or !fact.closure_ty.isValid() or !fact.closure_ty.eql(closure_local.typed_result_ty) or !fact.target_return_ty.isValid() or !fact.closure_return_ty.isValid() or !fact.target_return_ty.eql(fact.closure_return_ty) or fact.target_param_count != fact.closure_param_count + 1) return false;
    if (!closure_local.typed_value_operand_span_id.eql(fact.closure_span_id) or !spanValid(function, fact.target_span_id) or !spanValid(function, fact.capture_span_id) or !spanValid(function, fact.capture_operand_span_id) or !spanValid(function, fact.closure_span_id)) return false;
    const capture_access = addressFactAt(function, fact.capture_span_id) orelse return false;
    if (!capture_access.operand_span_id.eql(fact.capture_operand_span_id) or std.meta.activeTag(capture_access.result_ty) != std.meta.activeTag(typeForId(function, fact.capture_ty) orelse return false)) return false;
    const capture_value = valueAt(function, entry, fact.capture_operand_span_id) orelse return false;
    if (!capture_value.id.eql(fact.capture_value_id)) return false;
    var target_type_count: usize = 0;
    for (function.target_type_facts) |target_type| {
        if (target_type.kind != .bind or !target_type.typed_span_id.eql(fact.closure_span_id)) continue;
        if (!target_type.typed_result_ty.eql(fact.closure_ty)) return false;
        target_type_count += 1;
    }
    return target_type_count == 1 and symbolRef(function, fact.typed_target_fn_symbol_id, fact.target_fn, fact.target_span_id) != null;
}

fn closureIndirectCall(function: *const mir.Function, entry: mir.Block, instruction: mir.Instruction, bind: ClosureBind) ?ClosureIndirectCall {
    if (!instruction.typed_callee_span_id.isValid() or !instruction.typed_callee_root_value_id.eql(bind.closure.id) or !instruction.typed_callee_root_span_id.isValid() or instruction.callee_field_index != null) return null;
    const callee_type = uniqueIndirectCalleeType(function, instruction.typed_callee_span_id) orelse return null;
    if (!callee_type.typed_result_ty.eql(bind.closure_type.id) or !sameType(callee_type.result_ty, bind.closure_type.value_ty) or !instruction.typed_result_ty.eql(bind.closure_return.id) or !sameType(instruction.result_ty, bind.closure_return.value_ty)) return null;
    const argument_fact = uniqueIndirectArgument(function, instruction.typed_callee_span_id, 0) orelse return null;
    if (indirectArgumentCount(function, instruction.typed_callee_span_id) != 1) return null;
    const argument = valueAt(function, entry, argument_fact.typed_span_id) orelse return null;
    if (!argument.id.eql(argument_fact.typed_operand_value_id)) return null;
    return .{ .closure = valueRef(function, bind.closure.id, instruction.typed_callee_root_span_id) orelse return null, .result = typeRef(function, instruction.typed_result_ty, instruction.result_ty) orelse return null, .location = location(function, instruction.typed_span_id) orelse return null, .argument = argument };
}

fn uniqueIndirectCalleeType(function: *const mir.Function, span: mir.SpanId) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .indirect_call_callee or !fact.typed_span_id.eql(span)) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn uniqueIndirectArgument(function: *const mir.Function, callee: mir.SpanId, index: usize) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .indirect_call_argument or !fact.typed_callee_span_id.eql(callee) or fact.target_index != index) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn indirectArgumentCount(function: *const mir.Function, callee: mir.SpanId) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.kind == .indirect_call_argument and fact.typed_callee_span_id.eql(callee)) count += 1;
    }
    return count;
}

fn straightLineEntry(function: *const mir.Function) ?mir.Block {
    if (function.blocks.len != 1) return null;
    const entry = function.blocks[0];
    return if (entry.typed_id.isValid() and entry.terminator == .return_ and entry.successors.len == 0) entry else null;
}
fn voidEntry(function: *const mir.Function) ?mir.Block {
    if (function.blocks.len != 1) return null;
    const entry = function.blocks[0];
    return if (entry.typed_id.isValid() and entry.terminator == .fallthrough and entry.successors.len == 0) entry else null;
}
fn hasOnly(block: mir.Block, allowed: []const mir.Instruction.Kind) bool {
    for (block.instructions) |instruction| {
        var admitted = false;
        for (allowed) |kind| {
            if (instruction.kind == kind) admitted = true;
        }
        if (!admitted) return false;
    }
    return true;
}
fn uniqueInstruction(block: mir.Block, kind: mir.Instruction.Kind) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| if (instruction.kind == kind) {
        if (found != null) return null;
        found = instruction;
    };
    return found;
}
fn instructionAt(block: mir.Block, span: mir.SpanId, kind: mir.Instruction.Kind) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| if (instruction.kind == kind and instruction.typed_span_id.eql(span)) {
        if (found != null) return null;
        found = instruction;
    };
    return found;
}
fn aggregateTypeAt(block: mir.Block, span: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| if (instruction.kind == .target_type and instruction.typed_span_id.eql(span) and instruction.aggregate_construction != null) {
        if (found != null) return null;
        found = instruction;
    };
    return found;
}
fn uniqueCallResult(function: *const mir.Function, callee: mir.SpanId, owner: []const u8) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_result or !fact.typed_span_id.eql(callee)) continue;
        if (fact.target_owner == null or !std.mem.eql(u8, fact.target_owner.?, owner) or found != null) return null;
        found = fact;
    }
    return found;
}
fn uniqueCallArgument(function: *const mir.Function, callee: mir.SpanId, index: usize) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_argument or !fact.typed_callee_span_id.eql(callee) or fact.target_index != index) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}
fn directArgumentCount(function: *const mir.Function, callee: mir.SpanId) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.kind == .direct_call_argument and fact.typed_callee_span_id.eql(callee)) count += 1;
    }
    return count;
}
fn addressFactAt(function: *const mir.Function, span: mir.SpanId) ?AddressAccess {
    var found: ?AddressAccess = null;
    for (function.access_facts) |fact| switch (fact) {
        .address_of => |address| if (address.typed_span_id.eql(span)) {
            if (found != null) return null;
            found = .{ .result_ty = address.result_ty, .operand_span_id = address.operand_span_id };
        },
        else => {},
    };
    return found;
}
fn valueAt(function: *const mir.Function, block: mir.Block, span: mir.SpanId) ?ValueRef {
    const instruction = instructionAt(block, span, .expr) orelse return null;
    return valueRef(function, instruction.typed_value_id orelse return null, span);
}
fn valueRef(function: *const mir.Function, id: mir.ValueId, span: mir.SpanId) ?ValueRef {
    if (!id.isValid() or id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[id.index()];
    if (!identity.id.eql(id)) return null;
    return .{ .id = id, .name = identity.spelling, .location = location(function, span) orelse return null };
}
fn symbolRef(function: *const mir.Function, id: mir.SymbolId, name: []const u8, span: mir.SpanId) ?SymbolRef {
    if (!id.isValid() or id.index() >= function.target_owner_identities.len) return null;
    const identity = function.target_owner_identities[id.index()];
    if (!identity.id.eql(id) or !std.mem.eql(u8, identity.spelling, name)) return null;
    return .{ .id = id, .name = name, .location = location(function, span) orelse return null };
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
fn spanValid(function: *const mir.Function, span: mir.SpanId) bool {
    return span.isValid() and span.index() < function.span_identities.len and function.span_identities[span.index()].id.eql(span);
}
fn typeForId(function: *const mir.Function, id: mir.TypeId) ?mir.ValueType {
    if (!id.isValid() or id.index() >= function.type_identities.len or !function.type_identities[id.index()].id.eql(id)) return null;
    const spelling = function.type_identities[id.index()].spelling;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.typed_result_ty.eql(id) and std.mem.eql(u8, instruction.result_ty.name(), spelling)) return instruction.result_ty;
    };
    return null;
}
fn sameType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}
