const std = @import("std");
const ast = @import("ast.zig");
const mir = @import("mir.zig");
const type_syntax = @import("type_syntax.zig");

/// A deliberately small, backend-neutral execution plan for straight-line
/// void functions.  It is the first shared replacement for C/LLVM AST body
/// recognizers: admission and statement order are decided once from checked
/// MIR, while each backend only encodes the admitted operations.
pub const max_statements = 8;
pub const max_arguments = 8;

pub const Location = struct {
    span_id: mir.SpanId,
    source: mir.SourcePoint,
};

pub const LocalDirectCall = struct {
    local_id: mir.ValueId,
    local_name: []const u8,
    local_location: Location,
    call_location: Location,
    result_fact: mir.TargetTypeFact,
};

pub const IndirectVoidCall = struct {
    callee_id: mir.ValueId,
    callee_name: []const u8,
    location: Location,
    callee_fact: mir.TargetTypeFact,
};

pub const Statement = union(enum) {
    discard_direct_call: Location,
    local_direct_call: LocalDirectCall,
    indirect_void_call: IndirectVoidCall,
};

pub const Plan = struct {
    statements: [max_statements]Statement = undefined,
    count: usize = 0,
};

pub const IndirectArgument = struct {
    index: usize,
    value_id: mir.ValueId,
    name: []const u8,
    type_fact: mir.TargetTypeFact,
};

pub const IndirectCallee = union(enum) {
    parameter: []const u8,
    global: []const u8,
    global_field: struct {
        root_name: []const u8,
        field_name: []const u8,
        field_index: usize,
        root_type_fact: mir.TargetTypeFact,
    },
};

pub const IndirectCallReturnPlan = struct {
    location: Location,
    callee: IndirectCallee,
    callee_fact: mir.TargetTypeFact,
    arguments: [max_arguments]IndirectArgument = undefined,
    argument_count: usize = 0,
};

/// Admit a single value-producing function-pointer call whose result is
/// returned immediately. Arguments are typed/indexed MIR facts and, in this
/// first slice, must be direct parameter values. The callee may be a parameter,
/// a global function-pointer object, or one field of a global struct object.
pub fn buildSingleBlockIndirectCallReturn(function: mir.Function) ?IndirectCallReturnPlan {
    if (function.return_ty == .void or function.blocks.len != 1) return null;
    if (function.trap_edges.len != 0 or function.pointer_provenance_facts.len != 0 or function.representation_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const block = function.blocks[0];
    if (block.terminator != .return_ or block.successors.len != 0) return null;

    var call_instruction: ?mir.Instruction = null;
    var return_instruction: ?mir.Instruction = null;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .expr => {},
        .indirect_call => {
            if (call_instruction != null) return null;
            call_instruction = instruction;
        },
        .return_value => {
            if (return_instruction != null) return null;
            return_instruction = instruction;
        },
        else => return null,
    };

    const call = call_instruction orelse return null;
    const returned = return_instruction orelse return null;
    if (!call.typed_callee_span_id.isValid() or !call.typed_callee_root_value_id.isValid() or !call.typed_callee_root_span_id.isValid()) return null;
    if (call.target_owner == null or call.typed_target_owner_id == null) return null;
    if (call.result_ty == .void or !sameRepresentationType(call.result_ty, returned.result_ty) or !sameRepresentationType(call.result_ty, function.return_ty)) return null;
    const returned_value_id = returned.typed_value_id orelse return null;
    const call_value_id = call.typed_value_id orelse return null;
    if (!returned_value_id.eql(call_value_id)) return null;

    const location = locationFromInstruction(call);
    const callee_fact = targetFactAt(function, .indirect_call_callee, location, null) orelse return null;
    const signature = switch (callee_fact.target_ty.kind) {
        .fn_pointer => |signature| signature,
        else => return null,
    };
    if (typeNameIsVoid(signature.ret.*) or signature.params.len > max_arguments or signature.params.len == 0) return null;
    if (!sameRepresentationType(callee_fact.result_ty, .value)) return null;

    var plan: IndirectCallReturnPlan = .{
        .location = location,
        .callee = undefined,
        .callee_fact = callee_fact,
    };
    if (!collectIndirectArguments(function, call, signature.params, &plan)) return null;
    plan.callee = indirectCalleePlan(function, call) orelse return null;
    return plan;
}

