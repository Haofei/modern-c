//! Syntax-free lowering plans for the strict structural-access family.
//!
//! An access plan is admitted only from the MIR-owned `AccessFact` records and
//! their CFG/instruction witnesses.  It gives a backend stable block, span,
//! type, and (when the operand is a named value) value identity without asking
//! an AST to reconstruct the original expression.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const Location = struct {
    span_id: mir.SpanId,
    source: mir.SourcePoint,
};

pub const TypeRef = struct {
    id: mir.TypeId,
    value_ty: mir.ValueType,
};

pub const Operand = struct {
    name: ?[]const u8 = null,
    location: Location,
    type_ref: TypeRef,
    /// Literals intentionally have no value identity. Named operands must
    /// carry an interned identity, so a missing ID fails admission.
    value_id: ?mir.ValueId,
    integer_value: ?usize = null,
};

pub const max_place_projections = 4;
pub const max_initializer_nodes = 16;

/// A bounded, canonical place for address formation.  It deliberately records
/// only MIR identities and resolved projection ordinals; consumers must never
/// recover a member/index path from source syntax.
pub const AddressPlace = struct {
    pub const RootKind = enum { parameter, local, global, access_result };
    pub const Projection = union(enum) {
        field: struct { index: usize, result: TypeRef, location: Location },
        constant_index: struct { index: usize, bound: usize, result: TypeRef, location: Location },
        deref: struct { result: TypeRef, location: Location },
    };

    root_kind: RootKind,
    root: Operand,
    access_index: ?usize = null,
    projections: [max_place_projections]Projection = undefined,
    projection_count: usize = 0,
};

/// The minimum typed initializer graph needed by the strict access fixtures.
/// Nodes are fixed-size and source-free: aggregate children refer to node
/// indices, while leaves retain their exact Span/Value/Type identity.
pub const InitializerNode = struct {
    pub const Aggregate = struct {
        children: [mir.Instruction.max_aggregate_operands]usize = undefined,
        field_indices: [mir.Instruction.max_aggregate_operands]usize = [_]usize{std.math.maxInt(usize)} ** mir.Instruction.max_aggregate_operands,
        count: usize,
    };
    pub const Operation = union(enum) {
        named: Operand,
        integer_literal: struct { operand: Operand, value: usize },
        array_literal: Aggregate,
        struct_literal: Aggregate,
    };

    location: Location,
    type_ref: TypeRef,
    operation: Operation,
};

pub const InitializerGraph = struct {
    nodes: [max_initializer_nodes]InitializerNode,
    count: usize,
    root: usize,
};

pub const Initializer = union(enum) {
    named: Operand,
    direct_call: DirectCall,
    access_result: usize,
    graph: InitializerGraph,
};

pub const Index = struct {
    block_id: mir.BlockId,
    location: Location,
    result: TypeRef,
    base: Operand,
    index: Operand,
    constant_index: ?usize,
    static_bound: ?usize,
};

pub const RangeSlice = struct {
    block_id: mir.BlockId,
    location: Location,
    result: TypeRef,
    base: Operand,
    start: Operand,
    end: Operand,
};

pub const AddressOf = struct {
    block_id: mir.BlockId,
    location: Location,
    result: TypeRef,
    operand: Operand,
    place: AddressPlace,
};

pub const Deref = struct {
    block_id: mir.BlockId,
    location: Location,
    result: TypeRef,
    operand: Operand,
};

pub const Access = union(enum) {
    index: Index,
    range_slice: RangeSlice,
    address_of: AddressOf,
    deref: Deref,
};

pub const Plan = struct {
    function_name: []const u8,
    function_symbol_id: mir.SymbolId,
    accesses: []Access,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.accesses);
        self.* = undefined;
    }
};

/// A bounded function-level view over the strict access/slice bucket.  The
/// events are source-ordered stable MIR operations; each event carries the
/// IDs needed to reproduce its storage or evaluation edge without an AST.
pub const AccessBodyStatement = union(enum) {
    local_init: LocalInit,
    address_of: AccessEvent,
    deref_load: AccessEvent,
    deref_store: Store,
    index: AccessEvent,
    range_slice: AccessEvent,
    index_store: Store,
    direct_call: DirectCall,
    return_value: Return,
};

pub const LocalInit = struct {
    name: []const u8,
    value_id: mir.ValueId,
    type_ref: TypeRef,
    declaration: Location,
    initializer: Location,
    value: Initializer,
};

pub const AccessEvent = struct {
    access_index: usize,
    location: Location,
};

pub const Store = struct {
    target_access_index: usize,
    target: Location,
    value: StoreValue,
    location: Location,
};

/// Typed RHS values for structural stores.  This is deliberately small: it
/// covers named/literal operands, a value produced by an access event, and
/// the checked/conversion expression edges needed by the strict address
/// fixtures without asking a backend to revisit syntax.
pub const StoreValue = union(enum) {
    operand: Operand,
    access_result: usize,
    checked_binary: struct { location: Location, type_ref: TypeRef, op: []const u8, left: Operand, right: Operand },
    conversion: struct { location: Location, type_ref: TypeRef, operand: Operand },
};

pub const DirectCall = struct {
    callee_name: []const u8,
    callee_value_id: mir.ValueId,
    result: TypeRef,
    location: Location,
    arguments: [mir.Instruction.max_aggregate_operands]Operand = undefined,
    argument_count: usize = 0,
};

pub const Return = struct {
    location: Location,
    value: ?Operand,
    projection: ?ReturnProjection = null,
};

/// A source-free projection consumed directly by a return.  Field identity is
/// the resolved declaration ordinal, while builtins use the closed MIR enum;
/// neither form retains member spelling.
pub const FieldProjection = struct {
    base: Operand,
    field_index: usize,
    result: TypeRef,
    location: Location,
};

pub const BuiltinMemberProjection = struct {
    base: Operand,
    member: mir.Instruction.BuiltinMember,
    result: TypeRef,
    location: Location,
};

pub const ReturnProjection = union(enum) {
    field: FieldProjection,
    builtin_member: BuiltinMemberProjection,
};

pub const AccessBodyPlan = struct {
    function_name: []const u8,
    function_symbol_id: mir.SymbolId,
    entry_block: mir.BlockId,
    accesses: []Access,
    statements: []AccessBodyStatement,

    pub fn deinit(self: *AccessBodyPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.accesses);
        allocator.free(self.statements);
        self.* = undefined;
    }
};

/// The syntax-free terminal operation for a strict structural-access body.
///
/// Local declarations and their typed initializers remain source ordered in
/// `AccessBodyPlan.statements`.  This terminal tells a backend which access
/// value is returned, or which access place is stored before a void return.
/// Consequently all address/index/slice families share one emitter contract;
/// adding a source spelling cannot create a new admission path.
pub const StructuralOperation = union(enum) {
    return_access: struct {
        access_index: usize,
        location: Location,
    },
    store_access_then_return: struct {
        store: Store,
        return_location: Location,
    },
    store_access_then_return_access: struct {
        store: Store,
        value: union(enum) {
            access_result: usize,
            field: FieldProjection,
        },
        return_location: Location,
    },
    store_access_then_return_operand: struct {
        store: Store,
        value: Operand,
        return_location: Location,
    },
    range_slice_local_then_return_builtin: struct {
        local: LocalInit,
        range_access_index: usize,
        member: BuiltinMemberProjection,
        return_location: Location,
    },
};

