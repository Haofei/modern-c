const std = @import("std");
const ast = @import("ast.zig");
const mir = @import("mir.zig");
const type_syntax = @import("type_syntax.zig");

/// A deliberately small, backend-neutral execution plan for straight-line
/// void functions.  It is the first shared replacement for C/LLVM AST body
/// recognizers: admission and statement order are decided once from checked
/// MIR, while each backend only encodes the admitted operations.
pub const max_arguments = 8;
pub const max_place_projections = 4;

pub const Location = struct {
    span_id: mir.SpanId,
    source: mir.SourcePoint,
};

pub const DirectCallArgument = struct {
    index: usize,
    type_fact: mir.TargetTypeFact,
    location: Location,
    value: Value,

    pub const Value = union(enum) {
        parameter: struct {
            value_id: mir.ValueId,
            name: []const u8,
        },
        zero_arg_call: struct {
            callee_name: []const u8,
            callee_value_id: mir.ValueId,
            callee_fact: mir.TargetTypeFact,
            location: Location,
        },
    };
};

pub const DirectCallProjection = union(enum) {
    field: struct {
        field_name: []const u8,
        field_index: usize,
        type_fact: mir.TargetTypeFact,
        location: Location,
    },
    index: struct {
        operand_name: []const u8,
        operand_id: mir.ValueId,
        operand_fact: mir.TargetTypeFact,
        type_fact: mir.TargetTypeFact,
        constant_value: ?usize,
        static_bound: ?usize,
        checked: bool,
        location: Location,
    },

    pub fn resultType(self: DirectCallProjection) mir.ValueType {
        return switch (self) {
            .field => |field| field.type_fact.result_ty,
            .index => |index| index.type_fact.result_ty,
        };
    }
};

pub const DirectCallRepresentationCheck = struct {
    projection_index: usize,
    type_fact: mir.TargetTypeFact,
    location: Location,
    value_id: mir.ValueId,
    result_ty: mir.ValueType,
};

pub const DirectCallValuePlan = struct {
    callee_name: []const u8,
    callee_value_id: mir.ValueId,
    call_location: Location,
    result_fact: mir.TargetTypeFact,
    arguments: [max_arguments]DirectCallArgument = undefined,
    argument_count: usize = 0,
    projections: [max_place_projections]DirectCallProjection = undefined,
    projection_count: usize = 0,
};

pub const ForEachIterable = union(enum) {
    parameter: struct {
        name: []const u8,
        value_id: mir.ValueId,
        type_fact: mir.TargetTypeFact,
        location: Location,
    },
    direct_call: DirectCallValuePlan,

    pub fn resultType(self: ForEachIterable) mir.ValueType {
        return switch (self) {
            .parameter => |parameter| parameter.type_fact.result_ty,
            .direct_call => |call| if (call.projection_count == 0)
                call.result_fact.result_ty
            else
                call.projections[call.projection_count - 1].resultType(),
        };
    }
};

/// A fixed-array or slice `for` whose iterable is either a parameter or one direct
/// call (optionally followed by resolved field projections), whose body
/// returns the bound element, and whose after block returns one integer
/// literal. The loop binding and iterable root are carried by typed MIR
/// identities; backends never recover them from AST syntax or source spelling.
pub const ForEachRepresentationCheck = struct {
    type_fact: mir.TargetTypeFact,
    location: Location,
    value_id: mir.ValueId,
};

pub const SequenceForEachReturnPlan = struct {
    iterable: ForEachIterable,
    iterable_fact: mir.TargetTypeFact,
    element_fact: mir.TargetTypeFact,
    representation_check: ?ForEachRepresentationCheck = null,
    binding_name: []const u8,
    binding_id: mir.ValueId,
    body_return_location: Location,
    fallback: IntegerLiteralValue,
    fallback_return_location: Location,

    pub fn iterableType(self: SequenceForEachReturnPlan) mir.ValueType {
        return self.iterable.resultType();
    }
};

pub const LoopControl = enum { break_, continue_ };

/// A direct projection of the length member of one slice parameter. The
/// non-null representation check is proven by the plan and is statically
/// elided by both backends: reading a slice's stored length never dereferences
/// its data pointer.
pub const SequenceForEachUpdatePlan = struct {
    pub const Update = union(enum) {
        replace_with_element,
        checked_add_element: struct {
            operation_fact: mir.TargetTypeFact,
            location: Location,
        },
    };

    iterable: ForEachIterable,
    iterable_fact: mir.TargetTypeFact,
    element_fact: mir.TargetTypeFact,
    representation_check: ForEachRepresentationCheck,
    binding_name: []const u8,
    binding_id: mir.ValueId,
    local_name: []const u8,
    local_id: mir.ValueId,
    local_fact: mir.TargetTypeFact,
    initializer: IntegerLiteralValue,
    declaration_location: Location,
    assignment_location: Location,
    update: Update,
    control: LoopControl,
    control_location: Location,
    return_location: Location,
};

