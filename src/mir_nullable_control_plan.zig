//! Syntax-free, fail-closed plans for the smallest nullable control families.
//!
//! The plan deliberately admits only nullable-pointer `if let` and `switch`
//! forms with a bounded direct return in each arm. It is a shared
//! representation of control, value identity, and call ordering; C and LLVM
//! can consume it without reopening an AST body.

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

pub const DirectCall = struct {
    callee_name: []const u8,
    callee_value_id: mir.ValueId,
    call_location: Location,
    callee_location: Location,
    result: TypeRef,
};

pub const Subject = union(enum) {
    parameter: struct {
        name: []const u8,
        value_id: mir.ValueId,
        location: Location,
    },
    global: struct {
        name: []const u8,
        value_id: mir.ValueId,
        location: Location,
    },
    field: struct {
        base_name: []const u8,
        base_value_id: mir.ValueId,
        field_name: []const u8,
        field_index: usize,
        base_location: Location,
        location: Location,
    },
    direct_call: struct {
        call: DirectCall,
        /// The only admitted argument form is one nested, zero-argument,
        /// direct call. Keeping it explicit preserves `next_seed()` before
        /// `maybe_ptr_from(...)` without an AST ordering query.
        seed: ?DirectCall = null,
    },
};

pub const Binding = struct {
    name: []const u8,
    value_id: mir.ValueId,
    pointer_ty: mir.ValueType,
    location: Location,
};

pub const DirectCallReturn = struct {
    call: DirectCall,
    argument: Binding,
};

pub const Parameter = struct {
    name: []const u8,
    value_id: mir.ValueId,
    pointer_ty: mir.ValueType,
    location: Location,
    /// The only admitted checked parameter return has one MIR-owned
    /// InvalidRepresentation edge at this exact operand span.
    requires_nonnull_check: bool,
};

pub const ReturnOperand = union(enum) {
    direct_call: DirectCallReturn,
    binding: Binding,
    parameter: Parameter,
    integer_zero: Location,
};

pub const ArmReturn = struct {
    operand: ReturnOperand,
    return_location: Location,
};

pub const Plan = struct {
    pub const Form = enum { if_let, switch_ };

    form: Form,
    dispatch_block: mir.BlockId,
    nonnull_block: mir.BlockId,
    null_block: mir.BlockId,
    subject: Subject,
    subject_type: TypeRef,
    binding: Binding,
    then_return: ArmReturn,
    else_return: ArmReturn,
};

/// Returns null for every shape outside the bounded nullable-control family.
/// This is intentionally not a best-effort recovery API: absent/mismatched
/// typed facts, effects, cleanup, or CFG identity all fail closed.
pub fn build(function: *const mir.Function) ?Plan {
    if (!functionEffectsAreEmpty(function)) return null;
    if (function.blocks.len < 3) return null;
    const dispatch = function.blocks[0];
    if (!dispatch.typed_id.isValid()) return null;

    return switch (dispatch.terminator) {
        .branch => |branch| buildIfLet(function, dispatch, branch),
        .switch_ => buildSwitch(function, dispatch),
        else => null,
    };
}