/// Resolve the terminal effect of a strict access body without inspecting
/// syntax or names. Exactly one return is required. Its value is selected by
/// typed access identity, field ordinal, named ValueId, or closed builtin
/// member metadata. All other statements are source-ordered witnesses already
/// validated by `buildAccessBody`.
pub fn buildStructuralOperation(body: AccessBodyPlan) ?StructuralOperation {
    var returned: ?Return = null;
    var stored: ?Store = null;
    var range_event: ?AccessEvent = null;
    for (body.statements) |statement| switch (statement) {
        .local_init => {},
        .range_slice => |value| {
            if (range_event != null) return null;
            range_event = value;
        },
        .deref_store, .index_store => |value| {
            if (stored != null) return null;
            stored = value;
        },
        .return_value => |value| {
            if (returned != null) return null;
            returned = value;
        },
        .address_of, .deref_load, .index, .direct_call => {},
    };
    const result = returned orelse return null;
    if (stored) |store| {
        if (store.target_access_index >= body.accesses.len) return null;
        switch (body.accesses[store.target_access_index]) {
            .deref, .index => {},
            else => return null,
        }
        if (result.projection) |projection| return switch (projection) {
            .field => |field| if (result.value != null and sameLocation(result.value.?.location, field.location)) .{ .store_access_then_return_access = .{
                .store = store,
                .value = .{ .field = field },
                .return_location = result.location,
            } } else null,
            .builtin_member => null,
        };
        if (result.value) |value| {
            if (uniqueAccessIndexForLocation(body.accesses, value.location)) |access_index| {
                return .{ .store_access_then_return_access = .{
                    .store = store,
                    .value = .{ .access_result = access_index },
                    .return_location = result.location,
                } };
            }
            if (!namedOperand(value) or value.integer_value != null) return null;
            return .{ .store_access_then_return_operand = .{
                .store = store,
                .value = value,
                .return_location = result.location,
            } };
        }
        return .{ .store_access_then_return = .{
            .store = store,
            .return_location = result.location,
        } };
    }
    if (result.projection) |projection| switch (projection) {
        .builtin_member => |member| {
            if (member.member != .slice_length or result.value == null) return null;
            const range = range_event orelse return null;
            const access_index = range.access_index;
            const initialized = uniqueLocalForAccess(body.statements, access_index) orelse return null;
            const member_base_id = member.base.value_id orelse return null;
            if (body.accesses.len != 1 or access_index >= body.accesses.len or
                !member_base_id.eql(initialized.value_id) or
                !std.mem.eql(u8, member.base.name orelse return null, initialized.name) or
                !sameLocation(result.value.?.location, member.location)) return null;
            switch (body.accesses[access_index]) {
                .range_slice => {},
                else => return null,
            }
            return .{ .range_slice_local_then_return_builtin = .{
                .local = initialized,
                .range_access_index = access_index,
                .member = member,
                .return_location = result.location,
            } };
        },
        .field => return null,
    };
    const value = result.value orelse return null;
    const access_index = uniqueAccessIndexForLocation(body.accesses, value.location) orelse return null;
    return .{ .return_access = .{
        .access_index = access_index,
        .location = result.location,
    } };
}

fn sameLocation(left: Location, right: Location) bool {
    return left.span_id.eql(right.span_id) and sourceEquivalent(left.source, right.source);
}

fn uniqueLocalForAccess(statements: []const AccessBodyStatement, access_index: usize) ?LocalInit {
    var found: ?LocalInit = null;
    for (statements) |statement| switch (statement) {
        .local_init => |local| switch (local.value) {
            .access_result => |index| if (index == access_index) {
                if (found != null) return null;
                found = local;
            },
            else => {},
        },
        else => {},
    };
    return found;
}

/// Backend-neutral admission for one scalar slice load/store.  Backends own
/// only representation spelling; the operation, base, index, value and scalar
/// width are selected once from the verified access plan.
pub const SliceScalar = enum { u8, u32 };
pub const SliceOperation = struct {
    pub const Kind = enum { load, store };
    pub const Base = union(enum) { named: Operand, direct_call: DirectCall };
    pub const IndexValue = union(enum) { named: Operand, constant: usize };

    kind: Kind,
    scalar: SliceScalar,
    base: Base,
    index: IndexValue,
    value: ?Operand = null,
};

pub fn buildSliceOperation(body: AccessBodyPlan) ?SliceOperation {
    var index: ?Index = null;
    var store: ?Store = null;
    var returned: ?Return = null;
    var direct_call: ?DirectCall = null;
    for (body.statements) |statement| switch (statement) {
        .index => |event| {
            if (index != null or event.access_index >= body.accesses.len) return null;
            const value = switch (body.accesses[event.access_index]) {
                .index => |entry| entry,
                else => return null,
            };
            if (!event.location.span_id.eql(value.location.span_id)) return null;
            index = value;
        },
        .index_store => |value| {
            if (store != null) return null;
            store = value;
        },
        .direct_call => |value| {
            if (direct_call != null) return null;
            direct_call = value;
        },
        .return_value => |value| {
            if (returned != null) return null;
            returned = value;
        },
        else => return null,
    };
    const indexed = index orelse return null;
    const result = returned orelse return null;
    const scalar = sliceScalarFor(indexed.result.value_ty) orelse return null;
    if (!isSlice(indexed.base.type_ref.value_ty)) return null;
    const base: SliceOperation.Base = if (direct_call) |call| blk: {
        if (call.argument_count != 0 or !isSlice(call.result.value_ty) or indexed.base.name != null or indexed.base.value_id != null or !indexed.base.location.span_id.eql(call.location.span_id) or !sameTypeRef(indexed.base.type_ref, call.result)) return null;
        break :blk .{ .direct_call = call };
    } else if (namedOperand(indexed.base)) blk: {
        break :blk .{ .named = indexed.base };
    } else return null;
    const index_value: SliceOperation.IndexValue = if (indexed.constant_index) |constant|
        .{ .constant = constant }
    else if (isUsize(indexed.index.type_ref.value_ty) and namedOperand(indexed.index) and indexed.index.integer_value == null)
        .{ .named = indexed.index }
    else
        return null;
    if (indexed.constant_index == null and indexed.index.integer_value != null) return null;

    if (store) |stored| {
        const target = accessIndex(body.accesses, indexed) orelse return null;
        const value = switch (stored.value) {
            .operand => |operand| operand,
            else => return null,
        };
        if (stored.target_access_index != target or sliceScalarFor(value.type_ref.value_ty) != scalar or !namedOperand(value) or value.integer_value != null or result.value != null) return null;
        return .{ .kind = .store, .scalar = scalar, .base = base, .index = index_value, .value = value };
    }
    const returned_value = result.value orelse return null;
    if (!returned_value.location.span_id.eql(indexed.location.span_id) or sliceScalarFor(returned_value.type_ref.value_ty) != scalar) return null;
    return .{ .kind = .load, .scalar = scalar, .base = base, .index = index_value };
}

