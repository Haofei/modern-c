const std = @import("std");
const mir = @import("mir.zig");

/// A deliberately small, backend-neutral execution plan for straight-line
/// void functions.  It is the first shared replacement for C/LLVM AST body
/// recognizers: admission and statement order are decided once from checked
/// MIR, while each backend only encodes the admitted operations.
pub const max_statements = 8;

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