fn buildIfLet(function: *const mir.Function, dispatch: mir.Block, branch: anytype) ?Plan {
    // A non-null fallback parameter has its usual MIR representation check,
    // which contributes one dedicated trap block. No other extra CFG is
    // admitted by this bounded plan.
    if ((function.blocks.len < 3 or function.blocks.len > 5) or dispatch.successors.len != 2) return null;
    if (branch.true_block >= function.blocks.len or branch.false_block >= function.blocks.len) return null;
    if (dispatch.successors[0] != branch.true_block or dispatch.successors[1] != branch.false_block) return null;
    const nonnull = function.blocks[branch.true_block];
    const null_block = function.blocks[branch.false_block];
    if (!nonnull.typed_id.isValid() or !null_block.typed_id.isValid()) return null;

    const marker = uniqueInstruction(dispatch, .binary) orelse return null;
    if (marker.result_ty != .branch or !marker.typed_span_id.isValid()) return null;
    const direct_binding = bindingInThen(function, nonnull, marker.detail);
    const returned_binding = bindingReturn(function, nonnull, marker.detail);
    const binding = direct_binding orelse returned_binding orelse return null;
    const subject_type = uniqueTypeFactInBlock(function, dispatch, .if_let_subject) orelse return null;
    if (!nullableSubjectMatchesBinding(subject_type.value_ty, binding.pointer_ty)) return null;
    const subject = subjectForSpan(function, dispatch, subject_type.location.span_id) orelse return null;
    if (!dispatchContainsOnlySubjectWork(dispatch, subject)) return null;
    const then_return = if (direct_binding) |candidate|
        ArmReturn{ .operand = .{ .direct_call = thenCallForBinding(function, nonnull, candidate) orelse return null }, .return_location = returnLocation(function, nonnull) orelse return null }
    else
        ArmReturn{ .operand = .{ .binding = binding }, .return_location = returnLocation(function, nonnull) orelse return null };
    const else_return = zeroReturn(function, null_block) orelse parameterReturn(function, null_block);
    if (else_return == null) return null;
    const parameter_fallback = std.meta.activeTag(else_return.?.operand) == .parameter;
    if (parameter_fallback) {
        if (function.blocks.len != 4 and function.blocks.len != 5) return null;
        if (function.blocks.len == 5 and !hasSingleEmptyAfterBlock(function, dispatch, nonnull, null_block)) return null;
    } else if (function.blocks.len != 3) return null;
    return .{
        .form = .if_let,
        .dispatch_block = dispatch.typed_id,
        .nonnull_block = nonnull.typed_id,
        .null_block = null_block.typed_id,
        .subject = subject,
        .subject_type = subject_type,
        .binding = binding,
        .then_return = then_return,
        .else_return = else_return.?,
    };
}

fn hasSingleEmptyAfterBlock(function: *const mir.Function, dispatch: mir.Block, nonnull: mir.Block, null_block: mir.Block) bool {
    var after_count: usize = 0;
    for (function.blocks) |block| {
        if (block.id == dispatch.id or block.id == nonnull.id or block.id == null_block.id) continue;
        if (block.terminator == .fallthrough and block.instructions.len == 0 and block.successors.len == 0) {
            after_count += 1;
            continue;
        }
        if (block.terminator == .trap_) continue;
        return false;
    }
    return after_count == 1;
}

fn buildSwitch(function: *const mir.Function, dispatch: mir.Block) ?Plan {
    // Switch construction reserves block 1 as the after block and appends one
    // block per arm. A checked non-null fallback parameter contributes one
    // dedicated trap block, so the bounded family has four or five blocks.
    if ((function.blocks.len != 4 and function.blocks.len != 5) or dispatch.successors.len != 2) return null;
    const after = function.blocks[1];
    if (after.instructions.len != 0 or after.successors.len != 0 or after.terminator != .fallthrough) return null;
    const first = function.blocks[dispatch.successors[0]];
    const second = function.blocks[dispatch.successors[1]];
    if (!first.typed_id.isValid() or !second.typed_id.isValid()) return null;

    const marker = uniqueInstruction(dispatch, .binary) orelse return null;
    if (marker.result_ty != .branch or !std.mem.eql(u8, marker.detail, "switch_subject")) return null;
    const subject_type = uniqueTypeFactInBlock(function, dispatch, .switch_subject) orelse return null;
    if (!isNullablePointer(subject_type.value_ty)) return null;
    const subject = subjectForSpan(function, dispatch, subject_type.location.span_id) orelse return null;
    if (!dispatchContainsOnlySubjectWork(dispatch, subject)) return null;

    const first_marker = armMarker(first) orelse return null;
    const second_marker = armMarker(second) orelse return null;
    const arms = [_]struct { block: mir.Block, marker: []const u8 }{
        .{ .block = first, .marker = first_marker.detail },
        .{ .block = second, .marker = second_marker.detail },
    };
    var binding: ?Binding = null;
    var nonnull: ?mir.Block = null;
    var null_block: ?mir.Block = null;
    var then_return: ?ArmReturn = null;
    var otherwise: ?ArmReturn = null;
    for (arms) |arm| {
        if (std.mem.eql(u8, arm.marker, "_")) {
            const returned = zeroReturn(function, arm.block) orelse parameterReturn(function, arm.block) orelse return null;
            if (null_block != null) return null;
            null_block = arm.block;
            otherwise = returned;
        } else {
            if (nonnull != null) return null;
            const direct_binding = bindingInThen(function, arm.block, arm.marker);
            const returned_binding = bindingReturn(function, arm.block, arm.marker);
            const candidate = direct_binding orelse returned_binding orelse return null;
            if (!nullableSubjectMatchesBinding(subject_type.value_ty, candidate.pointer_ty)) return null;
            binding = candidate;
            nonnull = arm.block;
            then_return = if (direct_binding) |direct|
                .{ .operand = .{ .direct_call = thenCallForBinding(function, arm.block, direct) orelse return null }, .return_location = returnLocation(function, arm.block) orelse return null }
            else
                .{ .operand = .{ .binding = candidate }, .return_location = returnLocation(function, arm.block) orelse return null };
        }
    }
    const bound = binding orelse return null;
    const then = nonnull orelse return null;
    const null_arm = null_block orelse return null;
    const fallback = otherwise orelse return null;
    if ((function.blocks.len == 5) != (std.meta.activeTag(fallback.operand) == .parameter)) return null;
    return .{
        .form = .switch_,
        .dispatch_block = dispatch.typed_id,
        .nonnull_block = then.typed_id,
        .null_block = null_arm.typed_id,
        .subject = subject,
        .subject_type = subject_type,
        .binding = bound,
        .then_return = then_return orelse return null,
        .else_return = fallback,
    };
}