pub const LocalAddressUpdate = struct {
    local_name: []const u8,
    initial_name: []const u8,
    increment: usize,
};

pub fn buildLocalAddressUpdate(body: AccessBodyPlan) ?LocalAddressUpdate {
    var root: ?LocalInit = null;
    var address: ?AccessEvent = null;
    var deref: ?AccessEvent = null;
    var store: ?Store = null;
    var returned: ?Return = null;
    for (body.statements) |statement| switch (statement) {
        .local_init => |local| switch (local.value) {
            .named => if (root == null and sliceScalarFor(local.type_ref.value_ty) == .u32) {
                root = local;
            } else return null,
            .access_result => {},
            else => return null,
        },
        .address_of => |event| if (address == null) {
            address = event;
        } else return null,
        .deref_load => |event| if (deref == null) {
            deref = event;
        } else return null,
        .deref_store => |value| if (store == null) {
            store = value;
        } else return null,
        .return_value => |value| if (returned == null) {
            returned = value;
        } else return null,
        else => return null,
    };
    const local = root orelse return null;
    const initial = switch (local.value) {
        .named => |value| value,
        else => unreachable,
    };
    const address_event = address orelse return null;
    if (address_event.access_index >= body.accesses.len) return null;
    const address_access = switch (body.accesses[address_event.access_index]) {
        .address_of => |value| value,
        else => return null,
    };
    if (address_access.place.root_kind != .local or address_access.place.projection_count != 0 or !std.mem.eql(u8, address_access.place.root.name orelse return null, local.name)) return null;
    const deref_event = deref orelse return null;
    const stored = store orelse return null;
    if (stored.target_access_index != deref_event.access_index) return null;
    const binary = switch (stored.value) {
        .checked_binary => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, binary.op, "add") or !std.mem.eql(u8, binary.left.name orelse return null, local.name) or binary.right.integer_value == null or sliceScalarFor(binary.type_ref.value_ty) != .u32) return null;
    const returned_value = (returned orelse return null).value orelse return null;
    if (!std.mem.eql(u8, returned_value.name orelse return null, local.name)) return null;
    return .{ .local_name = local.name, .initial_name = initial.name orelse return null, .increment = binary.right.integer_value.? };
}

/// Build a finite statement/value plan for the strict address and slice
/// bucket. `build` first verifies every AccessFact/instruction/bounds edge;
/// this layer then admits only locals, direct calls, access stores, and a
/// single value return in the entry block. Trap successors are retained in the
/// CFG through `entry_block` and remain validated by `build`.
pub fn buildAccessBody(allocator: std.mem.Allocator, function: *const mir.Function) !?AccessBodyPlan {
    var access_plan = (try build(allocator, function)) orelse return null;
    var access_transferred = false;
    defer if (!access_transferred) access_plan.deinit(allocator);
    if (!accessBodyInstructionsSupported(function)) return null;

    var statements: std.ArrayList(AccessBodyStatement) = .empty;
    defer statements.deinit(allocator);
    const entry = function.blocks[0];
    for (entry.instructions) |instruction| {
        switch (instruction.kind) {
            .local => appendLocalInit(allocator, &statements, function, instruction) catch |err| {
                if (err == error.InvalidAccessBody) return null;
                return err;
            },
            .call => appendDirectCall(allocator, &statements, function, instruction) catch |err| {
                if (err == error.InvalidAccessBody) return null;
                return err;
            },
            .assign => appendStore(allocator, &statements, function, access_plan.accesses, instruction) catch |err| {
                if (err == error.InvalidAccessBody) return null;
                return err;
            },
            .index => appendIndexEvent(allocator, &statements, access_plan.accesses, instruction) catch |err| {
                if (err == error.InvalidAccessBody) return null;
                return err;
            },
            .return_value => appendReturn(allocator, &statements, function, instruction) catch |err| {
                if (err == error.InvalidAccessBody) return null;
                return err;
            },
            else => {},
        }
    }
    try appendSyntheticAccessEvents(allocator, &statements, access_plan.accesses);
    if (!bodyHasOneReturn(statements.items) or !accessBodyOrderIsStrict(statements.items)) return null;

    const owned_statements = try statements.toOwnedSlice(allocator);
    access_transferred = true;
    return .{
        .function_name = function.name,
        .function_symbol_id = function.typed_symbol_id,
        .entry_block = entry.typed_id,
        .accesses = access_plan.accesses,
        .statements = owned_statements,
    };
}

fn accessBodyInstructionsSupported(function: *const mir.Function) bool {
    for (function.blocks[0].instructions) |instruction| switch (instruction.kind) {
        .param, .local, .assign, .expr, .binary, .add_overflow, .cmp_bounds, .index, .typed_load, .call, .target_type, .representation_check, .representation_use, .integer_literal_conversion, .nullability_conversion, .conversion_check, .assignment_check, .return_value => {},
        else => return false,
    };
    return true;
}

fn appendLocalInit(allocator: std.mem.Allocator, statements: *std.ArrayList(AccessBodyStatement), function: *const mir.Function, instruction: mir.Instruction) !void {
    const value_id = instruction.typed_value_id orelse return error.InvalidAccessBody;
    const initializer = locationForSpan(function, instruction.typed_value_operand_span_id) orelse return error.InvalidAccessBody;
    try statements.append(allocator, .{ .local_init = .{
        .name = valueName(function, value_id) orelse return error.InvalidAccessBody,
        .value_id = value_id,
        .type_ref = typeRefForInstruction(function, instruction) orelse return error.InvalidAccessBody,
        .declaration = locationForSpan(function, instruction.typed_span_id) orelse return error.InvalidAccessBody,
        .initializer = initializer,
        .value = initializerForSpan(function, instruction.typed_value_operand_span_id) orelse return error.InvalidAccessBody,
    } });
}

fn appendDirectCall(allocator: std.mem.Allocator, statements: *std.ArrayList(AccessBodyStatement), function: *const mir.Function, instruction: mir.Instruction) !void {
    try statements.append(allocator, .{ .direct_call = directCallForInstruction(function, instruction) orelse return error.InvalidAccessBody });
}

