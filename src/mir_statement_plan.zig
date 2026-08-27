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
pub const max_place_projections = 4;
pub const max_switch_arms = 8;
pub const max_aggregate_value_nodes = 32;

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
    projected_place: Place,
    local_function: struct {
        local_name: []const u8,
        local_id: mir.ValueId,
        function_name: []const u8,
        function_id: mir.ValueId,
        local_location: Location,
    },
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

pub const NullableTryPlan = struct {
    pub const Source = union(enum) {
        parameter: struct {
            name: []const u8,
            value_id: mir.ValueId,
            location: Location,
        },
        zero_arg_call: struct {
            callee_name: []const u8,
            callee_id: mir.ValueId,
            result_fact: mir.TargetTypeFact,
            location: Location,
        },
    };

    pub const Consumer = union(enum) {
        return_unwrapped,
        direct_call: struct {
            callee_name: []const u8,
            callee_id: mir.ValueId,
            result_fact: mir.TargetTypeFact,
            argument_fact: mir.TargetTypeFact,
            location: Location,
            returns_value: bool,
        },
    };

    source: Source,
    consumer: Consumer,
    nullable_fact: mir.TargetTypeFact,
    unwrapped_fact: mir.TargetTypeFact,
    try_value_id: mir.ValueId,
    try_location: Location,
    return_location: ?Location,
};

pub const ScalarSwitchArm = struct {
    block_id: mir.BlockId,
    patterns: [mir.Instruction.max_switch_patterns]mir.Instruction.SwitchPattern = [_]mir.Instruction.SwitchPattern{.unused} ** mir.Instruction.max_switch_patterns,
    pattern_count: usize,
    result: IntegerLiteralValue,
    location: Location,
};

pub const ScalarSwitchReturnPlan = struct {
    subject_name: []const u8,
    subject_id: mir.ValueId,
    subject_fact: mir.TargetTypeFact,
    subject_location: Location,
    arms: [max_switch_arms]ScalarSwitchArm = undefined,
    arm_count: usize = 0,
    default_arm_index: usize = std.math.maxInt(usize),
};

pub const PlaceRootKind = enum { parameter, local, global };

pub const PlaceProjection = union(enum) {
    field: struct {
        field_name: []const u8,
        field_index: usize,
        result_ty: mir.ValueType,
        location: Location,
    },
    constant_index: struct {
        index: usize,
        bound: usize,
        result_ty: mir.ValueType,
        checked: bool,
        location: Location,
        index_operand_span_id: mir.SpanId,
    },

    pub fn resultType(self: PlaceProjection) mir.ValueType {
        return switch (self) {
            .field => |field| field.result_ty,
            .constant_index => |index| index.result_ty,
        };
    }
};