/// Admit only the initial statement-plan slice:
///
/// * one fallthrough block returning void;
/// * no traps, cleanup, provenance, or representation obligations;
/// * a discarded direct-call result; or
/// * a direct call initializing a local followed by a zero-argument ordinary
///   function-pointer call through that local/parameter.
///
/// This narrow contract keeps evaluation order explicit and fail-closed.  It
/// intentionally rejects closures, indirect arguments, reassignment, and all
/// control flow until MIR carries equally explicit operands for those forms.
pub fn buildSingleBlockVoid(function: mir.Function) ?Plan {
    if (function.return_ty != .void or function.blocks.len != 1) return null;
    if (function.trap_edges.len != 0 or function.pointer_provenance_facts.len != 0 or function.representation_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const block = function.blocks[0];
    if (block.terminator != .fallthrough or block.successors.len != 0) return null;

    var plan: Plan = .{};
    var pending_local: ?mir.Instruction = null;
    var saw_new_family = false;

    for (block.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .expr => {},
        .local => {
            const local_id = instruction.typed_value_id orelse return null;
            if (pending_local != null or !local_id.isValid()) return null;
            pending_local = instruction;
        },
        .call => {
            const location = locationFromInstruction(instruction);
            const result_fact = targetFactAt(function, .direct_call_result, location, instruction.detail) orelse return null;
            if (pending_local) |local| {
                const local_id = local.typed_value_id orelse return null;
                if (!local_id.isValid() or !localInitAt(function, local_id, location.source)) return null;
                if (result_fact.result_ty == .void) return null;
                if (plan.count >= max_statements) return null;
                plan.statements[plan.count] = .{ .local_direct_call = .{
                    .local_id = local_id,
                    .local_name = local.detail,
                    .local_location = locationFromInstruction(local),
                    .call_location = location,
                    .result_fact = result_fact,
                } };
                plan.count += 1;
                pending_local = null;
            } else {
                // Existing void-call recognizers already cover void results.
                // This plan's first direct-call family is the previously
                // missing observable discard of a non-void result.
                if (result_fact.result_ty == .void) return null;
                if (plan.count >= max_statements) return null;
                plan.statements[plan.count] = .{ .discard_direct_call = location };
                plan.count += 1;
                saw_new_family = true;
            }
        },
        .indirect_call => {
            if (pending_local != null) return null;
            const callee_id = instruction.typed_value_id orelse return null;
            if (!callee_id.isValid()) return null;
            const location = locationFromInstruction(instruction);
            const callee_fact = targetFactAt(function, .indirect_call_callee, location, null) orelse return null;
            const signature = switch (callee_fact.target_ty.kind) {
                .fn_pointer => |signature| signature,
                else => return null,
            };
            if (signature.params.len != 0 or !typeNameIsVoid(signature.ret.*)) return null;
            if (instruction.result_ty != .void) return null;
            if (!valueIdentityMatches(function, callee_id, instruction.detail)) return null;
            if (plan.count >= max_statements) return null;
            plan.statements[plan.count] = .{ .indirect_void_call = .{
                .callee_id = callee_id,
                .callee_name = instruction.detail,
                .location = location,
                .callee_fact = callee_fact,
            } };
            plan.count += 1;
            saw_new_family = true;
        },
        else => return null,
    };

    if (pending_local != null or plan.count == 0 or !saw_new_family) return null;
    if (!validateLocalUses(plan)) return null;
    return plan;
}

fn locationFromInstruction(instruction: mir.Instruction) Location {
    return .{
        .span_id = if ((instruction.kind == .call or instruction.kind == .indirect_call) and instruction.typed_callee_span_id.isValid())
            instruction.typed_callee_span_id
        else
            instruction.typed_span_id,
        .source = .{
            .line = instruction.line,
            .column = instruction.column,
            .offset = instruction.source_offset,
            .len = instruction.source_len,
        },
    };
}

fn sameLocation(location: Location, fact: mir.TargetTypeFact) bool {
    if (location.span_id.isValid() and fact.typed_span_id.isValid()) return location.span_id.eql(fact.typed_span_id);
    return sameSource(location.source, fact.source);
}

fn sameSource(a: mir.SourcePoint, b: mir.SourcePoint) bool {
    return a.line == b.line and a.column == b.column and a.offset == b.offset and a.len == b.len;
}

fn targetFactAt(function: mir.Function, kind: mir.TargetTypeKind, location: Location, owner: ?[]const u8) ?mir.TargetTypeFact {
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or !sameLocation(location, fact)) continue;
        if (owner) |expected| {
            if (!std.mem.eql(u8, fact.target_owner orelse "", expected)) continue;
        }
        return fact;
    }
    return null;
}

fn localInitAt(function: mir.Function, local_id: mir.ValueId, source: mir.SourcePoint) bool {
    for (function.ownership_events) |event| {
        if (event.kind != .init or !event.place.root_value_id.eql(local_id)) continue;
        // Ownership events do not yet carry SpanId.  Pair the typed local
        // identity with the exact source location; no offset arithmetic or
        // relative-column inference is used here.
        if (event.source.line == source.line and event.source.column == source.column) return true;
    }
    return false;
}

fn valueIdentityMatches(function: mir.Function, value_id: mir.ValueId, spelling: []const u8) bool {
    for (function.value_identities) |identity| {
        if (identity.id.eql(value_id)) return std.mem.eql(u8, identity.spelling, spelling);
    }
    return false;
}