fn directCallForInstruction(function: *const mir.Function, instruction: mir.Instruction) ?DirectCall {
    const value_id = instruction.typed_value_id orelse return null;
    const callee_span = instruction.typed_callee_span_id;
    if (!callee_span.isValid()) return null;
    const result = directCallResult(function, callee_span, instruction.detail, instruction.result_ty) orelse return null;
    var call: DirectCall = .{
        .callee_name = instruction.detail,
        .callee_value_id = value_id,
        .result = result,
        .location = locationForSpan(function, instruction.typed_span_id) orelse return null,
    };
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_argument or !fact.typed_callee_span_id.eql(callee_span)) continue;
        if (fact.target_index == null or fact.target_index.? >= call.arguments.len or fact.target_index.? != call.argument_count) return null;
        call.arguments[call.argument_count] = operandForSpan(function, fact.typed_span_id, fact.result_ty) orelse return null;
        call.argument_count += 1;
    }
    return call;
}

fn initializerForSpan(function: *const mir.Function, span_id: mir.SpanId) ?Initializer {
    const entry = function.blocks[0];
    for (entry.instructions) |instruction| {
        if (instruction.kind == .call and instruction.typed_span_id.eql(span_id)) return .{ .direct_call = directCallForInstruction(function, instruction) orelse return null };
    }
    if (accessIndexForSpanFromFacts(function, span_id)) |access_index| return .{ .access_result = access_index };
    const expression = expressionAtSpan(function.blocks[0], span_id) orelse return null;
    if (std.mem.eql(u8, expression.detail, "array_literal") or std.mem.eql(u8, expression.detail, "struct_literal")) {
        return .{ .graph = initializerGraph(function, span_id) orelse return null };
    }
    const operand = operandForSpan(function, span_id, expressionResultType(function, span_id) orelse return null) orelse
        accessResultOperand(function, span_id, null) orelse return null;
    if (operand.value_id != null) return .{ .named = operand };
    return .{ .graph = initializerGraph(function, span_id) orelse return null };
}

fn storeExpressionAtSpan(block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (!instruction.typed_span_id.eql(span_id)) continue;
        switch (instruction.kind) {
            .expr, .binary => {},
            else => continue,
        }
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn initializerGraph(function: *const mir.Function, span_id: mir.SpanId) ?InitializerGraph {
    var graph: InitializerGraph = undefined;
    graph.count = 0;
    graph.root = appendInitializerNode(function, span_id, &graph, 0) orelse return null;
    return graph;
}

fn appendInitializerNode(function: *const mir.Function, span_id: mir.SpanId, graph: *InitializerGraph, depth: usize) ?usize {
    if (!span_id.isValid() or depth >= max_initializer_nodes or graph.count >= max_initializer_nodes) return null;
    // Reserve the parent slot before descending. A full child graph may
    // otherwise advance `count` to the bound and make the later parent write
    // address one element past the fixed array.
    const node_index = graph.count;
    graph.count += 1;
    const instruction = expressionAtSpan(function.blocks[0], span_id) orelse return null;
    const type_ref = typeRefForValueType(function, initializerNodeType(function, instruction) orelse return null) orelse return null;
    const location = locationForSpan(function, span_id) orelse return null;
    const operation: InitializerNode.Operation = if (std.mem.eql(u8, instruction.detail, "array_literal") or std.mem.eql(u8, instruction.detail, "struct_literal")) blk: {
        if (instruction.typed_aggregate_operand_count == 0 or instruction.typed_aggregate_operand_count > mir.Instruction.max_aggregate_operands) return null;
        var aggregate: InitializerNode.Aggregate = .{ .count = instruction.typed_aggregate_operand_count };
        for (instruction.typed_aggregate_operand_span_ids[0..instruction.typed_aggregate_operand_count], 0..) |child_span, index| {
            aggregate.children[index] = appendInitializerNode(function, child_span, graph, depth + 1) orelse return null;
            if (std.mem.eql(u8, instruction.detail, "struct_literal")) {
                const field_index = instruction.typed_aggregate_field_indices[index];
                if (field_index == std.math.maxInt(usize)) return null;
                aggregate.field_indices[index] = field_index;
            }
        }
        break :blk if (std.mem.eql(u8, instruction.detail, "array_literal")) .{ .array_literal = aggregate } else .{ .struct_literal = aggregate };
    } else if (instruction.typed_value_id != null) blk: {
        const operand = operandForSpan(function, span_id, type_ref.value_ty) orelse return null;
        break :blk .{ .named = operand };
    } else blk: {
        if (!std.mem.eql(u8, instruction.detail, "int") or instruction.constant_usize_value == null) return null;
        const operand = operandForSpan(function, span_id, type_ref.value_ty) orelse return null;
        break :blk .{ .integer_literal = .{ .operand = operand, .value = instruction.constant_usize_value.? } };
    };
    graph.nodes[node_index] = .{ .location = location, .type_ref = type_ref, .operation = operation };
    return node_index;
}

fn initializerNodeType(function: *const mir.Function, instruction: mir.Instruction) ?mir.ValueType {
    if (std.mem.eql(u8, instruction.detail, "array_literal")) return targetTypeForSpan(function, .array_literal, instruction.typed_span_id);
    if (std.mem.eql(u8, instruction.detail, "struct_literal")) return targetTypeForSpan(function, .struct_literal, instruction.typed_span_id);
    return expressionResultType(function, instruction.typed_span_id);
}

fn expressionAtSpan(block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .expr or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn expressionResultType(function: *const mir.Function, span_id: mir.SpanId) ?mir.ValueType {
    return targetTypeForSpan(function, .expression_result, span_id);
}

fn targetTypeForSpan(function: *const mir.Function, kind: mir.TargetTypeKind, span_id: mir.SpanId) ?mir.ValueType {
    var found: ?mir.ValueType = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind or !fact.typed_span_id.eql(span_id) or !fact.typed_result_ty.isValid()) continue;
        if (found != null) return null;
        found = fact.result_ty;
    }
    return found;
}

fn accessIndexForSpanFromFacts(function: *const mir.Function, span_id: mir.SpanId) ?usize {
    var found: ?usize = null;
    for (function.access_facts, 0..) |fact, index| {
        const matches = switch (fact) {
            inline else => |entry| entry.typed_span_id.eql(span_id),
        };
        if (!matches) continue;
        if (found != null) return null;
        found = index;
    }
    return found;
}

fn addressAccessResultPlace(function: *const mir.Function, span_id: mir.SpanId, operand: Operand) ?AddressPlace {
    const access_index = accessIndexForSpanFromFacts(function, span_id) orelse return null;
    return .{ .root_kind = .access_result, .root = operand, .access_index = access_index };
}

fn addressPlaceForSpan(function: *const mir.Function, span_id: mir.SpanId, expected_ty: mir.ValueType) ?AddressPlace {
    var place: AddressPlace = undefined;
    var root_set = false;
    if (!appendAddressPlace(function, span_id, expected_ty, &place, &root_set, 0) or !root_set) return null;
    return place;
}