fn functionEffectsAreEmpty(function: *const mir.Function) bool {
    if (function.bounds_facts.len != 0 or function.range_facts.len != 0 or
        function.pointer_provenance_facts.len != 0 or
        function.ownership_events.len != 0 or function.ownership_cleanup_plan.actions.len != 0 or
        function.ownership_cleanup_plan.cancellations.len != 0) return false;
    for (function.trap_edges) |edge| if (edge.kind != .InvalidRepresentation) return false;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return false;
    return true;
}

fn bindingInThen(function: *const mir.Function, block: mir.Block, name: []const u8) ?Binding {
    const call = uniqueInstruction(block, .call) orelse return null;
    if (directCall(function, call) == null) return null;
    const argument_fact = uniqueDirectArgument(function, call.typed_callee_span_id, 0) orelse return null;
    const value_id = argument_fact.typed_operand_value_id;
    if (!value_id.isValid()) return null;
    const value_name = valueName(function, value_id) orelse return null;
    if (!std.mem.eql(u8, name, value_name)) return null;
    const argument_expr = instructionAtSpanOfKind(block, argument_fact.typed_span_id, .expr) orelse return null;
    if (argument_expr.kind != .expr or !argument_expr.typed_value_id.?.eql(value_id)) return null;
    if (!sameValueType(argument_expr.result_ty, argument_fact.result_ty)) return null;
    if (hasValueDeclaration(function, value_id)) return null;
    if (!isPointer(argument_expr.result_ty)) return null;
    return .{
        .name = value_name,
        .value_id = value_id,
        .pointer_ty = argument_expr.result_ty,
        .location = locationFromInstruction(function, argument_expr) orelse return null,
    };
}

fn thenCallForBinding(function: *const mir.Function, block: mir.Block, binding: Binding) ?DirectCallReturn {
    const call = uniqueInstruction(block, .call) orelse return null;
    const direct = directCall(function, call) orelse return null;
    const argument_fact = uniqueDirectArgument(function, call.typed_callee_span_id, 0) orelse return null;
    if (!argument_fact.typed_operand_value_id.eql(binding.value_id)) return null;
    if (countDirectArguments(function, call.typed_callee_span_id) != 1) return null;
    const argument_expr = instructionAtSpanOfKind(block, argument_fact.typed_span_id, .expr) orelse return null;
    if (argument_expr.kind != .expr or argument_expr.typed_value_id == null or !argument_expr.typed_value_id.?.eql(binding.value_id)) return null;
    if (!blockHasOnlyCallReturnWork(block, call)) return null;
    if (!bindingRepresentationMatches(function, block, binding)) return null;
    const returned = uniqueInstruction(block, .return_value) orelse return null;
    if (!returned.typed_value_operand_span_id.eql(call.typed_span_id) or !sameValueType(returned.result_ty, direct.result.value_ty)) return null;
    return .{
        .call = direct,
        .argument = binding,
    };
}