pub const IntegerLiteralValue = struct {
    value: usize,
    type_fact: mir.TargetTypeFact,
    location: Location,
};

/// Admit a slice `for` that maintains one scalar local, performs one assignment
/// from the element (or checked-adds it), then immediately breaks/continues and
/// finally returns that local. This is one bounded CFG family, not backend AST
/// reconstruction: local/binding generations, operand edges, traps and control
/// transfer all come from verified MIR identities.
pub fn buildSequenceForEachUpdate(function: mir.Function) ?SequenceForEachUpdatePlan {
    if (function.return_ty != .integer or (function.blocks.len != 4 and function.blocks.len != 5) or
        function.bounds_facts.len != 0 or function.pointer_provenance_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const entry = function.blocks[0];
    if (entry.terminator != .jump or entry.successors.len != 2) return null;
    var body_index: ?usize = null;
    var after_index: ?usize = null;
    for (function.blocks, 0..) |block, index| {
        if (std.mem.eql(u8, block.kind, "loop_body")) {
            if (body_index != null) return null;
            body_index = index;
        } else if (std.mem.eql(u8, block.kind, "loop_after")) {
            if (after_index != null) return null;
            after_index = index;
        }
    }
    const body = function.blocks[body_index orelse return null];
    const after = function.blocks[after_index orelse return null];
    if (body.terminator != .jump or !std.mem.eql(u8, after.kind, "loop_after") or
        after.terminator != .return_ or after.successors.len != 0) return null;

    var local_instruction: ?mir.Instruction = null;
    var loop_marker_count: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param, .integer_literal_conversion, .target_type, .typed_load, .representation_check, .expr => {},
        .local => {
            if (local_instruction != null) return null;
            local_instruction = instruction;
        },
        .binary => {
            if (!std.mem.eql(u8, instruction.detail, "for")) return null;
            loop_marker_count += 1;
        },
        else => return null,
    };
    if (loop_marker_count != 1) return null;
    const local = local_instruction orelse return null;
    const local_id = local.typed_value_id orelse return null;
    if (!local.typed_value_operand_span_id.isValid()) return null;
    const initializer_expr = expressionAtSpan(entry, local.typed_value_operand_span_id) orelse return null;
    const initializer_value = initializer_expr.constant_usize_value orelse return null;
    const local_fact = targetFactBySpan(function, .expression_result, local.typed_value_operand_span_id) orelse return null;
    if (local_fact.result_ty != .integer or !sameRepresentationType(local.result_ty, function.return_ty)) return null;

    var iterable_fact: ?mir.TargetTypeFact = null;
    var element_fact: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| switch (fact.kind) {
        .for_iterable => {
            if (iterable_fact != null) return null;
            iterable_fact = fact;
        },
        .for_element => {
            if (element_fact != null) return null;
            element_fact = fact;
        },
        else => {},
    };
    const iterable = iterable_fact orelse return null;
    const element = element_fact orelse return null;
    if (std.meta.activeTag(iterable.target_ty.kind) != .slice or !iterable.typed_span_id.eql(element.typed_span_id) or
        !element.typed_operand_value_id.isValid() or !sameRepresentationType(element.result_ty, function.return_ty)) return null;
    const iterable_expr = expressionAtSpan(entry, iterable.typed_span_id) orelse return null;
    const iterable_id = iterable_expr.typed_value_id orelse return null;
    const iterable_name = valueIdentityName(function, iterable_id) orelse return null;
    const iterable_parameter_ty = parameterType(function, iterable_name) orelse return null;
    if (!sameRepresentationType(iterable_parameter_ty, iterable.result_ty)) return null;
    const iterable_root_fact = targetFactBySpan(function, .expression_result, iterable.typed_span_id) orelse return null;
    const iterable_plan: ForEachIterable = .{ .parameter = .{
        .name = iterable_name,
        .value_id = iterable_id,
        .type_fact = iterable_root_fact,
        .location = locationFromInstruction(iterable_expr),
    } };
    var representation_check: ?ForEachRepresentationCheck = null;
    if (!findForEachRepresentationCheck(function, entry, iterable_plan, iterable, &representation_check) or representation_check == null) return null;

    const binding_id = element.typed_operand_value_id;
    const binding_name = valueIdentityName(function, binding_id) orelse return null;
    var assignment: ?mir.Instruction = null;
    var control_instruction: ?mir.Instruction = null;
    var add_instruction: ?mir.Instruction = null;
    for (body.instructions) |instruction| switch (instruction.kind) {
        .target_type, .expr, .add_overflow => {},
        .binary => {
            if (add_instruction != null or !std.mem.eql(u8, instruction.detail, "add")) return null;
            add_instruction = instruction;
        },
        .assign => {
            if (assignment != null) return null;
            assignment = instruction;
        },
        .control_transfer => {
            if (control_instruction != null) return null;
            control_instruction = instruction;
        },
        else => return null,
    };
    const store = assignment orelse return null;
    if (!store.typed_target_operand_span_id.isValid() or !store.typed_value_operand_span_id.isValid()) return null;
    const target_expr = expressionAtSpan(body, store.typed_target_operand_span_id) orelse return null;
    const target_id = target_expr.typed_value_id orelse return null;
    if (!target_id.eql(local_id) or !std.mem.eql(u8, target_expr.detail, local.detail)) return null;

    const control_inst = control_instruction orelse return null;
    const after_block_index = after.id;
    const control: LoopControl = if (std.mem.eql(u8, control_inst.detail, "break")) blk: {
        if (body.successors.len != 1 or body.terminator.jump != after_block_index or body.successors[0] != after_block_index) return null;
        break :blk .break_;
    } else if (std.mem.eql(u8, control_inst.detail, "continue")) blk: {
        if (body.successors.len != 2 or body.terminator.jump != entry.id) return null;
        var returns_to_entry = false;
        for (body.successors) |successor| {
            if (successor == entry.id) returns_to_entry = true;
        }
        if (!returns_to_entry) return null;
        break :blk .continue_;
    } else return null;

    const update: SequenceForEachUpdatePlan.Update = if (add_instruction) |add| blk: {
        if (control != .continue_ or !add.typed_span_id.eql(store.typed_value_operand_span_id) or
            !add.typed_left_operand_span_id.isValid() or !add.typed_right_operand_span_id.isValid()) return null;
        const left = expressionAtSpan(body, add.typed_left_operand_span_id) orelse return null;
        const right = expressionAtSpan(body, add.typed_right_operand_span_id) orelse return null;
        const left_id = left.typed_value_id orelse return null;
        const right_id = right.typed_value_id orelse return null;
        if (!left_id.eql(local_id) or !right_id.eql(binding_id)) return null;
        const operation_fact = targetFactBySpan(function, .expression_result, add.typed_span_id) orelse return null;
        if (!sameRepresentationType(operation_fact.result_ty, function.return_ty)) return null;
        break :blk .{ .checked_add_element = .{
            .operation_fact = operation_fact,
            .location = locationFromInstruction(add),
        } };
    } else blk: {
        if (control != .break_) return null;
        const value_expr = expressionAtSpan(body, store.typed_value_operand_span_id) orelse return null;
        const value_id = value_expr.typed_value_id orelse return null;
        if (!value_id.eql(binding_id)) return null;
        break :blk .replace_with_element;
    };

    var returned: ?mir.Instruction = null;
    for (after.instructions) |instruction| switch (instruction.kind) {
        .target_type, .expr => {},
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        else => return null,
    };
    const return_instruction = returned orelse return null;
    if (!return_instruction.typed_value_operand_span_id.isValid()) return null;
    const returned_expr = expressionAtSpan(after, return_instruction.typed_value_operand_span_id) orelse return null;
    const returned_id = returned_expr.typed_value_id orelse return null;
    if (!returned_id.eql(local_id) or !sameRepresentationType(return_instruction.result_ty, function.return_ty)) return null;

    const expected_traps: usize = switch (update) {
        .replace_with_element => 1,
        .checked_add_element => 2,
    };
    if (function.trap_edges.len != expected_traps) return null;
    switch (update) {
        .replace_with_element => {},
        .checked_add_element => {
            var overflow_count: usize = 0;
            for (function.trap_edges) |edge| {
                if (edge.from_block == body.id and edge.kind == .IntegerOverflow and edge.source == .checked_arithmetic) overflow_count += 1;
            }
            if (overflow_count != 1) return null;
        },
    }

    return .{
        .iterable = iterable_plan,
        .iterable_fact = iterable,
        .element_fact = element,
        .representation_check = representation_check.?,
        .binding_name = binding_name,
        .binding_id = binding_id,
        .local_name = local.detail,
        .local_id = local_id,
        .local_fact = local_fact,
        .initializer = .{
            .value = initializer_value,
            .type_fact = local_fact,
            .location = locationFromInstruction(initializer_expr),
        },
        .declaration_location = locationFromInstruction(local),
        .assignment_location = locationFromInstruction(store),
        .update = update,
        .control = control,
        .control_location = locationFromInstruction(control_inst),
        .return_location = locationFromInstruction(return_instruction),
    };
}