fn appendAddressPlace(function: *const mir.Function, span_id: mir.SpanId, expected_ty: mir.ValueType, place: *AddressPlace, root_set: *bool, depth: usize) bool {
    if (!span_id.isValid() or depth >= max_place_projections) return false;
    if (indexInstructionAtSpan(function.blocks[0], span_id)) |index_instruction| {
        const index = index_instruction.constant_index_value orelse return false;
        const bound = index_instruction.static_index_bound orelse return false;
        if (index >= bound or !index_instruction.typed_base_operand_span_id.isValid()) return false;
        const base_ty = expressionResultType(function, index_instruction.typed_base_operand_span_id) orelse return false;
        const result = typeRefForInstruction(function, index_instruction) orelse return false;
        if (!appendAddressPlace(function, index_instruction.typed_base_operand_span_id, base_ty, place, root_set, depth + 1) or place.projection_count >= place.projections.len) return false;
        place.projections[place.projection_count] = .{ .constant_index = .{ .index = index, .bound = bound, .result = result, .location = locationForSpan(function, span_id) orelse return false } };
        place.projection_count += 1;
        return true;
    }
    if (derefFactForSpan(function, span_id)) |deref| {
        const result = typeRefForTargetType(function, span_id, deref.result_ty) orelse return false;
        if (!appendAddressPlace(function, deref.operand_span_id, deref.operand_ty, place, root_set, depth + 1) or place.projection_count >= place.projections.len) return false;
        place.projections[place.projection_count] = .{ .deref = .{ .result = result, .location = locationForSpan(function, span_id) orelse return false } };
        place.projection_count += 1;
        return true;
    }
    if (accessIndexForSpanFromFacts(function, span_id)) |access_index| {
        const operand = accessResultOperand(function, span_id, expected_ty) orelse return false;
        if (root_set.*) return false;
        place.* = .{ .root_kind = .access_result, .root = operand, .access_index = access_index };
        root_set.* = true;
        return true;
    }
    const instruction = expressionAtSpan(function.blocks[0], span_id) orelse return false;
    const type_ref = typeRefForValueType(function, expected_ty) orelse return false;
    if (instruction.typed_base_operand_span_id.isValid()) {
        const field_index = instruction.member_field_index orelse return false;
        const base_ty = expressionResultType(function, instruction.typed_base_operand_span_id) orelse return false;
        if (!appendAddressPlace(function, instruction.typed_base_operand_span_id, base_ty, place, root_set, depth + 1) or place.projection_count >= place.projections.len) return false;
        place.projections[place.projection_count] = .{ .field = .{ .index = field_index, .result = type_ref, .location = locationForSpan(function, span_id) orelse return false } };
        place.projection_count += 1;
        return true;
    }
    const value_id = instruction.typed_value_id orelse return false;
    const name = valueName(function, value_id) orelse return false;
    if (root_set.* or !std.mem.eql(u8, instruction.detail, name)) return false;
    const kind: AddressPlace.RootKind = if (isLocalValue(function, value_id)) .local else if (isParameterValue(function, name)) .parameter else .global;
    place.* = .{ .root_kind = kind, .root = .{ .name = name, .location = locationForSpan(function, span_id) orelse return false, .type_ref = type_ref, .value_id = value_id } };
    root_set.* = true;
    return true;
}