pub const Place = struct {
    root_kind: PlaceRootKind = undefined,
    /// The source place begins at the pointee of a checked single pointer
    /// parameter (`p.field`).  MIR records the implicit dereference through a
    /// typed-load/representation edge at the root SpanId; backends must use the
    /// pointee type and pointer-style access for the first projection.
    root_indirect: bool = false,
    root_id: mir.ValueId = .invalid,
    root_name: []const u8 = "",
    root_ty: mir.ValueType = .unknown,
    root_type_fact: mir.TargetTypeFact = undefined,
    root_location: Location = undefined,
    projections: [max_place_projections]PlaceProjection = undefined,
    projection_count: usize = 0,

    pub fn resultType(self: Place) mir.ValueType {
        if (self.projection_count == 0) return self.root_ty;
        return self.projections[self.projection_count - 1].resultType();
    }
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

/// A direct call evaluated once and then projected by resolved fields and
/// checked indexes. Every edge is owned by typed MIR identities: the callee
/// occurrence, indexed arguments, projection operands, bounds facts, and any
/// representation check. Backends only encode this plan.
pub const DirectCallProjectedReturnPlan = struct {
    callee_name: []const u8,
    callee_value_id: mir.ValueId,
    call_location: Location,
    result_fact: mir.TargetTypeFact,
    arguments: [max_arguments]DirectCallArgument = undefined,
    argument_count: usize = 0,
    projections: [max_place_projections]DirectCallProjection = undefined,
    projection_count: usize = 0,
    representation_check: ?DirectCallRepresentationCheck = null,
    return_location: Location,

    pub fn resultType(self: DirectCallProjectedReturnPlan) mir.ValueType {
        if (self.projection_count == 0) return self.result_fact.result_ty;
        return self.projections[self.projection_count - 1].resultType();
    }
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

pub const AggregateValueNode = struct {
    type_fact: mir.TargetTypeFact,
    location: Location,
    operation: Operation,

    pub const Child = struct {
        node: usize,
        field_index: usize = std.math.maxInt(usize),
    };

    pub const Aggregate = struct {
        children: [mir.Instruction.max_aggregate_operands]Child = undefined,
        child_count: usize,
    };

    pub const Operation = union(enum) {
        parameter: struct {
            name: []const u8,
            value_id: mir.ValueId,
        },
        integer_literal: usize,
        array_literal: Aggregate,
        struct_literal: Aggregate,
    };
};

/// A bounded, backend-neutral aggregate value graph. Children are referenced
/// by node index so nested arrays/structs do not require recursive Zig types.
/// Admission currently accepts only parameter and integer leaves; calls,
/// loads, conversions with effects, and dynamic indexing remain fail-closed.
pub const AggregateValuePlan = struct {
    nodes: [max_aggregate_value_nodes]AggregateValueNode = undefined,
    count: usize = 0,
    root: usize = 0,

    pub fn resultType(self: AggregateValuePlan) mir.ValueType {
        if (self.count == 0 or self.root >= self.count) return .unknown;
        return self.nodes[self.root].type_fact.result_ty;
    }
};

pub const PlaceStoreValue = union(enum) {
    pub const max_array_elements: usize = mir.Instruction.max_aggregate_operands;

    parameter: struct {
        name: []const u8,
        value_id: mir.ValueId,
        ty: mir.ValueType,
        location: Location,
    },
    integer_literal: struct {
        value: usize,
        type_fact: mir.TargetTypeFact,
        location: Location,
    },
    array_literal: struct {
        type_fact: mir.TargetTypeFact,
        elements: [max_array_elements]IntegerLiteralValue = undefined,
        element_count: usize,
        location: Location,
    },
    struct_literal: struct {
        type_fact: mir.TargetTypeFact,
        fields: [max_array_elements]StructLiteralField = undefined,
        field_count: usize,
        location: Location,
    },

    pub fn resultType(self: PlaceStoreValue) mir.ValueType {
        return switch (self) {
            .parameter => |parameter| parameter.ty,
            .integer_literal => |literal| literal.type_fact.result_ty,
            .array_literal => |literal| literal.type_fact.result_ty,
            .struct_literal => |literal| literal.type_fact.result_ty,
        };
    }

    pub fn expressionCount(self: PlaceStoreValue) usize {
        return switch (self) {
            .parameter, .integer_literal => 1,
            .array_literal => |literal| 1 + literal.element_count,
            .struct_literal => |literal| 1 + literal.field_count,
        };
    }
};

pub const StructLiteralField = struct {
    field_index: usize,
    value: IntegerLiteralValue,
};

pub const IntegerLiteralValue = struct {
    value: usize,
    type_fact: mir.TargetTypeFact,
    location: Location,
};

pub fn buildNullableTry(function: mir.Function) ?NullableTryPlan {
    if (function.blocks.len != 3 or function.trap_edges.len != 2 or
        function.bounds_facts.len != 0 or function.pointer_provenance_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const entry = function.blocks[0];
    if (entry.terminator != .return_ and entry.terminator != .fallthrough) return null;
    if (entry.successors.len != 2) return null;
    for (function.blocks[1..]) |trap_block| {
        if (trap_block.instructions.len != 0 or trap_block.successors.len != 0) return null;
        switch (trap_block.terminator) {
            .trap_ => |kind| if (kind != .InvalidRepresentation and kind != .Unwrap) return null,
            else => return null,
        }
    }

    var result_check: ?mir.Instruction = null;
    var representation_check: ?mir.Instruction = null;
    var try_use: ?mir.Instruction = null;
    var call_argument_use: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    var calls: [2]mir.Instruction = undefined;
    var call_count: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .expr => {},
        .result_check => {
            if (result_check != null or !std.mem.eql(u8, instruction.detail, "try_handled")) return null;
            result_check = instruction;
        },
        .representation_check => {
            if (representation_check != null or !std.mem.eql(u8, instruction.detail, "nonnull_pointer")) return null;
            representation_check = instruction;
        },
        .representation_use => {
            if (std.mem.eql(u8, instruction.detail, "try_unwrap")) {
                if (try_use != null) return null;
                try_use = instruction;
            } else if (std.mem.eql(u8, instruction.detail, "call_arg")) {
                if (call_argument_use != null) return null;
                call_argument_use = instruction;
            } else return null;
        },
        .call => {
            if (call_count == calls.len) return null;
            calls[call_count] = instruction;
            call_count += 1;
        },
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        else => return null,
    };

    const checked = result_check orelse return null;
    const representation = representation_check orelse return null;
    const unwrapped_use = try_use orelse return null;
    if (!checked.typed_span_id.isValid() or !representation.typed_span_id.eql(checked.typed_span_id) or
        !unwrapped_use.typed_span_id.eql(checked.typed_span_id)) return null;
    const try_value_id = representation.typed_value_id orelse return null;
    const use_value_id = unwrapped_use.typed_value_id orelse return null;
    if (!try_value_id.isValid() or !use_value_id.eql(try_value_id)) return null;
    switch (representation.result_ty) {
        .pointer => {},
        else => return null,
    }
    if (!sameRepresentationType(representation.result_ty, unwrapped_use.result_ty)) return null;

    const nullable_fact = blk: {
        var found: ?mir.TargetTypeFact = null;
        for (function.target_type_facts) |fact| {
            if (fact.kind != .try_operand) continue;
            if (found != null) return null;
            found = fact;
        }
        break :blk found orelse return null;
    };
    const nullable_child = switch (nullable_fact.target_ty.kind) {
        .nullable => |child| child.*,
        else => return null,
    };
    if (std.meta.activeTag(nullable_child.kind) != .pointer or !nullable_fact.typed_span_id.isValid()) return null;
    const unwrapped_fact = targetFactBySpan(function, .expression_result, checked.typed_span_id) orelse return null;
    if (std.meta.activeTag(unwrapped_fact.target_ty.kind) != .pointer or
        !type_syntax.sameTypeSyntax(unwrapped_fact.target_ty, nullable_child) or
        !sameRepresentationType(unwrapped_fact.result_ty, representation.result_ty)) return null;

    var saw_invalid_representation = false;
    var saw_unwrap = false;
    for (function.trap_edges) |edge| {
        if (edge.from_block != entry.id or !edge.typed_span_id.eql(checked.typed_span_id) or
            edge.trap_block >= function.blocks.len) return null;
        switch (edge.kind) {
            .InvalidRepresentation => {
                if (saw_invalid_representation or edge.source != .representation_check) return null;
                saw_invalid_representation = true;
            },
            .Unwrap => {
                if (saw_unwrap or edge.source != .unwrap) return null;
                saw_unwrap = true;
            },
            else => return null,
        }
    }
    if (!saw_invalid_representation or !saw_unwrap) return null;

    const expected_representation_facts: usize = if (call_argument_use == null) 2 else 3;
    if (function.representation_facts.len != expected_representation_facts) return null;
    var saw_representation_check = false;
    var saw_try_use = false;
    var saw_call_use = false;
    for (function.representation_facts) |fact| {
        if (!fact.typed_span_id.eql(checked.typed_span_id) or !fact.typed_value_id.eql(try_value_id) or
            !sameRepresentationType(fact.result_ty, representation.result_ty)) return null;
        if (fact.kind == .representation_check and std.mem.eql(u8, fact.detail, "nonnull_pointer")) {
            if (saw_representation_check) return null;
            saw_representation_check = true;
        } else if (fact.kind == .representation_use and std.mem.eql(u8, fact.detail, "try_unwrap")) {
            if (saw_try_use) return null;
            saw_try_use = true;
        } else if (fact.kind == .representation_use and std.mem.eql(u8, fact.detail, "call_arg")) {
            if (saw_call_use) return null;
            saw_call_use = true;
        } else return null;
    }
    if (!saw_representation_check or !saw_try_use or saw_call_use != (call_argument_use != null)) return null;

    const source: NullableTryPlan.Source = blk: {
        if (expressionAtSpan(entry, nullable_fact.typed_span_id)) |operand| {
            const operand_id = operand.typed_value_id orelse return null;
            const name = valueIdentityName(function, operand_id) orelse return null;
            if (parameterType(function, name) == null or !std.mem.eql(u8, operand.detail, name)) return null;
            break :blk .{ .parameter = .{
                .name = name,
                .value_id = operand_id,
                .location = locationFromInstruction(operand),
            } };
        }
        var source_call: ?mir.Instruction = null;
        for (calls[0..call_count]) |call| {
            if (!call.typed_span_id.eql(nullable_fact.typed_span_id)) continue;
            if (source_call != null) return null;
            source_call = call;
        }
        const call = source_call orelse return null;
        const callee_id = call.typed_value_id orelse return null;
        const callee_name = valueIdentityName(function, callee_id) orelse return null;
        if (!std.mem.eql(u8, call.detail, callee_name) or !call.typed_callee_span_id.isValid()) return null;
        const result_fact = targetFactBySpan(function, .direct_call_result, call.typed_callee_span_id) orelse return null;
        if (!type_syntax.sameTypeSyntax(result_fact.target_ty, nullable_fact.target_ty) or
            !std.mem.eql(u8, result_fact.target_owner orelse "", callee_name)) return null;
        for (function.target_type_facts) |fact| {
            if (fact.kind == .direct_call_argument and fact.typed_callee_span_id.eql(call.typed_callee_span_id)) return null;
        }
        break :blk .{ .zero_arg_call = .{
            .callee_name = callee_name,
            .callee_id = callee_id,
            .result_fact = result_fact,
            .location = locationFromInstruction(call),
        } };
    };

    var return_location: ?Location = null;
    const consumer: NullableTryPlan.Consumer = if (call_argument_use == null) blk: {
        const expected_source_calls: usize = switch (source) {
            .parameter => 0,
            .zero_arg_call => 1,
        };
        if (call_count != expected_source_calls) return null;
        const ret = returned orelse return null;
        const returned_id = ret.typed_value_id orelse return null;
        if (!returned_id.eql(try_value_id) or !sameRepresentationType(ret.result_ty, function.return_ty) or
            function.return_ty == .void or entry.terminator != .return_) return null;
        return_location = locationFromInstruction(ret);
        break :blk .return_unwrapped;
    } else blk: {
        const call_use = call_argument_use.?;
        if (!call_use.typed_span_id.eql(checked.typed_span_id)) return null;
        var argument_fact: ?mir.TargetTypeFact = null;
        for (function.target_type_facts) |fact| {
            if (fact.kind != .direct_call_argument or !fact.typed_span_id.eql(checked.typed_span_id)) continue;
            if (argument_fact != null or fact.target_index != 0) return null;
            argument_fact = fact;
        }
        const argument = argument_fact orelse return null;
        if ((argument.typed_operand_value_id.isValid() and !argument.typed_operand_value_id.eql(try_value_id)) or
            !type_syntax.sameTypeSyntax(argument.target_ty, unwrapped_fact.target_ty)) return null;
        var consumer_call: ?mir.Instruction = null;
        for (calls[0..call_count]) |call| {
            if (!call.typed_callee_span_id.eql(argument.typed_callee_span_id)) continue;
            if (consumer_call != null) return null;
            consumer_call = call;
        }
        const call = consumer_call orelse return null;
        const callee_id = call.typed_value_id orelse return null;
        const callee_name = valueIdentityName(function, callee_id) orelse return null;
        if (!std.mem.eql(u8, call.detail, callee_name)) return null;
        const result_fact = targetFactBySpan(function, .direct_call_result, call.typed_callee_span_id) orelse return null;
        const returns_value = result_fact.result_ty != .void;
        if (returns_value) {
            const ret = returned orelse return null;
            const returned_id = ret.typed_value_id orelse return null;
            if (!returned_id.eql(callee_id) or entry.terminator != .return_ or
                !sameRepresentationType(result_fact.result_ty, function.return_ty)) return null;
            return_location = locationFromInstruction(ret);
        } else if (returned != null or entry.terminator != .fallthrough or function.return_ty != .void) return null;
        break :blk .{ .direct_call = .{
            .callee_name = callee_name,
            .callee_id = callee_id,
            .result_fact = result_fact,
            .argument_fact = argument,
            .location = locationFromInstruction(call),
            .returns_value = returns_value,
        } };
    };

    return .{
        .source = source,
        .consumer = consumer,
        .nullable_fact = nullable_fact,
        .unwrapped_fact = unwrapped_fact,
        .try_value_id = try_value_id,
        .try_location = locationFromInstruction(checked),
        .return_location = return_location,
    };
}

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

/// Admit an exhaustive scalar switch whose subject is one parameter and whose
/// arms return non-negative integer literals. The arm patterns are normalized
/// MIR payloads, so neither backend consults switch syntax or source spelling.
pub fn buildScalarSwitchReturn(function: mir.Function) ?ScalarSwitchReturnPlan {
    if (function.return_ty == .void or function.blocks.len < 4) return null;
    if (function.trap_edges.len != 0 or function.pointer_provenance_facts.len != 0 or function.representation_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const entry = function.blocks[0];
    if (entry.terminator != .switch_ or entry.successors.len < 2 or entry.successors.len > max_switch_arms) return null;

    var switch_marker_count: usize = 0;
    for (entry.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .expr => {},
        .binary => {
            if (!std.mem.eql(u8, instruction.detail, "switch_subject")) return null;
            switch_marker_count += 1;
        },
        else => return null,
    };
    if (switch_marker_count != 1) return null;

    var subject_fact: ?mir.TargetTypeFact = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .switch_subject) continue;
        if (subject_fact != null or !fact.typed_span_id.isValid() or fact.result_ty != .integer) return null;
        subject_fact = fact;
    }
    const fact = subject_fact orelse return null;
    const subject_instruction = expressionAtSpan(entry, fact.typed_span_id) orelse return null;
    const subject_id = subject_instruction.typed_value_id orelse return null;
    const subject_name = valueIdentityName(function, subject_id) orelse return null;
    const subject_ty = parameterType(function, subject_name) orelse return null;
    if (subject_ty != .integer or subject_instruction.result_ty != .integer) return null;

    var plan: ScalarSwitchReturnPlan = .{
        .subject_name = subject_name,
        .subject_id = subject_id,
        .subject_fact = fact,
        .subject_location = locationFromInstruction(subject_instruction),
    };
    var seen_blocks = [_]bool{false} ** (max_switch_arms + 2);
    if (function.blocks.len > seen_blocks.len) return null;
    seen_blocks[0] = true;

    var after_count: usize = 0;
    for (function.blocks[1..]) |block| {
        if (!std.mem.eql(u8, block.kind, "switch_after")) continue;
        if (block.terminator != .fallthrough or block.successors.len != 0 or block.instructions.len != 0) return null;
        if (block.id >= seen_blocks.len) return null;
        seen_blocks[block.id] = true;
        after_count += 1;
    }
    if (after_count != 1) return null;

    for (entry.successors) |successor| {
        if (successor >= function.blocks.len or successor >= seen_blocks.len or seen_blocks[successor]) return null;
        const arm_block = function.blocks[successor];
        if (!std.mem.eql(u8, arm_block.kind, "switch_arm") or arm_block.terminator != .return_ or arm_block.successors.len != 0) return null;
        if (plan.arm_count >= plan.arms.len) return null;

        var marker: ?mir.Instruction = null;
        var returned: ?mir.Instruction = null;
        for (arm_block.instructions) |instruction| switch (instruction.kind) {
            .target_type, .integer_literal_conversion => {},
            .expr => if (instruction.result_ty == .branch) {
                if (marker != null) return null;
                marker = instruction;
            },
            .return_value => {
                if (returned != null or !instruction.typed_value_operand_span_id.isValid()) return null;
                returned = instruction;
            },
            else => return null,
        };
        const arm_marker = marker orelse return null;
        if (arm_marker.typed_switch_pattern_count == 0) return null;
        const return_instruction = returned orelse return null;
        const result_instruction = expressionAtSpan(arm_block, return_instruction.typed_value_operand_span_id) orelse return null;
        const result_value = result_instruction.constant_usize_value orelse return null;
        const result_fact = targetFactBySpan(function, .expression_result, return_instruction.typed_value_operand_span_id) orelse return null;
        if (!sameRepresentationType(result_fact.result_ty, function.return_ty) or !sameRepresentationType(return_instruction.result_ty, function.return_ty)) return null;

        const arm_index = plan.arm_count;
        plan.arms[arm_index] = .{
            .block_id = arm_block.typed_id,
            .patterns = arm_marker.typed_switch_patterns,
            .pattern_count = arm_marker.typed_switch_pattern_count,
            .result = .{
                .value = result_value,
                .type_fact = result_fact,
                .location = locationFromInstruction(result_instruction),
            },
            .location = locationFromInstruction(return_instruction),
        };

        var wildcard_count: usize = 0;
        for (plan.arms[arm_index].patterns[0..plan.arms[arm_index].pattern_count]) |pattern| switch (pattern) {
            .unused => return null,
            .wildcard => wildcard_count += 1,
            .scalar => |scalar| {
                for (plan.arms[0..arm_index]) |previous| for (previous.patterns[0..previous.pattern_count]) |other| switch (other) {
                    .scalar => |old| if (old.negative == scalar.negative and old.magnitude == scalar.magnitude) return null,
                    else => {},
                };
            },
        };
        if (wildcard_count != 0) {
            if (wildcard_count != 1 or plan.arms[arm_index].pattern_count != 1 or plan.default_arm_index != std.math.maxInt(usize)) return null;
            plan.default_arm_index = arm_index;
        }
        seen_blocks[successor] = true;
        plan.arm_count += 1;
    }

    if (plan.arm_count != entry.successors.len or plan.default_arm_index == std.math.maxInt(usize)) return null;
    for (seen_blocks[0..function.blocks.len]) |seen| if (!seen) return null;
    return plan;
}

pub const PlaceStore = struct {
    target: Place,
    value: PlaceStoreValue,
    location: Location,
};

pub const PlaceLocalInit = struct {
    name: []const u8,
    ty: mir.ValueType,
    value: Place,
    location: Location,
};

pub const PlaceReturnPlan = struct {
    local_init: ?PlaceLocalInit = null,
    store: ?PlaceStore = null,
    returned: Place,
    return_location: Location,
};

pub const LocalAggregateAssignmentReturnPlan = struct {
    local_name: []const u8,
    local_id: mir.ValueId,
    local_type_fact: mir.TargetTypeFact,
    declaration_location: Location,
    assignment_location: Location,
    value: PlaceStoreValue,
    return_location: Location,
};

pub const LocalAggregatePlaceUpdateReturnPlan = struct {
    local_name: []const u8,
    local_id: mir.ValueId,
    local_type_fact: mir.TargetTypeFact,
    declaration_location: Location,
    initializer: AggregateValuePlan,
    update: ?PlaceStore = null,
    returned: Place,
    return_location: Location,
};

/// Admit `return make_value(args).field[index]` without reopening the AST
/// function body. The first slice intentionally accepts only direct parameter
/// arguments and parameter index operands, which makes call and index
/// evaluation order explicit and excludes nested/effectful operands.
pub fn buildDirectCallProjectedReturn(function: mir.Function) ?DirectCallProjectedReturnPlan {
    if (function.return_ty == .void or function.blocks.len == 0) return null;
    if (function.pointer_provenance_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const block = function.blocks[0];
    if (block.terminator != .return_) return null;
    var call: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    var expression_count: usize = 0;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .cmp_bounds, .index, .typed_load, .representation_check => {},
        .expr => expression_count += 1,
        .call => {
            if (call != null) return null;
            call = instruction;
        },
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        else => return null,
    };

    const call_instruction = call orelse return null;
    const return_instruction = returned orelse return null;
    if (!call_instruction.typed_span_id.isValid() or !call_instruction.typed_callee_span_id.isValid()) return null;
    const callee_value_id = call_instruction.typed_value_id orelse return null;
    const callee_name = valueIdentityName(function, callee_value_id) orelse return null;
    if (!std.mem.eql(u8, callee_name, call_instruction.detail)) return null;
    const result_fact = targetFactBySpan(function, .direct_call_result, call_instruction.typed_callee_span_id) orelse return null;
    if (!std.mem.eql(u8, result_fact.target_owner orelse "", callee_name) or !result_fact.typed_target_owner_id.isValid()) return null;
    if (!sameRepresentationType(result_fact.result_ty, call_instruction.result_ty)) return null;
    if (!return_instruction.typed_value_operand_span_id.isValid()) return null;

    var plan: DirectCallProjectedReturnPlan = .{
        .callee_name = callee_name,
        .callee_value_id = callee_value_id,
        .call_location = locationFromInstruction(call_instruction),
        .result_fact = result_fact,
        .return_location = locationFromInstruction(return_instruction),
    };
    if (!collectDirectCallArguments(function, call_instruction, &plan)) return null;
    if (!appendDirectCallProjection(function, block, call_instruction, return_instruction.typed_value_operand_span_id, &plan, 0)) return null;
    if (plan.projection_count == 0 or !sameRepresentationType(plan.resultType(), function.return_ty) or
        !sameRepresentationType(return_instruction.result_ty, function.return_ty)) return null;

    var consumed_expressions: usize = 1 + plan.argument_count;
    for (plan.projections[0..plan.projection_count]) |projection| switch (projection) {
        .field => consumed_expressions += 1,
        .index => consumed_expressions += 1,
    };
    if (consumed_expressions != expression_count) return null;
    if (!directCallProjectedTrapsMatch(function, &plan)) return null;
    return plan;
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

/// Admit a straight-line local aggregate generation: initialize one local from
/// a pure (possibly nested) aggregate value, optionally update one projected
/// field/index, and return a projection from the same local generation. The
/// local, update target, and returned place are joined by ValueId, never by
/// source spelling alone.
pub fn buildLocalAggregatePlaceUpdateReturn(function: mir.Function) ?LocalAggregatePlaceUpdateReturnPlan {
    if (function.return_ty == .void or function.blocks.len == 0) return null;
    if (function.pointer_provenance_facts.len != 0 or function.representation_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const block = function.blocks[0];
    if (block.terminator != .return_) return null;
    var local: ?mir.Instruction = null;
    var assignment: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    var expression_count: usize = 0;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .cmp_bounds, .index, .integer_literal_conversion => {},
        .expr => expression_count += 1,
        .local => {
            if (local != null) return null;
            local = instruction;
        },
        .assign => {
            if (assignment != null) return null;
            assignment = instruction;
        },
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        else => return null,
    };

    const local_instruction = local orelse return null;
    const local_id = local_instruction.typed_value_id orelse return null;
    if (!local_id.isValid() or !local_instruction.typed_value_operand_span_id.isValid()) return null;
    var initializer: AggregateValuePlan = .{};
    initializer.root = appendAggregateValueNode(function, block, local_instruction.typed_value_operand_span_id, &initializer, 0) orelse return null;
    if (initializer.count == 0 or !sameRepresentationType(initializer.resultType(), local_instruction.result_ty)) return null;

    const return_instruction = returned orelse return null;
    if (!return_instruction.typed_value_operand_span_id.isValid()) return null;
    const returned_place = buildPlace(function, block, return_instruction.typed_value_operand_span_id) orelse return null;
    if (returned_place.root_kind != .local or !returned_place.root_id.eql(local_id) or returned_place.projection_count == 0) return null;
    if (!placeHasAggregateIntermediates(returned_place) or !sameRepresentationType(returned_place.resultType(), function.return_ty)) return null;

    var plan: LocalAggregatePlaceUpdateReturnPlan = .{
        .local_name = local_instruction.detail,
        .local_id = local_id,
        .local_type_fact = initializer.nodes[initializer.root].type_fact,
        .declaration_location = locationFromInstruction(local_instruction),
        .initializer = initializer,
        .returned = returned_place,
        .return_location = locationFromInstruction(return_instruction),
    };
    var consumed_expressions = initializer.count + returned_place.projection_count + 1;
    if (assignment) |store_instruction| {
        if (!store_instruction.typed_target_operand_span_id.isValid() or !store_instruction.typed_value_operand_span_id.isValid()) return null;
        const target = buildPlace(function, block, store_instruction.typed_target_operand_span_id) orelse return null;
        if (target.root_kind != .local or !target.root_id.eql(local_id) or target.projection_count == 0) return null;
        if (!placeHasAggregateIntermediates(target) or !sameRepresentationType(target.resultType(), store_instruction.result_ty)) return null;
        const value = buildPlaceStoreValue(function, block, store_instruction.typed_value_operand_span_id) orelse return null;
        switch (value) {
            .parameter, .integer_literal => {},
            else => return null,
        }
        if (!sameRepresentationType(value.resultType(), target.resultType())) return null;
        plan.update = .{ .target = target, .value = value, .location = locationFromInstruction(store_instruction) };
        consumed_expressions += target.projection_count + 1 + value.expressionCount();
    }
    if (consumed_expressions != expression_count or !localAggregateBoundsTrapsMatch(function, plan)) return null;
    return plan;
}

/// Admit the common storage-generation sequence `var x: T = uninit; x =
/// aggregate; return x`. MIR owns the local identity, assignment edges,
/// aggregate operand order/field indices, and literal values. Backends only
/// materialize that verified value; they never reopen the function AST.
pub fn buildLocalAggregateAssignmentReturn(function: mir.Function) ?LocalAggregateAssignmentReturnPlan {
    if (function.return_ty == .void or function.blocks.len != 1 or function.trap_edges.len != 0) return null;
    if (function.pointer_provenance_facts.len != 0 or function.representation_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const block = function.blocks[0];
    if (block.terminator != .return_ or block.successors.len != 0) return null;
    var local: ?mir.Instruction = null;
    var assignment: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    var expression_count: usize = 0;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .target_type, .integer_literal_conversion => {},
        .expr => expression_count += 1,
        .local => {
            if (local != null) return null;
            local = instruction;
        },
        .assign => {
            if (assignment != null) return null;
            assignment = instruction;
        },
        .return_value => {
            if (returned != null) return null;
            returned = instruction;
        },
        else => return null,
    };

    const local_instruction = local orelse return null;
    const local_id = local_instruction.typed_value_id orelse return null;
    if (!local_instruction.typed_value_operand_span_id.isValid()) return null;
    const initializer = expressionAtSpan(block, local_instruction.typed_value_operand_span_id) orelse return null;
    if (!std.mem.eql(u8, initializer.detail, "uninit")) return null;

    const assignment_instruction = assignment orelse return null;
    if (!assignment_instruction.typed_target_operand_span_id.isValid() or !assignment_instruction.typed_value_operand_span_id.isValid()) return null;
    const target = buildPlace(function, block, assignment_instruction.typed_target_operand_span_id) orelse return null;
    if (target.root_kind != .local or target.projection_count != 0 or !target.root_type_fact.typed_span_id.isValid()) return null;
    const target_id = valueIdentityId(function, target.root_name) orelse return null;
    if (!target_id.eql(local_id)) return null;

    const value = buildPlaceStoreValue(function, block, assignment_instruction.typed_value_operand_span_id) orelse return null;
    switch (value) {
        .array_literal, .struct_literal => {},
        else => return null,
    }
    if (!sameRepresentationType(value.resultType(), target.resultType())) return null;

    const return_instruction = returned orelse return null;
    if (!return_instruction.typed_value_operand_span_id.isValid()) return null;
    const returned_place = buildPlace(function, block, return_instruction.typed_value_operand_span_id) orelse return null;
    if (returned_place.root_kind != .local or returned_place.projection_count != 0) return null;
    const returned_id = valueIdentityId(function, returned_place.root_name) orelse return null;
    if (!returned_id.eql(local_id) or !sameRepresentationType(returned_place.resultType(), function.return_ty)) return null;
    if (expression_count != 4 + value.expressionCount() - 1) return null;

    return .{
        .local_name = target.root_name,
        .local_id = local_id,
        .local_type_fact = target.root_type_fact,
        .declaration_location = locationFromInstruction(local_instruction),
        .assignment_location = locationFromInstruction(assignment_instruction),
        .value = value,
        .return_location = locationFromInstruction(return_instruction),
    };
}

/// Admit a straight-line aggregate-place body from typed MIR edges. Fields and
/// fixed-array constant indexes may be combined; checked indexes retain their
/// explicit Bounds trap edges. Every base/index/member, assignment target/value,
/// and return/value relationship is explicit in MIR; source text and relative
/// columns are never consulted.
pub fn buildSingleBlockPlaceReturn(function: mir.Function) ?PlaceReturnPlan {
    if (function.return_ty == .void or function.blocks.len == 0) return null;
    if (function.pointer_provenance_facts.len != 0 or function.representation_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const block = function.blocks[0];
    if (block.terminator != .return_) return null;

    var assignment: ?mir.Instruction = null;
    var returned: ?mir.Instruction = null;
    var expression_count: usize = 0;
    var local_count: usize = 0;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .param, .target_type, .cmp_bounds, .index, .integer_literal_conversion => {},
        .local => local_count += 1,
        .expr => expression_count += 1,
        .assign => {
            if (assignment != null or !instruction.typed_target_operand_span_id.isValid() or !instruction.typed_value_operand_span_id.isValid()) return null;
            assignment = instruction;
        },
        .return_value => {
            if (returned != null or !instruction.typed_value_operand_span_id.isValid()) return null;
            returned = instruction;
        },
        else => return null,
    };

    const return_instruction = returned orelse return null;
    var result: PlaceReturnPlan = .{
        .returned = buildPlace(function, block, return_instruction.typed_value_operand_span_id) orelse return null,
        .return_location = locationFromInstruction(return_instruction),
    };
    if (result.returned.projection_count == 0 or !placeHasAggregateIntermediates(result.returned) or !sameRepresentationType(result.returned.resultType(), function.return_ty)) return null;

    var consumed_expressions = result.returned.projection_count + 1;
    if (result.returned.root_kind == .local) {
        if (local_count != 1) return null;
        const local_instruction = localInstruction(function, result.returned.root_name) orelse return null;
        if (!local_instruction.typed_value_operand_span_id.isValid()) return null;
        const initializer = buildPlace(function, block, local_instruction.typed_value_operand_span_id) orelse return null;
        if (initializer.root_kind == .local or !sameRepresentationType(initializer.resultType(), result.returned.root_ty)) return null;
        result.local_init = .{
            .name = result.returned.root_name,
            .ty = result.returned.root_ty,
            .value = initializer,
            .location = locationFromInstruction(local_instruction),
        };
        consumed_expressions += initializer.projection_count + 1;
    } else if (local_count != 0) return null;
    if (assignment) |store_instruction| {
        const target = buildPlace(function, block, store_instruction.typed_target_operand_span_id) orelse return null;
        if (target.root_kind != .global or target.projection_count == 0 or !placeHasAggregateIntermediates(target) or !sameRepresentationType(target.resultType(), store_instruction.result_ty)) return null;
        const value = buildPlaceStoreValue(function, block, store_instruction.typed_value_operand_span_id) orelse return null;
        if (!sameRepresentationType(value.resultType(), target.resultType())) return null;
        result.store = .{
            .target = target,
            .value = value,
            .location = locationFromInstruction(store_instruction),
        };
        consumed_expressions += target.projection_count + 1 + value.expressionCount();
    }
    if (consumed_expressions != expression_count) return null;
    if (!placeBoundsTrapsMatch(function, result)) return null;
    return result;
}

/// Admit one void store through a checked pointer-root field place.  The
/// pointer dereference and field index are MIR identities, and the sole
/// InvalidRepresentation edge belongs to the pointer root.  This is the
/// statement counterpart of the pointer-root indirect-call plan.
fn buildPlaceStoreValue(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?PlaceStoreValue {
    const instruction = expressionAtSpan(block, span_id) orelse return null;
    if (instruction.typed_value_id) |value_id| {
        const name = valueIdentityName(function, value_id) orelse return null;
        const ty = parameterType(function, name) orelse return null;
        if (!sameRepresentationType(ty, instruction.result_ty)) return null;
        return .{ .parameter = .{
            .name = name,
            .value_id = value_id,
            .ty = ty,
            .location = locationFromInstruction(instruction),
        } };
    }
    if (std.mem.eql(u8, instruction.detail, "array_literal")) {
        if (instruction.typed_aggregate_operand_count == 0) return null;
        const type_fact = targetFactBySpan(function, .array_literal, span_id) orelse return null;
        if (type_fact.result_ty != .array) return null;
        var result: PlaceStoreValue = .{ .array_literal = .{
            .type_fact = type_fact,
            .element_count = instruction.typed_aggregate_operand_count,
            .location = locationFromInstruction(instruction),
        } };
        for (instruction.typed_aggregate_operand_span_ids[0..instruction.typed_aggregate_operand_count], 0..) |operand_span_id, index| {
            const operand = expressionAtSpan(block, operand_span_id) orelse return null;
            const operand_value = operand.constant_usize_value orelse return null;
            const operand_fact = targetFactBySpan(function, .expression_result, operand_span_id) orelse return null;
            if (operand_fact.result_ty != .integer) return null;
            result.array_literal.elements[index] = .{
                .value = operand_value,
                .type_fact = operand_fact,
                .location = locationFromInstruction(operand),
            };
        }
        return result;
    }
    if (std.mem.eql(u8, instruction.detail, "struct_literal")) {
        if (instruction.typed_aggregate_operand_count == 0) return null;
        const type_fact = targetFactBySpan(function, .struct_literal, span_id) orelse return null;
        if (type_fact.result_ty != .struct_) return null;
        var result: PlaceStoreValue = .{ .struct_literal = .{
            .type_fact = type_fact,
            .field_count = instruction.typed_aggregate_operand_count,
            .location = locationFromInstruction(instruction),
        } };
        for (instruction.typed_aggregate_operand_span_ids[0..instruction.typed_aggregate_operand_count], 0..) |operand_span_id, index| {
            const operand = expressionAtSpan(block, operand_span_id) orelse return null;
            const operand_value = operand.constant_usize_value orelse return null;
            const operand_fact = targetFactBySpan(function, .expression_result, operand_span_id) orelse return null;
            if (operand_fact.result_ty != .integer) return null;
            const field_index = instruction.typed_aggregate_field_indices[index];
            if (field_index == std.math.maxInt(usize)) return null;
            result.struct_literal.fields[index] = .{
                .field_index = field_index,
                .value = .{
                    .value = operand_value,
                    .type_fact = operand_fact,
                    .location = locationFromInstruction(operand),
                },
            };
        }
        return result;
    }
    const value = instruction.constant_usize_value orelse return null;
    const type_fact = targetFactBySpan(function, .expression_result, span_id) orelse return null;
    if (type_fact.result_ty != .integer) return null;
    return .{ .integer_literal = .{
        .value = value,
        .type_fact = type_fact,
        .location = locationFromInstruction(instruction),
    } };
}

fn appendAggregateValueNode(function: mir.Function, block: mir.Block, span_id: mir.SpanId, plan: *AggregateValuePlan, depth: usize) ?usize {
    if (!span_id.isValid() or depth >= max_aggregate_value_nodes or plan.count >= max_aggregate_value_nodes) return null;
    const instruction = expressionAtSpan(block, span_id) orelse return null;
    const type_fact_kind: mir.TargetTypeKind = if (std.mem.eql(u8, instruction.detail, "array_literal"))
        .array_literal
    else if (std.mem.eql(u8, instruction.detail, "struct_literal"))
        .struct_literal
    else
        .expression_result;
    const type_fact = targetFactBySpan(function, type_fact_kind, span_id) orelse return null;
    const converted_integer_literal = type_fact_kind == .expression_result and
        type_fact.result_ty == .integer and instruction.constant_usize_value != null;
    if (!sameRepresentationType(instruction.result_ty, type_fact.result_ty) and
        !(type_fact_kind == .struct_literal and instruction.result_ty == .value and type_fact.result_ty == .struct_) and
        !converted_integer_literal) return null;

    const operation: AggregateValueNode.Operation = if (std.mem.eql(u8, instruction.detail, "array_literal")) blk: {
        if (type_fact.result_ty != .array or instruction.typed_aggregate_operand_count == 0) return null;
        var aggregate: AggregateValueNode.Aggregate = .{ .child_count = instruction.typed_aggregate_operand_count };
        for (instruction.typed_aggregate_operand_span_ids[0..instruction.typed_aggregate_operand_count], 0..) |child_span, index| {
            aggregate.children[index] = .{ .node = appendAggregateValueNode(function, block, child_span, plan, depth + 1) orelse return null };
        }
        break :blk .{ .array_literal = aggregate };
    } else if (std.mem.eql(u8, instruction.detail, "struct_literal")) blk: {
        if (type_fact.result_ty != .struct_ or instruction.typed_aggregate_operand_count == 0) return null;
        var aggregate: AggregateValueNode.Aggregate = .{ .child_count = instruction.typed_aggregate_operand_count };
        for (instruction.typed_aggregate_operand_span_ids[0..instruction.typed_aggregate_operand_count], 0..) |child_span, index| {
            const field_index = instruction.typed_aggregate_field_indices[index];
            if (field_index == std.math.maxInt(usize)) return null;
            aggregate.children[index] = .{
                .node = appendAggregateValueNode(function, block, child_span, plan, depth + 1) orelse return null,
                .field_index = field_index,
            };
        }
        break :blk .{ .struct_literal = aggregate };
    } else if (instruction.typed_value_id) |value_id| blk: {
        const name = valueIdentityName(function, value_id) orelse return null;
        const parameter_ty = parameterType(function, name) orelse return null;
        if (!sameRepresentationType(parameter_ty, type_fact.result_ty)) return null;
        break :blk .{ .parameter = .{ .name = name, .value_id = value_id } };
    } else blk: {
        if (type_fact.result_ty != .integer) return null;
        break :blk .{ .integer_literal = instruction.constant_usize_value orelse return null };
    };

    const index = plan.count;
    plan.nodes[index] = .{ .type_fact = type_fact, .location = locationFromInstruction(instruction), .operation = operation };
    plan.count += 1;
    return index;
}

fn placeHasAggregateIntermediates(place: Place) bool {
    if (place.projection_count <= 1) return true;
    for (place.projections[0 .. place.projection_count - 1]) |projection| {
        const ty = projection.resultType();
        if (ty != .struct_ and ty != .array) return false;
    }
    return true;
}

fn placeRootRepresentationMatches(function: mir.Function, place: Place) bool {
    if (!place.root_indirect) return function.representation_facts.len == 0;
    if (!place.root_location.span_id.isValid() or !place.root_id.isValid() or
        function.representation_facts.len != 2 or function.trap_edges.len != 1 or
        function.bounds_facts.len != 0 or function.blocks.len != 2) return false;
    const entry = function.blocks[0];
    const trap = function.blocks[1];
    if (entry.successors.len != 1 or entry.successors[0] != trap.id or trap.instructions.len != 0 or
        trap.successors.len != 0) return false;
    switch (trap.terminator) {
        .trap_ => |kind| if (kind != .InvalidRepresentation) return false,
        else => return false,
    }
    const edge = function.trap_edges[0];
    if (edge.from_block != entry.id or edge.trap_block != trap.id or
        edge.kind != .InvalidRepresentation or edge.source != .representation_check or
        !edge.typed_span_id.eql(place.root_location.span_id)) return false;

    var saw_load = false;
    var saw_check = false;
    for (function.representation_facts) |fact| {
        if (!fact.typed_span_id.eql(place.root_location.span_id) or
            !fact.typed_value_id.eql(place.root_id) or
            !sameRepresentationType(fact.result_ty, place.root_ty)) return false;
        if (fact.kind == .typed_load and std.mem.eql(u8, fact.detail, place.root_name)) {
            if (saw_load) return false;
            saw_load = true;
        } else if (fact.kind == .representation_check and std.mem.eql(u8, fact.detail, "nonnull_pointer")) {
            if (saw_check) return false;
            saw_check = true;
        } else return false;
    }
    return saw_load and saw_check;
}

fn placeBoundsTrapsMatch(function: mir.Function, plan: PlaceReturnPlan) bool {
    var indexes: [max_place_projections * 3]CheckedIndexIdentity = undefined;
    var index_count: usize = 0;
    appendCheckedIndexLocations(plan.returned, &indexes, &index_count) orelse return false;
    if (plan.local_init) |local| appendCheckedIndexLocations(local.value, &indexes, &index_count) orelse return false;
    if (plan.store) |store| appendCheckedIndexLocations(store.target, &indexes, &index_count) orelse return false;
    return boundsTrapLocationsMatch(function, indexes[0..index_count]);
}

fn localAggregateBoundsTrapsMatch(function: mir.Function, plan: LocalAggregatePlaceUpdateReturnPlan) bool {
    var indexes: [max_place_projections * 2]CheckedIndexIdentity = undefined;
    var index_count: usize = 0;
    appendCheckedIndexLocations(plan.returned, &indexes, &index_count) orelse return false;
    if (plan.update) |update| appendCheckedIndexLocations(update.target, &indexes, &index_count) orelse return false;
    return boundsTrapLocationsMatch(function, indexes[0..index_count]);
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

fn directCallProjectedTrapsMatch(function: mir.Function, plan: *DirectCallProjectedReturnPlan) bool {
    var indexes: [max_place_projections]CheckedIndexIdentity = undefined;
    var index_count: usize = 0;
    for (plan.projections[0..plan.projection_count]) |projection| switch (projection) {
        .field => {},
        .index => |index| {
            if (!index.checked or index_count >= indexes.len or !index.location.span_id.isValid() or !index.operand_fact.typed_span_id.isValid()) return false;
            indexes[index_count] = .{
                .expression_span_id = index.location.span_id,
                .operand_span_id = index.operand_fact.typed_span_id,
            };
            index_count += 1;
        },
    };

    if (function.bounds_facts.len != index_count) return false;
    var bounds_seen = [_]bool{false} ** max_place_projections;
    for (function.bounds_facts) |fact| {
        if (fact.kind != .index or !fact.typed_span_id.isValid()) return false;
        var found: ?usize = null;
        for (indexes[0..index_count], 0..) |identity, index| {
            if (!bounds_seen[index] and fact.typed_span_id.eql(identity.operand_span_id)) {
                found = index;
                break;
            }
        }
        const index = found orelse return false;
        bounds_seen[index] = true;
    }
    for (bounds_seen[0..index_count]) |seen| if (!seen) return false;

    var representation_span_id: ?mir.SpanId = null;
    if (function.representation_facts.len != 0) {
        if (function.representation_facts.len < 2 or function.representation_facts.len > 3) return false;
        var load_fact: ?mir.RepresentationFact = null;
        var check_fact: ?mir.RepresentationFact = null;
        for (function.representation_facts) |fact| switch (fact.kind) {
            .typed_load => {
                if (load_fact != null) return false;
                load_fact = fact;
            },
            .representation_check => {
                if (check_fact) |existing| {
                    if (!existing.typed_span_id.eql(fact.typed_span_id) or
                        !existing.typed_value_id.eql(fact.typed_value_id) or
                        !sameRepresentationType(existing.result_ty, fact.result_ty)) return false;
                } else check_fact = fact;
            },
            else => return false,
        };
        const load = load_fact orelse return false;
        const check = check_fact orelse return false;
        if (!load.typed_span_id.isValid() or !load.typed_span_id.eql(check.typed_span_id) or
            !load.typed_value_id.isValid() or !load.typed_value_id.eql(check.typed_value_id) or
            !sameRepresentationType(load.result_ty, check.result_ty)) return false;
        var matched_projection: ?usize = null;
        var matched_type_fact: mir.TargetTypeFact = undefined;
        for (plan.projections[0..plan.projection_count], 0..) |projection, projection_index| switch (projection) {
            .field => |field| {
                if (!field.location.span_id.eql(load.typed_span_id) or !sameRepresentationType(field.type_fact.result_ty, load.result_ty)) continue;
                if (matched_projection != null) return false;
                matched_projection = projection_index;
                matched_type_fact = field.type_fact;
            },
            .index => |index| {
                if (!index.location.span_id.eql(load.typed_span_id) or !sameRepresentationType(index.type_fact.result_ty, load.result_ty)) continue;
                if (matched_projection != null) return false;
                matched_projection = projection_index;
                matched_type_fact = index.type_fact;
            },
        };
        const projection_index = matched_projection orelse return false;
        plan.representation_check = .{
            .projection_index = projection_index,
            .type_fact = matched_type_fact,
            .location = locationForSpan(function, load.typed_span_id) orelse return false,
            .value_id = load.typed_value_id,
            .result_ty = load.result_ty,
        };
        representation_span_id = load.typed_span_id;
    }

    const expected_traps = index_count + @intFromBool(representation_span_id != null);
    if (function.trap_edges.len != expected_traps or function.blocks.len != expected_traps + 1 or function.blocks[0].successors.len != expected_traps) return false;
    var matched_bounds = [_]bool{false} ** max_place_projections;
    var matched_representation = false;
    for (function.trap_edges) |edge| {
        if (edge.from_block != function.blocks[0].id or !edge.typed_span_id.isValid() or edge.trap_block >= function.blocks.len) return false;
        switch (function.blocks[edge.trap_block].terminator) {
            .trap_ => |kind| if (kind != edge.kind) return false,
            else => return false,
        }
        if (edge.kind == .Bounds and edge.source == .bounds_check) {
            var found: ?usize = null;
            for (indexes[0..index_count], 0..) |identity, index| {
                if (!matched_bounds[index] and edge.typed_span_id.eql(identity.expression_span_id)) {
                    found = index;
                    break;
                }
            }
            const index = found orelse return false;
            matched_bounds[index] = true;
        } else if (edge.kind == .InvalidRepresentation and edge.source == .representation_check) {
            const span = representation_span_id orelse return false;
            if (matched_representation or !edge.typed_span_id.eql(span)) return false;
            matched_representation = true;
        } else return false;
    }
    for (matched_bounds[0..index_count]) |seen| if (!seen) return false;
    return matched_representation == (representation_span_id != null);
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

fn appendCheckedIndexLocations(place: Place, indexes: []CheckedIndexIdentity, count: *usize) ?void {
    for (place.projections[0..place.projection_count]) |projection| switch (projection) {
        .field => {},
        .constant_index => |index| if (index.checked) {
            if (count.* >= indexes.len or !index.location.span_id.isValid() or !index.index_operand_span_id.isValid()) return null;
            indexes[count.*] = .{
                .expression_span_id = index.location.span_id,
                .operand_span_id = index.index_operand_span_id,
            };
            count.* += 1;
        },
    };
    return {};
}

/// Admit a single value-producing function-pointer call whose result is
/// returned immediately. Arguments are typed/indexed MIR facts and, in this
/// first slice, must be direct parameter values. The callee may be a parameter,
/// a global function-pointer object, or one field of a global struct object.
pub fn buildSingleBlockIndirectCallReturn(function: mir.Function) ?IndirectCallReturnPlan {
    if (function.return_ty == .void or function.blocks.len == 0) return null;
    if (function.pointer_provenance_facts.len != 0) return null;
    if (function.ownership_cleanup_plan.actions.len != 0 or function.ownership_cleanup_plan.cancellations.len != 0) return null;
    for (function.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return null;

    const block = function.blocks[0];
    if (block.terminator != .return_) return null;

    var call_instruction: ?mir.Instruction = null;
    var return_instruction: ?mir.Instruction = null;
    for (block.instructions) |instruction| switch (instruction.kind) {
        .param, .local, .target_type, .expr, .cmp_bounds, .index, .integer_literal_conversion, .typed_load, .representation_check => {},
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
    if (!call.typed_callee_span_id.isValid()) return null;
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
    plan.callee = indirectCalleePlan(function, call, callee_fact) orelse return null;
    switch (plan.callee) {
        .projected_place => |place| {
            if ((place.root_kind != .global and !place.root_indirect) or place.projection_count == 0 or
                place.resultType() != .value or !placeHasAggregateIntermediates(place)) return null;
            var indexes: [max_place_projections]CheckedIndexIdentity = undefined;
            var index_count: usize = 0;
            appendCheckedIndexLocations(place, &indexes, &index_count) orelse return null;
            if (place.root_indirect) {
                if (index_count != 0 or !placeRootRepresentationMatches(function, place)) return null;
            } else if (!boundsTrapLocationsMatch(function, indexes[0..index_count]) or
                !placeRootRepresentationMatches(function, place)) return null;
        },
        else => if (function.blocks.len != 1 or block.successors.len != 0 or
            function.trap_edges.len != 0 or function.bounds_facts.len != 0 or
            function.representation_facts.len != 0) return null,
    }
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

fn buildPlace(function: mir.Function, block: mir.Block, span_id: mir.SpanId) ?Place {
    var place: Place = .{};
    var root_set = false;
    if (!appendPlace(function, block, span_id, &place, &root_set, 0) or !root_set) return null;
    return place;
}

fn appendPlace(function: mir.Function, block: mir.Block, span_id: mir.SpanId, place: *Place, root_set: *bool, depth: usize) bool {
    if (!span_id.isValid() or depth > max_place_projections) return false;
    const instruction = placeInstructionAtSpan(block, span_id) orelse return false;
    const fact = targetFactBySpan(function, .expression_result, span_id) orelse return false;
    if (!sameRepresentationType(instruction.result_ty, fact.result_ty)) return false;

    if (instruction.kind == .index) {
        if (!instruction.typed_base_operand_span_id.isValid() or !instruction.typed_index_operand_span_id.isValid()) return false;
        const index = instruction.constant_index_value orelse return false;
        const bound = instruction.static_index_bound orelse return false;
        if (index >= bound or place.projection_count >= max_place_projections) return false;
        if (!appendPlace(function, block, instruction.typed_base_operand_span_id, place, root_set, depth + 1)) return false;
        const index_operand = expressionAtSpan(block, instruction.typed_index_operand_span_id) orelse return false;
        if (index_operand.result_ty != .integer and index_operand.result_ty != .value) return false;
        place.projections[place.projection_count] = .{ .constant_index = .{
            .index = index,
            .bound = bound,
            .result_ty = instruction.result_ty,
            .checked = std.mem.eql(u8, instruction.detail, "bounds_checked"),
            .location = locationFromInstruction(instruction),
            .index_operand_span_id = instruction.typed_index_operand_span_id,
        } };
        if (!std.mem.eql(u8, instruction.detail, "bounds_checked") and !std.mem.eql(u8, instruction.detail, "const_in_bounds")) return false;
        place.projection_count += 1;
        return true;
    }

    if (instruction.typed_base_operand_span_id.isValid()) {
        if (instruction.member_field_index == null or place.projection_count >= max_place_projections) return false;
        if (!appendPlace(function, block, instruction.typed_base_operand_span_id, place, root_set, depth + 1)) return false;
        place.projections[place.projection_count] = .{ .field = .{
            .field_name = instruction.detail,
            .field_index = instruction.member_field_index.?,
            .result_ty = instruction.result_ty,
            .location = locationFromInstruction(instruction),
        } };
        place.projection_count += 1;
        return true;
    }

    if (instruction.member_field_index != null or root_set.*) return false;
    const root_id = instruction.typed_value_id orelse return false;
    const root_name = valueIdentityName(function, root_id) orelse return false;
    if (!std.mem.eql(u8, root_name, instruction.detail)) return false;
    if (localType(function, root_name)) |local_ty| {
        if (!sameRepresentationType(local_ty, instruction.result_ty)) return false;
        place.root_kind = .local;
    } else if (parameterType(function, root_name)) |parameter_ty| {
        if (!sameRepresentationType(parameter_ty, instruction.result_ty)) return false;
        place.root_kind = .parameter;
    } else {
        place.root_kind = .global;
    }
    place.root_name = root_name;
    place.root_id = root_id;
    place.root_ty = instruction.result_ty;
    place.root_type_fact = fact;
    if (place.root_ty != .struct_ and place.root_ty != .array) {
        const pointer_shape = switch (place.root_ty) {
            .pointer => |shape| shape,
            else => return false,
        };
        if (place.root_kind != .parameter or pointer_shape.kind != .single or
            std.meta.activeTag(fact.target_ty.kind) != .pointer) return false;
        place.root_indirect = true;
    }
    place.root_location = locationFromInstruction(instruction);
    root_set.* = true;
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

fn localInstruction(function: mir.Function, name: []const u8) ?mir.Instruction {
    var matched: ?mir.Instruction = null;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind != .local or !std.mem.eql(u8, instruction.detail, name)) continue;
        if (matched != null) return null;
        matched = instruction;
    };
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

fn indirectCalleePlan(function: mir.Function, call: mir.Instruction, callee_fact: mir.TargetTypeFact) ?IndirectCallee {
    if (buildPlace(function, function.blocks[0], callee_fact.typed_span_id)) |place| {
        return .{ .projected_place = place };
    }
    if (!call.typed_callee_root_value_id.isValid() or !call.typed_callee_root_span_id.isValid()) return null;
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
    if (localInstruction(function, root_name)) |local| {
        const local_id = local.typed_value_id orelse return null;
        if (!local_id.eql(call.typed_callee_root_value_id) or !local.typed_value_operand_span_id.isValid()) return null;
        const initializer = expressionAtSpan(function.blocks[0], local.typed_value_operand_span_id) orelse return null;
        const function_id = initializer.typed_value_id orelse return null;
        const function_name = valueIdentityName(function, function_id) orelse return null;
        if (!std.mem.eql(u8, initializer.detail, function_name)) return null;
        return .{ .local_function = .{
            .local_name = root_name,
            .local_id = local_id,
            .function_name = function_name,
            .function_id = function_id,
            .local_location = locationFromInstruction(local),
        } };
    }
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

fn isZeroArgVoidFnPointer(ty: anytype) bool {
    return switch (ty.kind) {
        .fn_pointer => |signature| signature.params.len == 0 and typeNameIsVoid(signature.ret.*),
        else => false,
    };
}