/// Admit the deliberately narrow CFG produced by:
///
///   for value in array_parameter { return value; }
///   for value in make_array(args).field { return value; }
///   return <integer literal>;
///
/// The iterable must be a fixed array or slice. Direct-call arguments may be function
/// parameters or zero-argument calls; the latter remain explicit in the plan
/// so both backends preserve their evaluation before the outer call. Slice
/// representation checks remain explicit in the plan. Loop-body side effects,
/// cleanup, and additional control flow fail closed.
pub fn buildSequenceForEachReturn(function: mir.Function) ?SequenceForEachReturnPlan {
    if (function.return_ty == .void or (function.blocks.len != 3 and function.blocks.len != 4)) return null;
    if (function.bounds_facts.len != 0 or function.pointer_provenance_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const entry = function.blocks[0];
    if (entry.terminator != .jump or (entry.successors.len != 1 and entry.successors.len != 2)) return null;
    var body_index_optional: ?usize = null;
    for (function.blocks, 0..) |block, index| {
        if (!std.mem.eql(u8, block.kind, "loop_body")) continue;
        if (body_index_optional != null) return null;
        body_index_optional = index;
    }
    const body_index = body_index_optional orelse return null;
    var body_is_successor = false;
    for (entry.successors) |successor| {
        if (successor == body_index) body_is_successor = true;
    }
    if (!body_is_successor) return null;
    const body = function.blocks[body_index];
    if (!std.mem.eql(u8, body.kind, "loop_body") or body.terminator != .return_ or body.successors.len != 0) return null;

    var after_index: ?usize = null;
    for (function.blocks, 0..) |block, index| {
        if (index == 0 or index == body_index) continue;
        switch (block.terminator) {
            .trap_ => continue,
            else => {},
        }
        if (after_index != null or !std.mem.eql(u8, block.kind, "loop_after") or block.terminator != .return_ or block.successors.len != 0) return null;
        after_index = index;
    }
    const after = function.blocks[after_index orelse return null];

    var calls: [max_arguments + 1]mir.Instruction = undefined;
    var call_count: usize = 0;
    var for_marker_count: usize = 0;
    var expression_count: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .typed_load, .representation_check => {},
        .binary => {
            if (!std.mem.eql(u8, instruction.detail, "for")) return null;
            for_marker_count += 1;
        },
        .expr => expression_count += 1,
        .call => {
            if (call_count >= calls.len) return null;
            calls[call_count] = instruction;
            call_count += 1;
        },
        else => return null,
    };
    if (for_marker_count != 1) return null;

    var iterable_fact: ?mir.TargetTypeFact = null;
    var element_fact: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| switch (fact.kind) {
        .for_iterable => {
            if (iterable_fact != null) return null;
            iterable_fact = fact;
        },
        .for_element => {
            if (element_fact != null) return null;
            element_fact = fact;
        },
        else => {},
    };
    const iterable = iterable_fact orelse return null;
    const element = element_fact orelse return null;
    const iterable_kind = std.meta.activeTag(iterable.target_ty.kind);
    if (!iterable.typed_span_id.isValid() or !iterable.typed_span_id.eql(element.typed_span_id) or
        (iterable_kind != .array and iterable_kind != .slice) or !element.typed_operand_value_id.isValid()) return null;

    const binding_name = valueIdentityName(function, element.typed_operand_value_id) orelse return null;
    var plan: SequenceForEachReturnPlan = .{
        .iterable = undefined,
        .iterable_fact = iterable,
        .element_fact = element,
        .binding_name = binding_name,
        .binding_id = element.typed_operand_value_id,
        .body_return_location = undefined,
        .fallback = undefined,
        .fallback_return_location = undefined,
    };

    if (call_count == 0) {
        const root = expressionAtSpan(entry, iterable.typed_span_id) orelse return null;
        const value_id = root.typed_value_id orelse return null;
        const name = valueIdentityName(function, value_id) orelse return null;
        const parameter_ty = parameterType(function, name) orelse return null;
        const root_fact = targetFactBySpan(function, .expression_result, iterable.typed_span_id) orelse return null;
        if (expression_count != 1 or !sameRepresentationType(parameter_ty, root_fact.result_ty) or
            !sameRepresentationType(root_fact.result_ty, iterable.result_ty)) return null;
        plan.iterable = .{ .parameter = .{
            .name = name,
            .value_id = value_id,
            .type_fact = root_fact,
            .location = locationFromInstruction(root),
        } };
    } else {
        var matched_call: ?DirectCallValuePlan = null;
        for (calls[0..call_count]) |call_instruction| {
            if (!call_instruction.typed_span_id.isValid() or !call_instruction.typed_callee_span_id.isValid()) continue;
            const callee_value_id = call_instruction.typed_value_id orelse continue;
            const callee_name = valueIdentityName(function, callee_value_id) orelse continue;
            if (!std.mem.eql(u8, callee_name, call_instruction.detail)) continue;
            const result_fact = targetFactBySpan(function, .direct_call_result, call_instruction.typed_callee_span_id) orelse continue;
            if (!std.mem.eql(u8, result_fact.target_owner orelse "", callee_name) or
                !result_fact.typed_target_owner_id.isValid() or
                !sameRepresentationType(result_fact.result_ty, call_instruction.result_ty)) continue;

            var candidate: DirectCallValuePlan = .{
                .callee_name = callee_name,
                .callee_value_id = callee_value_id,
                .call_location = locationFromInstruction(call_instruction),
                .result_fact = result_fact,
            };
            if (!collectDirectCallArguments(function, call_instruction, &candidate)) continue;
            if (!appendDirectCallProjection(function, entry, call_instruction, iterable.typed_span_id, &candidate, 0)) continue;
            if (candidate.projection_count == 0) {
                const result_kind = std.meta.activeTag(candidate.result_fact.target_ty.kind);
                if (result_kind != .array and result_kind != .slice) continue;
            }
            var projections_supported = true;
            for (candidate.projections[0..candidate.projection_count]) |projection| switch (projection) {
                .field => {},
                .index => projections_supported = false,
            };
            if (!projections_supported) continue;
            if (matched_call != null) return null;
            matched_call = candidate;
        }
        const root = matched_call orelse return null;
        if (expression_count != 1 + root.argument_count + root.projection_count) return null;
        plan.iterable = .{ .direct_call = root };
    }

    if (!sameRepresentationType(plan.iterableType(), iterable.result_ty)) return null;
    if (!attachForEachRepresentation(function, entry, &plan)) return null;

    var body_return: ?mir.Instruction = null;
    var body_expression_count: usize = 0;
    for (body.instructions) |instruction| switch (instruction.kind) {
        .target_type => {},
        .expr => body_expression_count += 1,
        .return_value => {
            if (body_return != null) return null;
            body_return = instruction;
        },
        else => return null,
    };
    const returned_element = body_return orelse return null;
    if (body_expression_count != 1 or !returned_element.typed_value_operand_span_id.isValid()) return null;
    const binding_expression = expressionAtSpan(body, returned_element.typed_value_operand_span_id) orelse return null;
    const returned_binding_id = binding_expression.typed_value_id orelse return null;
    if (!returned_binding_id.eql(plan.binding_id) or !std.mem.eql(u8, binding_expression.detail, plan.binding_name) or
        !sameRepresentationType(binding_expression.result_ty, element.result_ty) or
        !sameRepresentationType(returned_element.result_ty, function.return_ty) or
        !sameRepresentationType(element.result_ty, function.return_ty)) return null;
    plan.body_return_location = locationFromInstruction(returned_element);

    var fallback_return: ?mir.Instruction = null;
    var fallback_expression: ?mir.Instruction = null;
    for (after.instructions) |instruction| switch (instruction.kind) {
        .target_type, .integer_literal_conversion => {},
        .expr => {
            if (fallback_expression != null) return null;
            fallback_expression = instruction;
        },
        .return_value => {
            if (fallback_return != null) return null;
            fallback_return = instruction;
        },
        else => return null,
    };
    const fallback_return_instruction = fallback_return orelse return null;
    if (!fallback_return_instruction.typed_value_operand_span_id.isValid()) return null;
    const fallback_instruction = fallback_expression orelse return null;
    if (!fallback_instruction.typed_span_id.eql(fallback_return_instruction.typed_value_operand_span_id)) return null;
    const fallback_value = fallback_instruction.constant_usize_value orelse return null;
    const fallback_fact = targetFactBySpan(function, .expression_result, fallback_instruction.typed_span_id) orelse return null;
    if (fallback_fact.result_ty != .integer or !sameRepresentationType(fallback_return_instruction.result_ty, function.return_ty)) return null;
    plan.fallback = .{
        .value = fallback_value,
        .type_fact = fallback_fact,
        .location = locationFromInstruction(fallback_instruction),
    };
    plan.fallback_return_location = locationFromInstruction(fallback_return_instruction);
    return plan;
}