fn indexInstructionAtSpan(block: mir.Block, span_id: mir.SpanId) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (block.instructions) |instruction| {
        if (instruction.kind != .index or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

const DerefFact = struct {
    result_ty: mir.ValueType,
    operand_ty: mir.ValueType,
    operand_span_id: mir.SpanId,
};

fn derefFactForSpan(function: *const mir.Function, span_id: mir.SpanId) ?DerefFact {
    var found: ?DerefFact = null;
    for (function.access_facts) |fact| switch (fact) {
        .deref => |deref| {
            if (!deref.typed_span_id.eql(span_id)) continue;
            if (found != null) return null;
            found = .{ .result_ty = deref.result_ty, .operand_ty = deref.operand_ty, .operand_span_id = deref.operand_span_id };
        },
        else => {},
    };
    return found;
}

fn isLocalValue(function: *const mir.Function, value_id: mir.ValueId) bool {
    for (function.blocks[0].instructions) |instruction| {
        if (instruction.kind != .local) continue;
        const id = instruction.typed_value_id orelse continue;
        if (id.eql(value_id)) return true;
    }
    return false;
}

fn isParameterValue(function: *const mir.Function, name: []const u8) bool {
    for (function.blocks[0].instructions) |instruction| if (instruction.kind == .param and std.mem.eql(u8, instruction.detail, name)) return true;
    return false;
}

fn appendStore(allocator: std.mem.Allocator, statements: *std.ArrayList(AccessBodyStatement), function: *const mir.Function, accesses: []const Access, instruction: mir.Instruction) !void {
    const target_index = accessIndexForSpan(accesses, instruction.typed_target_operand_span_id) orelse return error.InvalidAccessBody;
    const target = accesses[target_index];
    const target_ty = accessResultType(target);
    const value = storeValueForSpan(function, instruction.typed_value_operand_span_id, target_ty) orelse return error.InvalidAccessBody;
    const store: Store = .{
        .target_access_index = target_index,
        .target = locationForSpan(function, instruction.typed_target_operand_span_id) orelse return error.InvalidAccessBody,
        .value = value,
        .location = locationForSpan(function, instruction.typed_span_id) orelse return error.InvalidAccessBody,
    };
    switch (target) {
        .deref => try statements.append(allocator, .{ .deref_store = store }),
        .index => try statements.append(allocator, .{ .index_store = store }),
        else => return error.InvalidAccessBody,
    }
}

fn storeValueForSpan(function: *const mir.Function, span_id: mir.SpanId, expected_ty: mir.ValueType) ?StoreValue {
    if (operandForSpan(function, span_id, expected_ty)) |operand| return .{ .operand = operand };
    if (accessIndexForSpanFromFacts(function, span_id)) |access_index| return .{ .access_result = access_index };
    const expression = storeExpressionAtSpan(function.blocks[0], span_id) orelse return null;
    const location = locationForSpan(function, span_id) orelse return null;
    const type_ref = typeRefForValueType(function, expected_ty) orelse return null;
    if (expression.typed_left_operand_span_id.isValid() and expression.typed_right_operand_span_id.isValid()) {
        return .{ .checked_binary = .{
            .location = location,
            .type_ref = type_ref,
            .op = expression.detail,
            .left = operandForSpan(function, expression.typed_left_operand_span_id, expected_ty) orelse return null,
            .right = operandForSpan(function, expression.typed_right_operand_span_id, expected_ty) orelse return null,
        } };
    }
    if (expression.typed_left_operand_span_id.isValid()) return .{ .conversion = .{
        .location = location,
        .type_ref = type_ref,
        .operand = operandForSpan(function, expression.typed_left_operand_span_id, expressionResultType(function, expression.typed_left_operand_span_id) orelse return null) orelse return null,
    } };
    return null;
}

fn appendIndexEvent(allocator: std.mem.Allocator, statements: *std.ArrayList(AccessBodyStatement), accesses: []const Access, instruction: mir.Instruction) !void {
    const access_index = accessIndexForSpan(accesses, instruction.typed_span_id) orelse return error.InvalidAccessBody;
    const event: AccessEvent = .{ .access_index = access_index, .location = accessLocation(accesses[access_index]) };
    switch (accesses[access_index]) {
        .index => try statements.append(allocator, .{ .index = event }),
        .range_slice => try statements.append(allocator, .{ .range_slice = event }),
        else => return error.InvalidAccessBody,
    }
}

fn appendReturn(allocator: std.mem.Allocator, statements: *std.ArrayList(AccessBodyStatement), function: *const mir.Function, instruction: mir.Instruction) !void {
    const value_span_id = instruction.typed_value_operand_span_id;
    const value: ?Operand = if (value_span_id.isValid())
        operandForSpan(function, instruction.typed_value_operand_span_id, instruction.result_ty) orelse
            accessResultOperand(function, instruction.typed_value_operand_span_id, null) orelse return error.InvalidAccessBody
    else if (instruction.result_ty == .void)
        null
    else
        return error.InvalidAccessBody;
    try statements.append(allocator, .{ .return_value = .{
        .location = locationForSpan(function, instruction.typed_span_id) orelse return error.InvalidAccessBody,
        .value = value,
        .projection = if (value_span_id.isValid()) returnProjectionForSpan(function, value_span_id, instruction.result_ty) catch return error.InvalidAccessBody else null,
    } });
}

const ReturnProjectionError = error{MalformedProjection};

/// Recover a return projection only from the MIR expression edge.  A plain
/// operand has no base edge and returns null; once a base edge exists, missing
/// or ambiguous field/builtin metadata is malformed rather than a fallback.
fn returnProjectionForSpan(function: *const mir.Function, span_id: mir.SpanId, expected_ty: mir.ValueType) ReturnProjectionError!?ReturnProjection {
    const expression = expressionAtSpan(function.blocks[0], span_id) orelse return null;
    if (expression.member_field_index == null and expression.builtin_member == null) {
        if (expression.typed_base_operand_span_id.isValid()) return error.MalformedProjection;
        return null;
    }
    if (!expression.typed_base_operand_span_id.isValid()) {
        return error.MalformedProjection;
    }
    if ((expression.member_field_index == null) == (expression.builtin_member == null)) return error.MalformedProjection;
    const base_ty = expressionResultType(function, expression.typed_base_operand_span_id) orelse return error.MalformedProjection;
    const base = operandForSpan(function, expression.typed_base_operand_span_id, base_ty) orelse return error.MalformedProjection;
    const result = typeRefForTargetType(function, span_id, expected_ty) orelse return error.MalformedProjection;
    const location = locationForSpan(function, span_id) orelse return error.MalformedProjection;
    if (expression.member_field_index) |field_index| return .{ .field = .{
        .base = base,
        .field_index = field_index,
        .result = result,
        .location = location,
    } };
    const member = expression.builtin_member orelse return error.MalformedProjection;
    if (member != .slice_length or !isSlice(base.type_ref.value_ty) or !isUsize(expected_ty)) return error.MalformedProjection;
    return .{ .builtin_member = .{
        .base = base,
        .member = member,
        .result = result,
        .location = location,
    } };
}

fn accessResultOperand(function: *const mir.Function, span_id: mir.SpanId, expected_ty: ?mir.ValueType) ?Operand {
    for (function.access_facts) |fact| {
        const matches = switch (fact) {
            inline else => |entry| entry.typed_span_id.eql(span_id) and (expected_ty == null or sameValueType(entry.result_ty, expected_ty.?)),
        };
        if (!matches) continue;
        const result_ty = switch (fact) {
            .index => |entry| entry.result_ty,
            .range_slice => |entry| entry.result_ty,
            .address_of => |entry| entry.result_ty,
            .deref => |entry| entry.result_ty,
        };
        return .{
            .location = locationForSpan(function, span_id) orelse return null,
            .type_ref = typeRefForValueType(function, result_ty) orelse return null,
            .value_id = null,
        };
    }
    return null;
}

fn appendSyntheticAccessEvents(allocator: std.mem.Allocator, statements: *std.ArrayList(AccessBodyStatement), accesses: []const Access) !void {
    for (accesses, 0..) |access, access_index| switch (access) {
        .address_of => try statements.append(allocator, .{ .address_of = .{ .access_index = access_index, .location = accessLocation(access) } }),
        .deref => try statements.append(allocator, .{ .deref_load = .{ .access_index = access_index, .location = accessLocation(access) } }),
        else => {},
    };
    sortAccessBodyStatements(statements.items);
}

fn directCallResult(function: *const mir.Function, callee_span: mir.SpanId, name: []const u8, result_ty: mir.ValueType) ?TypeRef {
    var found: ?TypeRef = null;
    for (function.target_type_facts) |fact| {
        if (fact.kind != .direct_call_result or !fact.typed_span_id.eql(callee_span)) continue;
        if (fact.target_owner == null or !std.mem.eql(u8, fact.target_owner.?, name) or !sameValueType(fact.result_ty, result_ty)) return null;
        const candidate = typeRefForValueType(function, fact.result_ty) orelse return null;
        if (!candidate.id.eql(fact.typed_result_ty) or found != null) return null;
        found = candidate;
    }
    return found;
}

fn accessIndexForSpan(accesses: []const Access, span_id: mir.SpanId) ?usize {
    var found: ?usize = null;
    for (accesses, 0..) |access, index| {
        if (!accessLocation(access).span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = index;
    }
    return found;
}

fn uniqueAccessIndexForLocation(accesses: []const Access, location: Location) ?usize {
    var found: ?usize = null;
    for (accesses, 0..) |access, index| {
        const candidate = accessLocation(access);
        if (!candidate.span_id.eql(location.span_id)) continue;
        if (!sourceEquivalent(candidate.source, location.source) or found != null) return null;
        found = index;
    }
    return found;
}

fn accessLocation(access: Access) Location {
    return switch (access) {
        .index => |entry| entry.location,
        .range_slice => |entry| entry.location,
        .address_of => |entry| entry.location,
        .deref => |entry| entry.location,
    };
}

fn accessResultType(access: Access) mir.ValueType {
    return switch (access) {
        .index => |entry| entry.result.value_ty,
        .range_slice => |entry| entry.result.value_ty,
        .address_of => |entry| entry.result.value_ty,
        .deref => |entry| entry.result.value_ty,
    };
}

fn bodyHasOneReturn(statements: []const AccessBodyStatement) bool {
    var count: usize = 0;
    for (statements) |statement| {
        if (statement == .return_value) count += 1;
    }
    return count == 1;
}

fn accessBodyOrderIsStrict(statements: []AccessBodyStatement) bool {
    sortAccessBodyStatements(statements);
    return statements.len != 0 and statements[statements.len - 1] == .return_value;
}

fn sortAccessBodyStatements(statements: []AccessBodyStatement) void {
    var index: usize = 1;
    while (index < statements.len) : (index += 1) {
        const current = statements[index];
        var cursor = index;
        while (cursor > 0 and statementLess(current, statements[cursor - 1])) : (cursor -= 1) statements[cursor] = statements[cursor - 1];
        statements[cursor] = current;
    }
}

fn statementLess(left: AccessBodyStatement, right: AccessBodyStatement) bool {
    if (left == .return_value) return false;
    if (right == .return_value) return true;
    const left_location = statementLocation(left);
    const right_location = statementLocation(right);
    if (left_location.source.offset != right_location.source.offset) return left_location.source.offset < right_location.source.offset;
    return statementRank(left) < statementRank(right);
}

fn statementLocation(statement: AccessBodyStatement) Location {
    return switch (statement) {
        .local_init => |entry| entry.declaration,
        .address_of, .deref_load, .index, .range_slice => |entry| entry.location,
        .deref_store, .index_store => |entry| entry.location,
        .direct_call => |entry| entry.location,
        .return_value => |entry| entry.location,
    };
}

fn statementRank(statement: AccessBodyStatement) u8 {
    return switch (statement) {
        .local_init => 0,
        .direct_call => 1,
        .address_of => 2,
        .index, .range_slice => 3,
        .deref_load => 4,
        .deref_store, .index_store => 5,
        .return_value => 6,
    };
}

/// Builds a plan for straight-line structural access bodies. The bounded
/// family permits one normal return entry block plus the bounds-trap blocks
/// required by element indexes/range slices. Every emitted operation must have
/// exactly one matching AccessFact and complete typed identities.
pub fn build(allocator: std.mem.Allocator, function: *const mir.Function) !?Plan {
    if (!straightLineAccessBody(function)) return null;
    if (function.access_facts.len == 0) return null;

    var accesses = try allocator.alloc(Access, function.access_facts.len);
    var returned = false;
    defer if (!returned) allocator.free(accesses);
    for (function.access_facts, 0..) |fact, index| {
        accesses[index] = buildAccess(function, fact) orelse return null;
    }
    if (!allAccessInstructionsWitnessed(function, accesses)) return null;

    returned = true;
    return .{
        .function_name = function.name,
        .function_symbol_id = function.typed_symbol_id,
        .accesses = accesses,
    };
}

fn straightLineAccessBody(function: *const mir.Function) bool {
    if (!function.typed_symbol_id.isValid() or function.blocks.len == 0) return false;
    const block = function.blocks[0];
    if (!block.typed_id.isValid() or block.terminator != .return_) return false;
    for (block.successors) |successor| {
        var trapped = false;
        for (function.trap_edges) |edge| {
            if (edge.from_block == 0 and edge.trap_block == successor) {
                trapped = true;
                break;
            }
        }
        if (!trapped) return false;
    }
    return true;
}

fn buildAccess(function: *const mir.Function, fact: mir.AccessFact) ?Access {
    return switch (fact) {
        .index => buildIndex(function, fact),
        .range_slice => buildRangeSlice(function, fact),
        .address_of => buildAddressOf(function, fact),
        .deref => buildDeref(function, fact),
    };
}

fn buildIndex(function: *const mir.Function, fact: mir.AccessFact) ?Access {
    const access = switch (fact) {
        .index => |entry| entry,
        else => return null,
    };
    const witness = uniqueIndexWitness(function, access.typed_span_id, false) orelse return null;
    if (!sameValueType(witness.result_ty, access.result_ty) or
        !witness.typed_base_operand_span_id.eql(access.base_span_id) or !witness.typed_index_operand_span_id.eql(access.index_span_id)) return null;
    const result = typeRefForInstruction(function, witness) orelse return null;
    const location = locationForSpan(function, access.typed_span_id) orelse return null;
    if (!sourceEquivalent(location.source, access.source)) return null;
    const base = operandForSpan(function, access.base_span_id, access.base_ty) orelse return null;
    const index = operandForSpan(function, access.index_span_id, access.index_ty) orelse return null;
    if (!isInteger(access.index_ty) or !hasBoundsWitness(function, .index, access.index_span_id)) return null;
    return .{ .index = .{
        .block_id = function.blocks[0].typed_id,
        .location = location,
        .result = result,
        .base = base,
        .index = index,
        .constant_index = witness.constant_index_value,
        .static_bound = witness.static_index_bound,
    } };
}

fn buildRangeSlice(function: *const mir.Function, fact: mir.AccessFact) ?Access {
    const access = switch (fact) {
        .range_slice => |entry| entry,
        else => return null,
    };
    const witness = uniqueIndexWitness(function, access.typed_span_id, true) orelse return null;
    if (!sameValueType(witness.result_ty, access.result_ty) or
        !witness.typed_base_operand_span_id.eql(access.base_span_id) or !witness.typed_index_operand_span_id.eql(access.start_span_id)) return null;
    const result = typeRefForInstruction(function, witness) orelse return null;
    const location = locationForSpan(function, access.typed_span_id) orelse return null;
    if (!sourceEquivalent(location.source, access.source) or !isSlice(access.result_ty) or
        !isInteger(access.start_ty) or !isInteger(access.end_ty) or !hasBoundsWitness(function, .slice, access.typed_span_id)) return null;
    return .{ .range_slice = .{
        .block_id = function.blocks[0].typed_id,
        .location = location,
        .result = result,
        .base = operandForSpan(function, access.base_span_id, access.base_ty) orelse return null,
        .start = operandForSpan(function, access.start_span_id, access.start_ty) orelse return null,
        .end = operandForSpan(function, access.end_span_id, access.end_ty) orelse return null,
    } };
}

fn buildAddressOf(function: *const mir.Function, fact: mir.AccessFact) ?Access {
    const access = switch (fact) {
        .address_of => |entry| entry,
        else => return null,
    };
    const location = locationForSpan(function, access.typed_span_id) orelse return null;
    if (!sourceEquivalent(location.source, access.source) or !isAddressResult(access.result_ty)) return null;
    const result = typeRefForTargetType(function, access.typed_span_id, access.result_ty) orelse return null;
    const operand = operandForSpan(function, access.operand_span_id, access.operand_ty) orelse
        accessResultOperand(function, access.operand_span_id, access.operand_ty) orelse return null;
    return .{ .address_of = .{
        .block_id = function.blocks[0].typed_id,
        .location = location,
        .result = result,
        .operand = operand,
        .place = addressPlaceForSpan(function, access.operand_span_id, access.operand_ty) orelse
            addressAccessResultPlace(function, access.operand_span_id, operand) orelse return null,
    } };
}

fn buildDeref(function: *const mir.Function, fact: mir.AccessFact) ?Access {
    const access = switch (fact) {
        .deref => |entry| entry,
        else => return null,
    };
    const location = locationForSpan(function, access.typed_span_id) orelse return null;
    if (!sourceEquivalent(location.source, access.source) or !isDerefOperand(access.operand_ty)) return null;
    const result = typeRefForTargetType(function, access.typed_span_id, access.result_ty) orelse return null;
    return .{ .deref = .{
        .block_id = function.blocks[0].typed_id,
        .location = location,
        .result = result,
        .operand = operandForSpan(function, access.operand_span_id, access.operand_ty) orelse return null,
    } };
}

fn operandForSpan(function: *const mir.Function, span_id: mir.SpanId, expected_ty: mir.ValueType) ?Operand {
    const location = locationForSpan(function, span_id) orelse return null;
    var found: ?mir.Instruction = null;
    for (function.blocks[0].instructions) |instruction| {
        if (instruction.kind != .expr or !instruction.typed_span_id.eql(span_id)) continue;
        if (found != null) return null;
        found = instruction;
    }
    const expression = found orelse {
        var call_found = false;
        for (function.blocks[0].instructions) |instruction| {
            if (instruction.kind != .call or !instruction.typed_span_id.eql(span_id)) continue;
            if (call_found or typeRefForTargetType(function, span_id, expected_ty) == null) return null;
            call_found = true;
        }
        if (!call_found) return null;
        return .{
            .location = location,
            .type_ref = typeRefForValueType(function, expected_ty) orelse return null,
            .value_id = null,
        };
    };
    const type_ref = typeRefForValueType(function, expected_ty) orelse return null;
    if (!sameValueType(expression.result_ty, expected_ty) and typeRefForTargetType(function, span_id, expected_ty) == null) return null;
    const value_id = expression.typed_value_id;
    const name = if (value_id) |id| valueName(function, id) orelse return null else null;
    return .{ .name = name, .location = location, .type_ref = type_ref, .value_id = value_id, .integer_value = expression.constant_usize_value };
}

fn uniqueIndexWitness(function: *const mir.Function, span_id: mir.SpanId, range: bool) ?mir.Instruction {
    var found: ?mir.Instruction = null;
    for (function.blocks[0].instructions) |instruction| {
        if (instruction.kind != .index or !instruction.typed_span_id.eql(span_id)) continue;
        if (std.mem.startsWith(u8, instruction.detail, "range_slice") != range) return null;
        if (found != null) return null;
        found = instruction;
    }
    return found;
}

fn allAccessInstructionsWitnessed(function: *const mir.Function, accesses: []const Access) bool {
    for (function.blocks[0].instructions) |instruction| {
        if (instruction.kind != .index) continue;
        var found = false;
        for (accesses) |access| switch (access) {
            .index => |entry| {
                if (entry.location.span_id.eql(instruction.typed_span_id)) found = true;
            },
            .range_slice => |entry| {
                if (entry.location.span_id.eql(instruction.typed_span_id)) found = true;
            },
            else => {},
        };
        if (!found) return false;
    }
    return true;
}

fn hasBoundsWitness(function: *const mir.Function, kind: mir.BoundsFactKind, span_id: mir.SpanId) bool {
    var found = false;
    for (function.bounds_facts) |fact| {
        if (fact.kind != kind or !fact.typed_span_id.eql(span_id)) continue;
        if (found or locationForSpan(function, span_id) == null) return false;
        found = true;
    }
    return found;
}

fn typeRefForInstruction(function: *const mir.Function, instruction: mir.Instruction) ?TypeRef {
    if (!instruction.typed_result_ty.isValid()) return null;
    const type_ref = typeRefForValueType(function, instruction.result_ty) orelse return null;
    return if (type_ref.id.eql(instruction.typed_result_ty)) type_ref else null;
}

fn typeRefForTargetType(function: *const mir.Function, span_id: mir.SpanId, expected_ty: mir.ValueType) ?TypeRef {
    var found: ?TypeRef = null;
    for (function.target_type_facts) |fact| {
        if (!fact.typed_span_id.eql(span_id) or !sameValueType(fact.result_ty, expected_ty)) continue;
        if (!fact.typed_result_ty.isValid()) return null;
        const candidate = typeRefForValueType(function, fact.result_ty) orelse return null;
        if (!candidate.id.eql(fact.typed_result_ty)) return null;
        if (found) |previous| {
            if (!previous.id.eql(candidate.id)) return null;
            continue;
        }
        found = candidate;
    }
    return found;
}

fn typeRefForValueType(function: *const mir.Function, value_ty: mir.ValueType) ?TypeRef {
    var found: ?mir.TypeId = null;
    for (function.type_identities) |identity| {
        if (!identity.id.isValid() or !std.mem.eql(u8, identity.spelling, value_ty.name())) continue;
        if (found != null) return null;
        found = identity.id;
    }
    return if (found) |id| .{ .id = id, .value_ty = value_ty } else null;
}

fn locationForSpan(function: *const mir.Function, span_id: mir.SpanId) ?Location {
    if (!span_id.isValid() or span_id.index() >= function.span_identities.len) return null;
    const identity = function.span_identities[span_id.index()];
    return if (identity.id.eql(span_id)) .{ .span_id = span_id, .source = identity.source } else null;
}

fn valueName(function: *const mir.Function, value_id: mir.ValueId) ?[]const u8 {
    if (!value_id.isValid() or value_id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[value_id.index()];
    return if (identity.id.eql(value_id)) identity.spelling else null;
}

fn isInteger(ty: mir.ValueType) bool {
    return std.meta.activeTag(ty) == .integer;
}

fn isSlice(ty: mir.ValueType) bool {
    return switch (ty) {
        .slice => true,
        .pointer => |shape| shape.kind == .slice,
        else => false,
    };
}

fn isAddressResult(ty: mir.ValueType) bool {
    return switch (ty) {
        .pointer, .nullable_pointer, .address, .value => true,
        else => false,
    };
}

fn isDerefOperand(ty: mir.ValueType) bool {
    return switch (ty) {
        .pointer, .nullable_pointer, .address => true,
        else => false,
    };
}

fn sameValueType(left: mir.ValueType, right: mir.ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and std.mem.eql(u8, left.name(), right.name());
}

fn sameTypeRef(left: TypeRef, right: TypeRef) bool {
    return left.id.eql(right.id) and sameValueType(left.value_ty, right.value_ty);
}

fn namedOperand(operand: Operand) bool {
    return operand.name != null and operand.value_id != null and operand.value_id.?.isValid();
}

fn isUsize(value_ty: mir.ValueType) bool {
    return switch (value_ty) {
        .integer => |name| std.mem.eql(u8, name, "usize"),
        else => false,
    };
}

fn sliceScalarFor(value_ty: mir.ValueType) ?SliceScalar {
    return switch (value_ty) {
        .integer => |name| if (std.mem.eql(u8, name, "u8")) .u8 else if (std.mem.eql(u8, name, "u32")) .u32 else null,
        else => null,
    };
}

fn accessIndex(accesses: []const Access, wanted: Index) ?usize {
    for (accesses, 0..) |access, access_index| switch (access) {
        .index => |candidate| if (candidate.location.span_id.eql(wanted.location.span_id)) return access_index,
        else => {},
    };
    return null;
}

fn sourceEquivalent(left: mir.SourcePoint, right: mir.SourcePoint) bool {
    return left.line == right.line and left.column == right.column and left.offset == right.offset and left.len == right.len and left.file_id == right.file_id;
}