fn zeroReturn(function: *const mir.Function, block: mir.Block) ?ArmReturn {
    const returned = uniqueInstruction(block, .return_value) orelse return null;
    const value = instructionAtSpanOfKind(block, returned.typed_value_operand_span_id, .expr) orelse return null;
    if (value.kind != .expr or value.constant_usize_value != 0 or value.typed_value_id != null) return null;
    const value_type = uniqueTypeFact(function, .expression_result, value.typed_span_id) orelse return null;
    if (!sameValueType(returned.result_ty, value_type.value_ty)) return null;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .expr, .return_value, .target_type, .integer_literal_conversion => {},
        else => return null,
    };
    return .{
        .operand = .{ .integer_zero = locationFromInstruction(function, value) orelse return null },
        .return_location = locationFromInstruction(function, returned) orelse return null,
    };
}

fn bindingReturn(function: *const mir.Function, block: mir.Block, name: []const u8) ?Binding {
    const returned = uniqueInstruction(block, .return_value) orelse return null;
    const value = instructionAtSpanOfKind(block, returned.typed_value_operand_span_id, .expr) orelse return null;
    const value_id = value.typed_value_id orelse return null;
    if (!std.mem.eql(u8, valueName(function, value_id) orelse return null, name) or hasValueDeclaration(function, value_id) or !isPointer(value.result_ty)) return null;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .expr, .typed_load, .representation_check, .representation_use, .target_type, .return_value => {},
        else => return null,
    };
    return .{
        .name = name,
        .value_id = value_id,
        .pointer_ty = value.result_ty,
        .location = locationFromInstruction(function, value) orelse return null,
    };
}

fn parameterReturn(function: *const mir.Function, block: mir.Block) ?ArmReturn {
    const returned = uniqueInstruction(block, .return_value) orelse return null;
    const value = instructionAtSpanOfKind(block, returned.typed_value_operand_span_id, .expr) orelse return null;
    const value_id = value.typed_value_id orelse return null;
    const name = valueName(function, value_id) orelse return null;
    if (!hasParameter(function, value_id) or !isPointer(value.result_ty)) return null;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .expr, .typed_load, .representation_check, .representation_use, .target_type, .return_value => {},
        else => return null,
    };
    if (!parameterReturnHasExactRepresentationTrap(function, block, value)) return null;
    return .{
        .operand = .{ .parameter = .{
            .name = name,
            .value_id = value_id,
            .pointer_ty = value.result_ty,
            .location = locationFromInstruction(function, value) orelse return null,
            .requires_nonnull_check = true,
        } },
        .return_location = locationFromInstruction(function, returned) orelse return null,
    };
}

fn parameterReturnHasExactRepresentationTrap(function: *const mir.Function, block: mir.Block, value: mir.Instruction) bool {
    if (function.trap_edges.len != 1) return false;
    const edge = function.trap_edges[0];
    if (edge.kind != .InvalidRepresentation or edge.from_block != block.id or !edge.typed_span_id.eql(value.typed_span_id)) return false;
    if (edge.trap_block >= function.blocks.len) return false;
    return switch (function.blocks[edge.trap_block].terminator) {
        .trap_ => |kind| kind == .InvalidRepresentation,
        else => false,
    };
}

fn returnLocation(function: *const mir.Function, block: mir.Block) ?Location {
    const returned = uniqueInstruction(block, .return_value) orelse return null;
    return locationFromInstruction(function, returned);
}