fn collectDirectCallArguments(function: mir.Function, call: mir.Instruction, plan: anytype) bool {
    var seen = [_]bool{false} ** max_arguments;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_argument or !fact.typed_callee_span_id.eql(call.typed_callee_span_id)) continue;
        if (!std.mem.eql(u8, fact.target_owner orelse "", plan.callee_name) or
            !fact.typed_target_owner_id.eql(plan.result_fact.typed_target_owner_id)) return false;
        const index = fact.target_index orelse return false;
        if (index >= max_arguments or seen[index]) return false;
        const location = locationForSpan(function, fact.typed_span_id) orelse return false;
        const value: DirectCallArgument.Value = if (fact.typed_operand_value_id.isValid()) blk: {
            const name = valueIdentityName(function, fact.typed_operand_value_id) orelse return false;
            const param_ty = parameterType(function, name) orelse return false;
            if (!sameRepresentationType(param_ty, fact.result_ty) or !hasOperandInstruction(function, fact)) return false;
            break :blk .{ .parameter = .{
                .value_id = fact.typed_operand_value_id,
                .name = name,
            } };
        } else blk: {
            var nested_call: ?mir.Instruction = null;
            for (function.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.kind != .call or !instruction.typed_span_id.eql(fact.typed_span_id)) continue;
                if (nested_call != null) return false;
                nested_call = instruction;
            };
            const nested = nested_call orelse return false;
            if (!nested.typed_callee_span_id.isValid()) return false;
            const nested_value_id = nested.typed_value_id orelse return false;
            const nested_name = valueIdentityName(function, nested_value_id) orelse return false;
            if (!std.mem.eql(u8, nested_name, nested.detail)) return false;
            const nested_fact = targetFactBySpan(function, .direct_call_result, nested.typed_callee_span_id) orelse return false;
            if (!std.mem.eql(u8, nested_fact.target_owner orelse "", nested_name) or
                !nested_fact.typed_target_owner_id.isValid() or
                !sameRepresentationType(nested_fact.result_ty, fact.result_ty) or
                !sameRepresentationType(nested.result_ty, fact.result_ty)) return false;
            for (function.target_type_facts) |nested_argument| {
                if (nested_argument.kind == .direct_call_argument and
                    nested_argument.typed_callee_span_id.eql(nested.typed_callee_span_id)) return false;
            }
            break :blk .{ .zero_arg_call = .{
                .callee_name = nested_name,
                .callee_value_id = nested_value_id,
                .callee_fact = nested_fact,
                .location = locationFromInstruction(nested),
            } };
        };
        plan.arguments[index] = .{
            .index = index,
            .type_fact = fact,
            .location = location,
            .value = value,
        };
        seen[index] = true;
        plan.argument_count = @max(plan.argument_count, index + 1);
    }
    for (seen[0..plan.argument_count]) |present| if (!present) return false;
    return true;
}