fn validateLocalUses(plan: Plan) bool {
    var locals: [max_statements]LocalDirectCall = undefined;
    var used = [_]bool{false} ** max_statements;
    var local_count: usize = 0;
    for (plan.statements[0..plan.count]) |statement| switch (statement) {
        .local_direct_call => |local| {
            if (local_count >= locals.len) return false;
            locals[local_count] = local;
            local_count += 1;
        },
        .indirect_void_call => |call| {
            var local_index: ?usize = null;
            for (locals[0..local_count], 0..) |local, index| {
                if (local.local_id.eql(call.callee_id)) {
                    local_index = index;
                    break;
                }
            }
            if (local_index) |index| {
                if (!isZeroArgVoidFnPointer(locals[index].result_fact.target_ty) or !isZeroArgVoidFnPointer(call.callee_fact.target_ty)) return false;
                if (used[index]) return false;
                used[index] = true;
            } else if (local_count != 0) {
                // Keep this first slice exact: a plan that declares a callable
                // local must call that local, rather than an unrelated param.
                return false;
            }
        },
        .discard_direct_call => {},
    };
    for (used[0..local_count]) |was_used| if (!was_used) return false;
    return true;
}

fn collectIndirectArguments(function: mir.Function, call: mir.Instruction, params: []const ast.TypeExpr, plan: *IndirectCallReturnPlan) bool {
    var seen = [_]bool{false} ** max_arguments;
    const owner = call.target_owner orelse return false;
    const owner_id = call.typed_target_owner_id orelse return false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .indirect_call_argument) continue;
        if (!fact.typed_callee_span_id.eql(call.typed_callee_span_id)) continue;
        if (!std.mem.eql(u8, fact.target_owner orelse "", owner) or !fact.typed_target_owner_id.eql(owner_id)) continue;
        const index = fact.target_index orelse return false;
        if (index >= params.len or index >= max_arguments or seen[index]) return false;
        if (!type_syntax.sameTypeSyntax(fact.target_ty, params[index])) return false;
        const operand_name = valueIdentityName(function, fact.typed_operand_value_id) orelse return false;
        const param_ty = parameterType(function, operand_name) orelse return false;
        if (!sameRepresentationType(param_ty, fact.result_ty)) return false;
        if (!hasOperandInstruction(function, fact)) return false;
        plan.arguments[index] = .{
            .index = index,
            .value_id = fact.typed_operand_value_id,
            .name = operand_name,
            .type_fact = fact,
        };
        seen[index] = true;
        plan.argument_count += 1;
    }
    if (plan.argument_count != params.len) return false;
    for (seen[0..params.len]) |present| if (!present) return false;
    return true;
}

fn indirectCalleePlan(function: mir.Function, call: mir.Instruction) ?IndirectCallee {
    const root_name = valueIdentityName(function, call.typed_callee_root_value_id) orelse return null;
    const root_is_parameter = parameterType(function, root_name) != null;
    if (call.callee_field_index) |field_index| {
        if (root_is_parameter) return null;
        const root_type_fact = targetFactBySpan(function, .expression_result, call.typed_callee_root_span_id) orelse return null;
        return .{ .global_field = .{
            .root_name = root_name,
            .field_name = call.detail,
            .field_index = field_index,
            .root_type_fact = root_type_fact,
        } };
    }
    if (root_is_parameter) return .{ .parameter = root_name };
    return .{ .global = root_name };
}

fn targetFactBySpan(function: mir.Function, kind: mir.TargetTypeKind, span_id: mir.SpanId) ?mir.TargetTypeFact {
    if (!span_id.isValid()) return null;
    var found: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or !fact.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = fact;
    }
    return found;
}

fn hasOperandInstruction(function: mir.Function, fact: mir.TargetTypeFact) bool {
    var found = false;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind != .expr) continue;
        const value_id = instruction.typed_value_id orelse continue;
        if (!instruction.typed_span_id.eql(fact.typed_span_id) or !value_id.eql(fact.typed_operand_value_id)) continue;
        if (!sameRepresentationType(instruction.result_ty, fact.result_ty)) return false;
        if (found) return false;
        found = true;
    };
    return found;
}

fn parameterType(function: mir.Function, name: []const u8) ?mir.ValueType {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .param and std.mem.eql(u8, instruction.detail, name)) return instruction.result_ty;
    };
    return null;
}

fn valueIdentityName(function: mir.Function, id: mir.ValueId) ?[]const u8 {
    if (!id.isValid()) return null;
    for (function.value_identities) |identity| if (identity.id.eql(id)) return identity.spelling;
    return null;
}

fn sameRepresentationType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and
        std.mem.eql(u8, left.name(), right.name());
}

fn typeNameIsVoid(ty: anytype) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "void"),
        else => false,
    };
}

fn isZeroArgVoidFnPointer(ty: anytype) bool {
    return switch (ty.kind) {
        .fn_pointer => |signature| signature.params.len == 0 and typeNameIsVoid(signature.ret.*),
        else => false,
    };
}