fn subjectForSpan(function: *const mir.Function, dispatch: mir.Block, span_id: mir.SpanId) ?Subject {
    if (instructionAtSpanOfKind(dispatch, span_id, .call)) |call| return directCallSubject(function, dispatch, call);
    const instruction = instructionAtSpanOfKind(dispatch, span_id, .expr) orelse return null;
    if (instruction.typed_base_operand_span_id.isValid() or instruction.member_field_index != null) return fieldSubject(function, dispatch, instruction, span_id);
    if (instruction.typed_value_id == null) return null;
    const value_id = instruction.typed_value_id.?;
    const name = valueName(function, value_id) orelse return null;
    const location = locationFromInstruction(function, instruction) orelse return null;
    if (hasParameter(function, value_id)) return .{ .parameter = .{ .name = name, .value_id = value_id, .location = location } };
    if (hasValueDeclaration(function, value_id)) return null;
    return .{ .global = .{ .name = name, .value_id = value_id, .location = location } };
}

fn fieldSubject(function: *const mir.Function, dispatch: mir.Block, instruction: mir.Instruction, span_id: mir.SpanId) ?Subject {
    if (instruction.kind != .expr or !instruction.typed_span_id.eql(span_id) or
        !instruction.typed_base_operand_span_id.isValid() or instruction.member_field_index == null) return null;
    const base = instructionAtSpanOfKind(dispatch, instruction.typed_base_operand_span_id, .expr) orelse return null;
    const base_id = base.typed_value_id orelse return null;
    if (base.kind != .expr or !hasParameter(function, base_id)) return null;
    return .{ .field = .{
        .base_name = valueName(function, base_id) orelse return null,
        .base_value_id = base_id,
        .field_name = instruction.detail,
        .field_index = instruction.member_field_index.?,
        .base_location = locationFromInstruction(function, base) orelse return null,
        .location = locationFromInstruction(function, instruction) orelse return null,
    } };
}

fn directCallSubject(function: *const mir.Function, dispatch: mir.Block, call: mir.Instruction) ?Subject {
    const outer = directCall(function, call) orelse return null;
    const argument_count = countDirectArguments(function, call.typed_callee_span_id);
    if (argument_count == 0) return .{ .direct_call = .{ .call = outer } };
    if (argument_count != 1) return null;
    const argument = uniqueDirectArgument(function, call.typed_callee_span_id, 0) orelse return null;
    if (argument.typed_operand_value_id.isValid()) return null;
    const seed_instruction = instructionAtSpanOfKind(dispatch, argument.typed_span_id, .call) orelse return null;
    const seed = directCall(function, seed_instruction) orelse return null;
    if (countDirectArguments(function, seed_instruction.typed_callee_span_id) != 0) return null;
    return .{ .direct_call = .{ .call = outer, .seed = seed } };
}

fn dispatchContainsOnlySubjectWork(dispatch: mir.Block, subject: Subject) bool {
    var calls: usize = 0;
    for (dispatch.instructions) |instruction| {
        switch (instruction.kind) {
            .param, .binary, .target_type, .expr => {},
            .call => calls += 1,
            else => return false,
        }
    }
    const expected_calls: usize = switch (subject) {
        .direct_call => |call| if (call.seed == null) 1 else 2,
        else => 0,
    };
    return calls == expected_calls;
}

fn blockHasOnlyCallReturnWork(block: mir.Block, call: mir.Instruction) bool {
    for (block.instructions) |instruction| switch (instruction.kind) {
        .call => if (!instruction.typed_span_id.eql(call.typed_span_id)) return false,
        .expr, .target_type, .typed_load, .representation_check, .representation_use, .return_value => {},
        else => return false,
    };
    return true;
}

/// The representation checks created by binding a nullable pointer are not
/// arbitrary effects: they are the three MIR-owned operations that establish
/// the non-null pointer passed to the arm call.  Admit exactly that trio and
/// tie every identity back to the binding occurrence.
fn bindingRepresentationMatches(function: *const mir.Function, block: mir.Block, binding: Binding) bool {
    var loads: usize = 0;
    var checks: usize = 0;
    var uses: usize = 0;
    for (block.instructions) |instruction| {
        switch (instruction.kind) {
            .typed_load => {
                if (!representationInstructionMatches(function, instruction, binding, .typed_load, binding.name)) return false;
                loads += 1;
            },
            .representation_check => {
                if (!representationInstructionMatches(function, instruction, binding, .representation_check, "nonnull_pointer")) return false;
                checks += 1;
            },
            .representation_use => {
                if (!representationInstructionMatches(function, instruction, binding, .representation_use, "call_arg")) return false;
                uses += 1;
            },
            else => {},
        }
    }
    if (loads != 1 or checks != 1 or uses != 1 or function.representation_facts.len != 3) return false;

    for (function.representation_facts) |fact| {
        if (!representationFactMatches(function, fact, binding)) return false;
    }
    return true;
}