fn attachForEachRepresentation(function: mir.Function, entry: mir.Block, plan: *SequenceForEachReturnPlan) bool {
    const iterable_kind = std.meta.activeTag(plan.iterable_fact.target_ty.kind);
    if (iterable_kind == .array) {
        return function.blocks.len == 3 and entry.successors.len == 1 and
            function.trap_edges.len == 0 and function.representation_facts.len == 0;
    }
    if (iterable_kind != .slice or function.blocks.len != 4 or entry.successors.len != 2 or
        function.trap_edges.len != 1) return false;

    return findForEachRepresentationCheck(function, entry, plan.iterable, plan.iterable_fact, &plan.representation_check);
}

fn findForEachRepresentationCheck(
    function: mir.Function,
    entry: mir.Block,
    iterable: ForEachIterable,
    iterable_fact: mir.TargetTypeFact,
    out: *?ForEachRepresentationCheck,
) bool {
    if (std.meta.activeTag(iterable_fact.target_ty.kind) != .slice or
        function.representation_facts.len < 1 or function.representation_facts.len > 2) return false;

    const root_value_id = switch (iterable) {
        .parameter => |parameter| parameter.value_id,
        .direct_call => |call| call.callee_value_id,
    };
    if (!root_value_id.isValid()) return false;

    var check_instruction: ?mir.Instruction = null;
    var load_instruction_count: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .representation_check => {
            if (check_instruction != null or !instruction.typed_span_id.eql(iterable_fact.typed_span_id) or
                !std.mem.eql(u8, instruction.detail, "nonnull_pointer") or
                !sameRepresentationType(instruction.result_ty, iterable_fact.result_ty)) return false;
            const value_id = instruction.typed_value_id orelse return false;
            if (!value_id.eql(root_value_id)) return false;
            check_instruction = instruction;
        },
        .typed_load => {
            if (!instruction.typed_span_id.eql(iterable_fact.typed_span_id)) return false;
            const value_id = instruction.typed_value_id orelse return false;
            if (!value_id.eql(root_value_id) or !sameRepresentationType(instruction.result_ty, iterable_fact.result_ty)) return false;
            load_instruction_count += 1;
        },
        else => {},
    };
    const check = check_instruction orelse return false;
    if (load_instruction_count > 1) return false;

    var check_fact_count: usize = 0;
    var load_fact_count: usize = 0;
    for (function.representation_facts) |fact| {
        if (!fact.typed_span_id.eql(iterable_fact.typed_span_id) or
            !fact.typed_value_id.eql(root_value_id) or
            !sameRepresentationType(fact.result_ty, iterable_fact.result_ty)) return false;
        switch (fact.kind) {
            .representation_check => {
                if (!std.mem.eql(u8, fact.detail, "nonnull_pointer")) return false;
                check_fact_count += 1;
            },
            .typed_load => load_fact_count += 1,
            else => return false,
        }
    }
    if (check_fact_count != 1 or load_fact_count != load_instruction_count) return false;

    var matching_edge: ?mir.TrapEdge = null;
    for (function.trap_edges) |edge| {
        if (edge.from_block != entry.id or edge.kind != .InvalidRepresentation or edge.source != .representation_check or
            !edge.typed_span_id.eql(iterable_fact.typed_span_id)) continue;
        if (matching_edge != null or edge.trap_block >= function.blocks.len) return false;
        matching_edge = edge;
    }
    const edge = matching_edge orelse return false;
    switch (function.blocks[edge.trap_block].terminator) {
        .trap_ => |kind| if (kind != .InvalidRepresentation) return false,
        else => return false,
    }
    out.* = .{
        .type_fact = iterable_fact,
        .location = locationFromInstruction(check),
        .value_id = root_value_id,
    };
    return true;
}

fn validateNonnullRepresentationPromotion(
    function: mir.Function,
    entry: mir.Block,
    span_id: mir.SpanId,
    value_id: mir.ValueId,
    result_ty: mir.ValueType,
) bool {
    var typed_load_count: usize = 0;
    var check_count: usize = 0;
    for (entry.instructions) |instruction| {
        if (!instruction.typed_span_id.eql(span_id)) continue;
        switch (instruction.kind) {
            .typed_load => {
                const instruction_value_id = instruction.typed_value_id orelse return false;
                if (!instruction_value_id.eql(value_id) or
                    !sameRepresentationType(instruction.result_ty, result_ty)) return false;
                typed_load_count += 1;
            },
            .representation_check => {
                const instruction_value_id = instruction.typed_value_id orelse return false;
                if (!instruction_value_id.eql(value_id) or !std.mem.eql(u8, instruction.detail, "nonnull_pointer") or
                    !sameRepresentationType(instruction.result_ty, result_ty)) return false;
                check_count += 1;
            },
            else => {},
        }
    }
    if (typed_load_count != 1 or check_count != 1) return false;

    var typed_load_fact_count: usize = 0;
    var check_fact_count: usize = 0;
    for (function.representation_facts) |fact| {
        if (!fact.typed_span_id.eql(span_id) or !fact.typed_value_id.eql(value_id) or
            !sameRepresentationType(fact.result_ty, result_ty)) return false;
        switch (fact.kind) {
            .typed_load => typed_load_fact_count += 1,
            .representation_check => {
                if (!std.mem.eql(u8, fact.detail, "nonnull_pointer")) return false;
                check_fact_count += 1;
            },
            else => return false,
        }
    }
    if (typed_load_fact_count != 1 or check_fact_count != 1) return false;

    const edge = function.trap_edges[0];
    if (edge.from_block != entry.id or edge.kind != .InvalidRepresentation or edge.source != .representation_check or
        !edge.typed_span_id.eql(span_id) or edge.trap_block >= function.blocks.len) return false;
    switch (function.blocks[edge.trap_block].terminator) {
        .trap_ => |kind| return kind == .InvalidRepresentation,
        else => return false,
    }
}