fn representationInstructionMatches(function: *const mir.Function, instruction: mir.Instruction, binding: Binding, kind: mir.Instruction.Kind, detail: []const u8) bool {
    if (instruction.kind != kind or !std.mem.eql(u8, instruction.detail, detail)) return false;
    if (instruction.typed_value_id == null or !instruction.typed_value_id.?.eql(binding.value_id)) return false;
    if (!instruction.typed_span_id.eql(binding.location.span_id) or !sameValueType(instruction.result_ty, binding.pointer_ty)) return false;
    return locationFromInstruction(function, instruction) != null;
}

fn representationFactMatches(function: *const mir.Function, fact: mir.RepresentationFact, binding: Binding) bool {
    const detail = switch (fact.kind) {
        .typed_load => binding.name,
        .representation_check => "nonnull_pointer",
        .representation_use => "call_arg",
        else => return false,
    };
    if (!std.mem.eql(u8, fact.detail, detail) or !std.mem.eql(u8, fact.value_id, binding.name)) return false;
    if (!fact.typed_value_id.eql(binding.value_id) or !fact.typed_span_id.eql(binding.location.span_id)) return false;
    if (!sameValueType(fact.result_ty, binding.pointer_ty) or !fact.typed_result_ty.isValid()) return false;
    if (fact.typed_result_ty.index() >= function.type_identities.len or fact.typed_span_id.index() >= function.span_identities.len) return false;
    const type_identity = function.type_identities[fact.typed_result_ty.index()];
    const span_identity = function.span_identities[fact.typed_span_id.index()];
    // The SpanId is the semantic identity. Some syntax transforms preserve a
    // legacy fact's raw source point without its FileId while the canonical
    // span table has already attached the per-file identity. Re-comparing the
    // duplicated raw coordinates rejects that valid production pipeline and
    // reintroduces the combined-source coupling this plan is meant to remove.
    return type_identity.id.eql(fact.typed_result_ty) and std.mem.eql(u8, type_identity.spelling, fact.result_ty.name()) and
        span_identity.id.eql(fact.typed_span_id);
}

fn armMarker(block: mir.Block) ?mir.Instruction {
    var marker: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .expr or instruction.result_ty != .branch) continue;
        if (marker != null) return null;
        marker = instruction;
    }
    return marker;
}

fn directCall(function: *const mir.Function, call: mir.Instruction) ?DirectCall {
    if (!call.typed_callee_span_id.isValid()) return null;
    const result = uniqueDirectResult(function, call.typed_callee_span_id) orelse return null;
    if (!std.mem.eql(u8, result.owner, call.detail) or !std.meta.eql(result.type_ref.value_ty, call.result_ty)) return null;
    const value_id = call.typed_value_id orelse return null;
    if (!value_id.isValid() or !std.mem.eql(u8, valueName(function, value_id) orelse return null, call.detail)) return null;
    return .{
        .callee_name = call.detail,
        .callee_value_id = value_id,
        .call_location = locationFromInstruction(function, call) orelse return null,
        .callee_location = locationForSpan(function, call.typed_callee_span_id) orelse return null,
        .result = result.type_ref,
    };
}

const OwnedTypeRef = struct { owner: []const u8, type_ref: TypeRef };

fn uniqueDirectResult(function: *const mir.Function, callee_span: mir.SpanId) ?OwnedTypeRef {
    var found: ?OwnedTypeRef = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_result or !fact.typed_span_id.eql(callee_span)) continue;
        const owner = fact.target_owner orelse return null;
        const type_ref = typeRef(function, fact) orelse return null;
        if (found != null) return null;
        found = .{ .owner = owner, .type_ref = type_ref };
    }
    return found;
}