fn appendDirectCallProjection(function: mir.Function, block: mir.Block, call: mir.Instruction, span_id: mir.SpanId, plan: anytype, depth: usize) bool {
    if (!span_id.isValid() or depth > max_place_projections) return false;

    if (span_id.eql(call.typed_span_id)) {
        const root = expressionAtSpan(block, call.typed_callee_span_id) orelse return false;
        const root_id = root.typed_value_id orelse return false;
        const root_fact = targetFactBySpan(function, .expression_result, span_id) orelse return false;
        return root_id.eql(plan.callee_value_id) and
            std.mem.eql(u8, root.detail, plan.callee_name) and
            sameRepresentationType(root_fact.result_ty, plan.result_fact.result_ty);
    }

    const instruction = placeInstructionAtSpan(block, span_id) orelse return false;
    const result_fact = targetFactBySpan(function, .expression_result, span_id) orelse return false;
    if (!sameRepresentationType(instruction.result_ty, result_fact.result_ty) or plan.projection_count >= max_place_projections) return false;

    if (instruction.kind == .index) {
        if (!instruction.typed_base_operand_span_id.isValid() or !instruction.typed_index_operand_span_id.isValid()) return false;
        if (!appendDirectCallProjection(function, block, call, instruction.typed_base_operand_span_id, plan, depth + 1)) return false;
        const operand = expressionAtSpan(block, instruction.typed_index_operand_span_id) orelse return false;
        const operand_id = operand.typed_value_id orelse return false;
        const operand_name = valueIdentityName(function, operand_id) orelse return false;
        const operand_ty = parameterType(function, operand_name) orelse return false;
        const operand_fact = targetFactBySpan(function, .expression_result, instruction.typed_index_operand_span_id) orelse return false;
        if (operand.constant_usize_value != null or operand_ty != .integer or operand_fact.result_ty != .integer) return false;
        if (!std.mem.eql(u8, instruction.detail, "bounds_checked") or instruction.constant_index_value != null or instruction.static_index_bound != null) return false;
        plan.projections[plan.projection_count] = .{ .index = .{
            .operand_name = operand_name,
            .operand_id = operand_id,
            .operand_fact = operand_fact,
            .type_fact = result_fact,
            .constant_value = null,
            .static_bound = null,
            .checked = true,
            .location = locationFromInstruction(instruction),
        } };
        plan.projection_count += 1;
        return true;
    }

    if (!instruction.typed_base_operand_span_id.isValid() or instruction.member_field_index == null or instruction.member_field_index.? == std.math.maxInt(usize)) return false;
    if (!appendDirectCallProjection(function, block, call, instruction.typed_base_operand_span_id, plan, depth + 1)) return false;
    plan.projections[plan.projection_count] = .{ .field = .{
        .field_name = instruction.detail,
        .field_index = instruction.member_field_index.?,
        .type_fact = result_fact,
        .location = locationFromInstruction(instruction),
    } };
    plan.projection_count += 1;
    return true;
}

const CheckedIndexIdentity = struct {
    expression_span_id: mir.SpanId,
    operand_span_id: mir.SpanId,
};

fn boundsTrapLocationsMatch(function: mir.Function, indexes: []const CheckedIndexIdentity) bool {
    if (function.trap_edges.len != indexes.len or function.bounds_facts.len != indexes.len) return false;
    if (function.blocks.len != indexes.len + 1 or function.blocks[0].successors.len != indexes.len) return false;
    for (function.blocks[1..]) |trap_block| switch (trap_block.terminator) {
        .trap_ => |kind| if (kind != .Bounds) return false,
        else => return false,
    };

    var matched = [_]bool{false} ** (max_place_projections * 3);
    if (indexes.len > matched.len) return false;
    for (function.trap_edges) |edge| {
        if (edge.from_block != function.blocks[0].id or edge.kind != .Bounds or edge.source != .bounds_check) return false;
        if (!edge.typed_span_id.isValid()) return false;
        if (edge.trap_block >= function.blocks.len or function.blocks[edge.trap_block].terminator != .trap_) return false;
        var found: ?usize = null;
        for (indexes, 0..) |identity, index| {
            if (matched[index]) continue;
            if (edge.typed_span_id.eql(identity.expression_span_id)) {
                found = index;
                break;
            }
        }
        const index = found orelse return false;
        matched[index] = true;
    }
    for (matched[0..indexes.len]) |present| if (!present) return false;

    @memset(matched[0..indexes.len], false);
    for (function.bounds_facts) |fact| {
        if (fact.kind != .index or !fact.typed_span_id.isValid()) return false;
        var found: ?usize = null;
        for (indexes, 0..) |identity, index| {
            if (matched[index]) continue;
            if (fact.typed_span_id.eql(identity.operand_span_id)) {
                found = index;
                break;
            }
        }
        const index = found orelse return false;
        matched[index] = true;
    }
    for (matched[0..indexes.len]) |present| if (!present) return false;
    return true;
}

fn placeInstructionAtSpan(block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var matched: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if ((instruction.kind != .expr and instruction.kind != .index) or !instruction.typed_span_id.eql(span_id)) continue;
        if (matched != null) return null;
        matched = instruction;
    }
    return matched;
}

fn expressionAtSpan(block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var matched: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .expr or !instruction.typed_span_id.eql(span_id)) continue;
        if (matched != null) return null;
        matched = instruction;
    }
    return matched;
}

fn localType(function: mir.Function, name: []const u8) ?mir.ValueType {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .local and std.mem.eql(u8, instruction.detail, name)) return instruction.result_ty;
    };
    return null;
}

fn locationForSpan(function: mir.Function, span_id: mir.SpanId) ?Location {
    if (!span_id.isValid() or span_id.index() >= function.span_identities.len) return null;
    return .{ .span_id = span_id, .source = function.span_identities[span_id.index()].source };
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
    // Plans are scoped to one MIR function, whose source identity is already
    // fixed by Function.typed_source_id. Compare only the local coordinates so
    // synthetic plan points remain compatible with interned per-file spans.
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

fn valueIdentityId(function: mir.Function, name: []const u8) ?mir.ValueId {
    var found: ?mir.ValueId = null;
    for (function.value_identities) |identity| {
        if (!std.mem.eql(u8, identity.spelling, name)) continue;
        if (found != null) return null;
        found = identity.id;
    }
    return found;
}

fn sameRepresentationType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and
        std.mem.eql(u8, left.name(), right.name());
}

fn samePointerShape(left: mir.PointerShape, right: mir.PointerShape) bool {
    return left.kind == right.kind and left.mutability == right.mutability and
        std.mem.eql(u8, left.child, right.child);
}

fn typeNameIsVoid(ty: anytype) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "void"),
        else => false,
    };
}