fn uniqueDirectArgument(function: *const mir.Function, callee_span: mir.SpanId, index: usize) ?mir.TargetTypeFact {
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_argument or !fact.typed_callee_span_id.eql(callee_span) or fact.target_index != index) continue;
        if (typeRef(function, fact) == null or found != null) return null;
        found = fact;
    }
    return found;
}

fn countDirectArguments(function: *const mir.Function, callee_span: mir.SpanId) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.kind == .direct_call_argument and fact.typed_callee_span_id.eql(callee_span)) count += 1;
    }
    return count;
}

fn uniqueTypeFact(function: *const mir.Function, kind: mir.TargetTypeKind, span_id: mir.SpanId) ?TypeRef {
    var found: ?TypeRef = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or !fact.typed_span_id.eql(span_id)) continue;
        const candidate = typeRef(function, fact) orelse return null;
        if (found != null) return null;
        found = candidate;
    }
    return found;
}

fn uniqueTypeFactInBlock(function: *const mir.Function, block: mir.Block, kind: mir.TargetTypeKind) ?TypeRef {
    var found: ?TypeRef = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .target_type or !std.mem.eql(u8, instruction.detail, @tagName(kind))) continue;
        const candidate = uniqueTypeFact(function, kind, instruction.typed_span_id) orelse return null;
        if (found != null) return null;
        found = candidate;
    }
    return found;
}

fn typeRef(function: *const mir.Function, fact: mir.TargetTypeFact) ?TypeRef {
    if (!fact.typed_result_ty.isValid() or !fact.typed_span_id.isValid()) return null;
    if (fact.typed_result_ty.index() >= function.type_identities.len or fact.typed_span_id.index() >= function.span_identities.len) return null;
    const type_identity = function.type_identities[fact.typed_result_ty.index()];
    if (!type_identity.id.eql(fact.typed_result_ty) or !std.mem.eql(u8, type_identity.spelling, fact.result_ty.name())) return null;
    const span = function.span_identities[fact.typed_span_id.index()];
    if (!span.id.eql(fact.typed_span_id)) return null;
    return .{ .id = fact.typed_result_ty, .value_ty = fact.result_ty, .location = .{ .span_id = fact.typed_span_id, .source = span.source } };
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

fn instructionAtSpanOfKind(block: mir.Block, span_id: mir.SpanId, kind: mir.Instruction.Kind) ?mir.Instruction {
    if (!span_id.isValid()) return null;
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != kind or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn locationFromInstruction(function: *const mir.Function, instruction: mir.Instruction) ?Location {
    return locationForSpan(function, instruction.typed_span_id);
}

fn locationForSpan(function: *const mir.Function, span_id: mir.SpanId) ?Location {
    if (!span_id.isValid() or span_id.index() >= function.span_identities.len) return null;
    const identity = function.span_identities[span_id.index()];
    if (!identity.id.eql(span_id)) return null;
    return .{ .span_id = span_id, .source = identity.source };
}

fn valueName(function: *const mir.Function, value_id: mir.ValueId) ?[]const u8 {
    if (!value_id.isValid() or value_id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[value_id.index()];
    return if (identity.id.eql(value_id)) identity.spelling else null;
}

fn hasParameter(function: *const mir.Function, value_id: mir.ValueId) bool {
    const name = valueName(function, value_id) orelse return false;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .param and std.mem.eql(u8, instruction.detail, name)) return true;
    };
    return false;
}

fn hasValueDeclaration(function: *const mir.Function, value_id: mir.ValueId) bool {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if ((instruction.kind == .param or instruction.kind == .local) and instruction.typed_value_id != null and instruction.typed_value_id.?.eql(value_id)) {
            return true;
        }
    };
    return false;
}

fn isNullablePointer(ty: mir.ValueType) bool {
    return switch (ty) {
        .nullable_pointer => true,
        else => false,
    };
}

fn isPointer(ty: mir.ValueType) bool {
    return switch (ty) {
        .pointer => true,
        else => false,
    };
}

fn nullableSubjectMatchesBinding(subject: mir.ValueType, binding: mir.ValueType) bool {
    switch (subject) {
        .nullable_pointer => {},
        else => return false,
    }
    switch (binding) {
        .pointer => {},
        else => return false,
    }
    return std.mem.eql(u8, subject.name(), binding.name());
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}
