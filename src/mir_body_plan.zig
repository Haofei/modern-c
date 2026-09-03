//! Syntax-free, immutable-by-convention MIR body plans.
//!
//! `mir_model.Function` is the canonical owned MIR representation.  A
//! `BodyPlan` is a backend-facing snapshot of just its body-shaped data: CFG,
//! instruction metadata, typed identities, trap edges, and cleanup edges.  It
//! intentionally does not import or expose AST/parser/sema types.  Backends
//! can retain a plan while selecting target spelling without re-deriving CFG
//! or typed-ID relationships from syntax.

const std = @import("std");
const mir = @import("mir_model.zig");

pub const Location = struct {
    span_id: mir.SpanId = .invalid,
    source: mir.SourcePoint,
};

/// All typed instruction references that identify another source occurrence.
/// The IDs are function-local and resolve through `BodyPlan.span`.
pub const OperandSpans = struct {
    left: mir.SpanId = .invalid,
    right: mir.SpanId = .invalid,
    base: mir.SpanId = .invalid,
    index: mir.SpanId = .invalid,
    target: mir.SpanId = .invalid,
    value: mir.SpanId = .invalid,
    callee: mir.SpanId = .invalid,
    callee_root: mir.SpanId = .invalid,
    aggregate: [mir.Instruction.max_aggregate_operands]mir.SpanId = [_]mir.SpanId{.invalid} ** mir.Instruction.max_aggregate_operands,
    aggregate_field_indices: [mir.Instruction.max_aggregate_operands]usize = [_]usize{std.math.maxInt(usize)} ** mir.Instruction.max_aggregate_operands,
    aggregate_count: usize = 0,
};

/// Syntax-free instruction projection. `target_ty` is intentionally absent:
/// its checked `type_id` and runtime `result_ty` are the body-plan interface.
pub const InstructionPlan = struct {
    kind: mir.Instruction.Kind,
    detail: []const u8,
    result_ty: mir.ValueType,
    type_id: mir.TypeId = .invalid,
    value_id: mir.ValueId = .invalid,
    location: Location,
    operands: OperandSpans = .{},
    operand_value_id: mir.ValueId = .invalid,
    callee_root_value_id: mir.ValueId = .invalid,
    target_owner_id: ?mir.SymbolId = null,
    aggregate_construction: ?mir.AggregateConstructionKind = null,
    const_index: ?usize = null,
    target_index: ?usize = null,
    member_field_index: ?usize = null,
    builtin_member: ?mir.Instruction.BuiltinMember = null,
    constant_index_value: ?usize = null,
    static_index_bound: ?usize = null,
    constant_usize_value: ?usize = null,
    callee_field_index: ?usize = null,
    contract_region_id: ?usize = null,
    switch_patterns: [mir.Instruction.max_switch_patterns]mir.Instruction.SwitchPattern = [_]mir.Instruction.SwitchPattern{.unused} ** mir.Instruction.max_switch_patterns,
    switch_pattern_count: usize = 0,
};

pub const TerminatorPlan = union(enum) {
    fallthrough,
    jump: mir.BlockId,
    branch: struct { true_block: mir.BlockId, false_block: mir.BlockId },
    return_: mir.ValueType,
    trap_: mir.TrapKind,
    unreachable_,
    switch_,
};

pub const BlockPlan = struct {
    id: mir.BlockId,
    ordinal: usize,
    kind: []const u8,
    instructions: []const InstructionPlan,
    successors: []const mir.BlockId,
    terminator: TerminatorPlan,
};

pub const TrapEdgePlan = struct {
    from_block: mir.BlockId,
    trap_block: mir.BlockId,
    kind: mir.TrapKind,
    source: mir.TrapSource,
    location: Location,
};

pub const OwnershipCleanupActionPlan = struct {
    kind: mir.CleanupActionKind,
    primary_event_index: usize,
    storage_dead_event_index: usize,
    place: mir.OwnershipPlace,
    generation: u32,
    drop_glue_symbol_id: mir.SymbolId,
    block_id: mir.BlockId,
    location: Location,
};

pub const CleanupActionPlan = union(enum) {
    ownership: struct {
        cleanup_action_index: usize,
        kind: mir.CleanupActionKind,
        primary_event_index: usize,
        storage_dead_event_index: usize,
        root_value_id: mir.ValueId,
        resource_type_symbol_id: mir.SymbolId,
        drop_glue_symbol_id: mir.SymbolId,
        generation: u32,
        block_id: mir.BlockId,
        location: Location,
    },
    defer_cleanup: struct {
        block_id: mir.BlockId,
        instruction_index: usize,
        location: Location,
    },
};

pub const CleanupEdgePlan = struct {
    kind: mir.CleanupCfgEdgeKind,
    source_block: mir.BlockId,
    target_block: ?mir.BlockId,
    location: Location,
    actions: []const CleanupActionPlan,
};

/// An owned snapshot. All public slices are const so consumers can share one
/// verified plan between C and LLVM lowering without mutating its structure.
pub const BodyPlan = struct {
    function_name: []const u8,
    function_symbol_id: mir.SymbolId,
    source_id: mir.SourceId,
    return_ty: mir.ValueType,
    blocks: []const BlockPlan,
    trap_edges: []const TrapEdgePlan,
    ownership_actions: []const OwnershipCleanupActionPlan,
    cleanup_edges: []const CleanupEdgePlan,
    types: []const mir.TypeIdentity,
    spans: []const mir.SpanIdentity,
    values: []const mir.ValueIdentity,
    symbols: []const mir.SymbolIdentity,
    access_facts: []const mir.AccessFact,
    integer_facts: []const mir.IntegerFact,
    float_facts: []const mir.FloatFact,

    pub fn deinit(self: *BodyPlan, allocator: std.mem.Allocator) void {
        for (self.blocks) |body_block| {
            allocator.free(body_block.instructions);
            allocator.free(body_block.successors);
        }
        allocator.free(self.blocks);
        allocator.free(self.trap_edges);
        allocator.free(self.ownership_actions);
        for (self.cleanup_edges) |edge| allocator.free(edge.actions);
        allocator.free(self.cleanup_edges);
        allocator.free(self.types);
        allocator.free(self.spans);
        allocator.free(self.values);
        allocator.free(self.symbols);
        allocator.free(self.access_facts);
        allocator.free(self.integer_facts);
        allocator.free(self.float_facts);
        self.* = undefined;
    }

    pub fn block(self: *const BodyPlan, id: mir.BlockId) ?*const BlockPlan {
        if (!id.isValid()) return null;
        for (self.blocks) |*candidate| if (candidate.id.eql(id)) return candidate;
        return null;
    }

    pub fn value(self: *const BodyPlan, id: mir.ValueId) ?mir.ValueIdentity {
        if (!id.isValid() or id.index() >= self.values.len) return null;
        const identity = self.values[id.index()];
        return if (identity.id.eql(id)) identity else null;
    }

    pub fn span(self: *const BodyPlan, id: mir.SpanId) ?mir.SpanIdentity {
        if (!id.isValid() or id.index() >= self.spans.len) return null;
        const identity = self.spans[id.index()];
        return if (identity.id.eql(id)) identity else null;
    }

    pub fn typeIdentity(self: *const BodyPlan, id: mir.TypeId) ?mir.TypeIdentity {
        if (!id.isValid() or id.index() >= self.types.len) return null;
        const identity = self.types[id.index()];
        return if (identity.id.eql(id)) identity else null;
    }

    pub fn symbol(self: *const BodyPlan, id: mir.SymbolId) ?mir.SymbolIdentity {
        if (!id.isValid() or id.index() >= self.symbols.len) return null;
        const identity = self.symbols[id.index()];
        return if (identity.id.eql(id)) identity else null;
    }
};

pub fn build(allocator: std.mem.Allocator, function: *const mir.Function) !BodyPlan {
    try verify(function);

    const types = try allocator.dupe(mir.TypeIdentity, function.type_identities);
    errdefer allocator.free(types);
    const spans = try allocator.dupe(mir.SpanIdentity, function.span_identities);
    errdefer allocator.free(spans);
    const values = try allocator.dupe(mir.ValueIdentity, function.value_identities);
    errdefer allocator.free(values);
    const symbols = try allocator.dupe(mir.SymbolIdentity, function.target_owner_identities);
    errdefer allocator.free(symbols);
    const access_facts = try allocator.dupe(mir.AccessFact, function.access_facts);
    errdefer allocator.free(access_facts);
    const integer_facts = try allocator.dupe(mir.IntegerFact, function.integer_facts);
    errdefer allocator.free(integer_facts);
    const float_facts = try allocator.dupe(mir.FloatFact, function.float_facts);
    errdefer allocator.free(float_facts);
    const blocks = try buildBlocks(allocator, function);
    errdefer freeBlocks(allocator, blocks);
    const trap_edges = try buildTrapEdges(allocator, function);
    errdefer allocator.free(trap_edges);
    const ownership_actions = try buildOwnershipActions(allocator, function);
    errdefer allocator.free(ownership_actions);
    const cleanup_edges = try buildCleanupEdges(allocator, function);
    errdefer freeCleanupEdges(allocator, cleanup_edges);

    return .{
        .function_name = function.name,
        .function_symbol_id = function.typed_symbol_id,
        .source_id = function.typed_source_id,
        .return_ty = function.return_ty,
        .blocks = blocks,
        .trap_edges = trap_edges,
        .ownership_actions = ownership_actions,
        .cleanup_edges = cleanup_edges,
        .types = types,
        .spans = spans,
        .values = values,
        .symbols = symbols,
        .access_facts = access_facts,
        .integer_facts = integer_facts,
        .float_facts = float_facts,
    };
}

/// Verifier-style admission. A successful result means the body can be
/// consumed using typed IDs and block IDs alone; no source tree lookup is
/// required to recover CFG or cleanup order.
pub fn verify(function: *const mir.Function) !void {
    try verifyIdentityTables(function);
    try verifyBlocks(function);
    try verifyTrapEdges(function);
    try verifyInstructions(function);
    try verifyAccessFacts(function);
    try verifyCleanup(function);
}

fn verifyAccessFacts(function: *const mir.Function) !void {
    for (function.access_facts, 0..) |fact, index| {
        const primary_span_id = accessFactSpanId(fact);
        _ = spanIdentity(function, primary_span_id) orelse return error.InvalidAccessFact;
        switch (fact) {
            .index => |access| {
                try verifyRequiredAccessSpan(function, access.base_span_id);
                try verifyRequiredAccessSpan(function, access.index_span_id);
                if (access.index_ty != .integer or !hasIndexInstruction(function, access.typed_span_id, access.result_ty, access.base_span_id, access.index_span_id)) return error.InvalidAccessFact;
            },
            .range_slice => |access| {
                try verifyRequiredAccessSpan(function, access.base_span_id);
                try verifyRequiredAccessSpan(function, access.start_span_id);
                try verifyRequiredAccessSpan(function, access.end_span_id);
                if (!accessResultIsSlice(access.result_ty) or access.start_ty != .integer or access.end_ty != .integer or
                    !hasRangeSliceInstruction(function, access.typed_span_id, access.result_ty, access.base_span_id, access.start_span_id)) return error.InvalidAccessFact;
            },
            .address_of => |access| {
                try verifyRequiredAccessSpan(function, access.operand_span_id);
                switch (access.result_ty) {
                    .pointer, .nullable_pointer, .address, .value => {},
                    else => return error.InvalidAccessFact,
                }
            },
            .deref => |access| {
                try verifyRequiredAccessSpan(function, access.operand_span_id);
                switch (access.operand_ty) {
                    .pointer, .nullable_pointer, .address => {},
                    else => return error.InvalidAccessFact,
                }
            },
        }
        for (function.access_facts[0..index]) |prior| {
            if (std.meta.activeTag(prior) == std.meta.activeTag(fact) and accessFactSpanId(prior).eql(primary_span_id)) return error.DuplicateAccessFact;
        }
    }
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind != .index) continue;
        if (std.mem.eql(u8, instruction.detail, "const_get")) continue;
        const present = if (std.mem.startsWith(u8, instruction.detail, "range_slice"))
            rangeSliceFactForInstruction(function, instruction)
        else
            indexFactForInstruction(function, instruction);
        if (!present) return error.InvalidAccessFact;
    };
}

fn verifyRequiredAccessSpan(function: *const mir.Function, span_id: mir.SpanId) !void {
    if (!span_id.isValid() or spanIdentity(function, span_id) == null) return error.InvalidAccessFact;
}

fn accessResultIsSlice(ty: mir.ValueType) bool {
    return switch (ty) {
        .slice => true,
        .pointer => |shape| shape.kind == .slice,
        else => false,
    };
}

fn hasIndexInstruction(function: *const mir.Function, span_id: mir.SpanId, result_ty: mir.ValueType, base_span_id: mir.SpanId, index_span_id: mir.SpanId) bool {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .index and instruction.typed_span_id.eql(span_id) and std.meta.eql(instruction.result_ty, result_ty) and
            instruction.typed_base_operand_span_id.eql(base_span_id) and instruction.typed_index_operand_span_id.eql(index_span_id)) return true;
    };
    return false;
}

fn hasRangeSliceInstruction(function: *const mir.Function, span_id: mir.SpanId, result_ty: mir.ValueType, base_span_id: mir.SpanId, start_span_id: mir.SpanId) bool {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .index and std.mem.startsWith(u8, instruction.detail, "range_slice") and instruction.typed_span_id.eql(span_id) and std.meta.eql(instruction.result_ty, result_ty) and
            instruction.typed_base_operand_span_id.eql(base_span_id) and instruction.typed_index_operand_span_id.eql(start_span_id)) return true;
    };
    return false;
}

fn indexFactForInstruction(function: *const mir.Function, instruction: mir.Instruction) bool {
    for (function.access_facts) |fact| switch (fact) {
        .index => |access| if (access.typed_span_id.eql(instruction.typed_span_id) and
            std.meta.eql(access.result_ty, instruction.result_ty) and
            access.base_span_id.eql(instruction.typed_base_operand_span_id) and
            access.index_span_id.eql(instruction.typed_index_operand_span_id)) return true,
        else => {},
    };
    return false;
}

fn rangeSliceFactForInstruction(function: *const mir.Function, instruction: mir.Instruction) bool {
    for (function.access_facts) |fact| switch (fact) {
        .range_slice => |access| if (access.typed_span_id.eql(instruction.typed_span_id) and
            std.meta.eql(access.result_ty, instruction.result_ty) and
            access.base_span_id.eql(instruction.typed_base_operand_span_id) and
            access.start_span_id.eql(instruction.typed_index_operand_span_id)) return true,
        else => {},
    };
    return false;
}

fn accessFactSpanId(fact: mir.AccessFact) mir.SpanId {
    return switch (fact) {
        inline else => |access| access.typed_span_id,
    };
}

fn verifyIdentityTables(function: *const mir.Function) !void {
    for (function.type_identities, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) return error.InvalidTypeIdentity;
    }
    for (function.span_identities, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) return error.InvalidSpanIdentity;
    }
    for (function.value_identities, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) return error.InvalidValueIdentity;
    }
}

fn verifyBlocks(function: *const mir.Function) !void {
    for (function.blocks, 0..) |block, ordinal| {
        if (block.id != ordinal or !block.typed_id.isValid()) return error.InvalidBlockIdentity;
        for (function.blocks[0..ordinal]) |prior| {
            if (prior.typed_id.eql(block.typed_id)) return error.DuplicateBlockIdentity;
        }
        if (block.typed_successors.len != 0) {
            if (block.typed_successors.len != block.successors.len) return error.InconsistentTypedSuccessor;
            for (block.successors, block.typed_successors) |successor, typed_successor| {
                if (successor >= function.blocks.len) return error.InvalidSuccessor;
                if (!typed_successor.isValid() or !typed_successor.eql(function.blocks[successor].typed_id)) {
                    return error.InconsistentTypedSuccessor;
                }
            }
        }
        for (block.successors) |successor| if (successor >= function.blocks.len) return error.InvalidSuccessor;
        try verifyTerminator(function, block);
    }
}

fn verifyTerminator(function: *const mir.Function, block: mir.Block) !void {
    const normal_count = normalSuccessorCount(function, block);
    switch (block.terminator) {
        .fallthrough, .return_, .trap_, .unreachable_ => if (normal_count != 0) return error.InvalidTerminator,
        .jump => |target| if (normal_count != 1 or !normalSuccessorListed(function, block, target)) return error.InvalidTerminator,
        .branch => |branch| if (normal_count != 2 or
            !normalSuccessorListed(function, block, branch.true_block) or
            !normalSuccessorListed(function, block, branch.false_block)) return error.InvalidTerminator,
        .switch_ => if (normal_count == 0) return error.InvalidTerminator,
    }
}

fn verifyTrapEdges(function: *const mir.Function) !void {
    for (function.trap_edges) |edge| {
        if (edge.from_block >= function.blocks.len or edge.trap_block >= function.blocks.len) return error.InvalidTrapEdge;
        if (!successorListed(function.blocks[edge.from_block], edge.trap_block)) return error.InvalidTrapEdge;
        switch (function.blocks[edge.trap_block].terminator) {
            .trap_ => |kind| if (kind != edge.kind) return error.InvalidTrapEdge,
            else => return error.InvalidTrapEdge,
        }
    }
}

fn verifyInstructions(function: *const mir.Function) !void {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.typed_result_ty.isValid()) {
            const identity = typeIdentity(function, instruction.typed_result_ty) orelse return error.InvalidInstructionType;
            if (!std.mem.eql(u8, identity.spelling, instruction.result_ty.name())) return error.InvalidInstructionType;
        }
        try verifyInstructionSpan(function, instruction.typed_span_id, null);
        inline for ([_]mir.SpanId{
            instruction.typed_left_operand_span_id,
            instruction.typed_right_operand_span_id,
            instruction.typed_base_operand_span_id,
            instruction.typed_index_operand_span_id,
            instruction.typed_target_operand_span_id,
            instruction.typed_value_operand_span_id,
            instruction.typed_callee_span_id,
            instruction.typed_callee_root_span_id,
        }) |span_id| try verifyInstructionSpan(function, span_id, null);
        for (instruction.typed_aggregate_operand_span_ids) |span_id| try verifyInstructionSpan(function, span_id, null);
        if (instruction.typed_aggregate_operand_count > mir.Instruction.max_aggregate_operands or
            instruction.typed_switch_pattern_count > mir.Instruction.max_switch_patterns) return error.InvalidInstructionMetadata;

        if (instruction.typed_value_id) |value_id| {
            _ = valueIdentity(function, value_id) orelse return error.InvalidValueReference;
        }
        if (instruction.typed_operand_value_id.isValid() and valueIdentity(function, instruction.typed_operand_value_id) == null) {
            return error.InvalidValueReference;
        }
        if (instruction.typed_callee_root_value_id.isValid() and valueIdentity(function, instruction.typed_callee_root_value_id) == null) {
            return error.InvalidValueReference;
        }
    };
}

fn verifyInstructionSpan(function: *const mir.Function, span_id: mir.SpanId, expected: ?mir.SourcePoint) !void {
    if (!span_id.isValid()) return;
    const identity = spanIdentity(function, span_id) orelse return error.InvalidSpanReference;
    if (expected) |source| if (!instructionSourceMatches(identity.source, source)) return error.InvalidSpanReference;
}

fn verifyCleanup(function: *const mir.Function) !void {
    for (function.ownership_cleanup_plan.actions) |action| {
        if (action.place.root_value_id.isValid() and valueIdentity(function, action.place.root_value_id) == null) return error.InvalidCleanupAction;
    }
    for (function.cleanup_cfg.edges) |edge| {
        // Cleanup CFG edges describe lexical exits, not the normal CFG. The
        // producer legitimately uses an invalid source/target BlockId for a
        // function/scope exit with no concrete control-flow block. Preserve
        // those sentinels in the snapshot instead of imposing normal-CFG
        // reachability requirements here.
        for (edge.actions) |action| switch (action) {
            .ownership => |ref| try verifyOwnershipCleanupRef(function, ref),
            .defer_cleanup => |ref| try verifyDeferCleanupRef(function, ref),
        };
    }
}

fn verifyOwnershipCleanupRef(function: *const mir.Function, ref: mir.OwnershipCleanupEdgeActionRef) !void {
    if (ref.cleanup_action_index >= function.ownership_cleanup_plan.actions.len) return error.InvalidCleanupAction;
    const action = function.ownership_cleanup_plan.actions[ref.cleanup_action_index];
    if (action.kind != ref.kind or action.primary_event_index != ref.primary_event_index or
        action.storage_dead_event_index != ref.storage_dead_event_index or
        !action.place.root_value_id.eql(ref.root_value_id) or
        !action.place.root_type_symbol_id.eql(ref.resource_type_symbol_id) or
        !action.drop_glue_symbol_id.eql(ref.drop_glue_symbol_id) or
        action.generation != ref.generation or !action.block_id.eql(ref.block_id) or
        !sourceEquivalent(action.source, ref.source)) return error.InvalidCleanupAction;
    if (ref.root_value_id.isValid() and valueIdentity(function, ref.root_value_id) == null) return error.InvalidCleanupAction;
}

fn verifyDeferCleanupRef(function: *const mir.Function, ref: mir.DeferCleanupEdgeActionRef) !void {
    if (!blockExists(function, ref.block_id)) return error.InvalidCleanupAction;
    const block = blockById(function, ref.block_id).?;
    if (ref.instruction_index >= block.instructions.len) return error.InvalidCleanupAction;
    const instruction = block.instructions[ref.instruction_index];
    if (instruction.kind != .defer_cleanup or !instructionSourceMatches(ref.source, sourceOf(function, instruction))) return error.InvalidCleanupAction;
}

fn buildBlocks(allocator: std.mem.Allocator, function: *const mir.Function) ![]const BlockPlan {
    const blocks = try allocator.alloc(BlockPlan, function.blocks.len);
    errdefer allocator.free(blocks);
    for (function.blocks, 0..) |block, ordinal| {
        const instructions = try allocator.alloc(InstructionPlan, block.instructions.len);
        errdefer allocator.free(instructions);
        for (block.instructions, 0..) |instruction, index| instructions[index] = instructionPlan(function, instruction);
        const successors = try allocator.alloc(mir.BlockId, block.successors.len);
        errdefer allocator.free(successors);
        if (block.typed_successors.len != 0) {
            @memcpy(successors, block.typed_successors);
        } else {
            for (block.successors, 0..) |successor, index| successors[index] = function.blocks[successor].typed_id;
        }
        blocks[ordinal] = .{
            .id = block.typed_id,
            .ordinal = ordinal,
            .kind = block.kind,
            .instructions = instructions,
            .successors = successors,
            .terminator = terminatorPlan(function, block.terminator),
        };
    }
    return blocks;
}

fn instructionPlan(function: *const mir.Function, instruction: mir.Instruction) InstructionPlan {
    return .{
        .kind = instruction.kind,
        .detail = instruction.detail,
        .result_ty = instruction.result_ty,
        .type_id = instruction.typed_result_ty,
        .value_id = instruction.typed_value_id orelse .invalid,
        .location = .{
            .span_id = instruction.typed_span_id,
            .source = sourceOf(function, instruction),
        },
        .operands = .{
            .left = instruction.typed_left_operand_span_id,
            .right = instruction.typed_right_operand_span_id,
            .base = instruction.typed_base_operand_span_id,
            .index = instruction.typed_index_operand_span_id,
            .target = instruction.typed_target_operand_span_id,
            .value = instruction.typed_value_operand_span_id,
            .callee = instruction.typed_callee_span_id,
            .callee_root = instruction.typed_callee_root_span_id,
            .aggregate = instruction.typed_aggregate_operand_span_ids,
            .aggregate_field_indices = instruction.typed_aggregate_field_indices,
            .aggregate_count = instruction.typed_aggregate_operand_count,
        },
        .operand_value_id = instruction.typed_operand_value_id,
        .callee_root_value_id = instruction.typed_callee_root_value_id,
        .target_owner_id = instruction.typed_target_owner_id,
        .aggregate_construction = instruction.aggregate_construction,
        .const_index = instruction.const_index,
        .target_index = instruction.target_index,
        .member_field_index = instruction.member_field_index,
        .builtin_member = instruction.builtin_member,
        .constant_index_value = instruction.constant_index_value,
        .static_index_bound = instruction.static_index_bound,
        .constant_usize_value = instruction.constant_usize_value,
        .callee_field_index = instruction.callee_field_index,
        .contract_region_id = instruction.contract_region_id,
        .switch_patterns = instruction.typed_switch_patterns,
        .switch_pattern_count = instruction.typed_switch_pattern_count,
    };
}

fn terminatorPlan(function: *const mir.Function, terminator: mir.Terminator) TerminatorPlan {
    return switch (terminator) {
        .fallthrough => .fallthrough,
        .jump => |target| .{ .jump = function.blocks[target].typed_id },
        .branch => |branch| .{ .branch = .{
            .true_block = function.blocks[branch.true_block].typed_id,
            .false_block = function.blocks[branch.false_block].typed_id,
        } },
        .return_ => |ty| .{ .return_ = ty },
        .trap_ => |kind| .{ .trap_ = kind },
        .unreachable_ => .unreachable_,
        .switch_ => .switch_,
    };
}

fn buildTrapEdges(allocator: std.mem.Allocator, function: *const mir.Function) ![]const TrapEdgePlan {
    const edges = try allocator.alloc(TrapEdgePlan, function.trap_edges.len);
    for (function.trap_edges, 0..) |edge, index| edges[index] = .{
        .from_block = function.blocks[edge.from_block].typed_id,
        .trap_block = function.blocks[edge.trap_block].typed_id,
        .kind = edge.kind,
        .source = edge.source,
        .location = .{ .span_id = edge.typed_span_id, .source = .{
            .line = edge.line,
            .column = edge.column,
            .offset = edge.source_offset,
            .len = edge.source_len,
        } },
    };
    return edges;
}

fn buildOwnershipActions(allocator: std.mem.Allocator, function: *const mir.Function) ![]const OwnershipCleanupActionPlan {
    const actions = try allocator.alloc(OwnershipCleanupActionPlan, function.ownership_cleanup_plan.actions.len);
    for (function.ownership_cleanup_plan.actions, 0..) |action, index| actions[index] = .{
        .kind = action.kind,
        .primary_event_index = action.primary_event_index,
        .storage_dead_event_index = action.storage_dead_event_index,
        .place = action.place,
        .generation = action.generation,
        .drop_glue_symbol_id = action.drop_glue_symbol_id,
        .block_id = action.block_id,
        .location = .{ .span_id = spanIdAtSource(function, action.source), .source = action.source },
    };
    return actions;
}

fn buildCleanupEdges(allocator: std.mem.Allocator, function: *const mir.Function) ![]const CleanupEdgePlan {
    const edges = try allocator.alloc(CleanupEdgePlan, function.cleanup_cfg.edges.len);
    errdefer allocator.free(edges);
    for (function.cleanup_cfg.edges, 0..) |edge, edge_index| {
        const actions = try allocator.alloc(CleanupActionPlan, edge.actions.len);
        errdefer allocator.free(actions);
        for (edge.actions, 0..) |action, action_index| actions[action_index] = switch (action) {
            .ownership => |ref| .{ .ownership = .{
                .cleanup_action_index = ref.cleanup_action_index,
                .kind = ref.kind,
                .primary_event_index = ref.primary_event_index,
                .storage_dead_event_index = ref.storage_dead_event_index,
                .root_value_id = ref.root_value_id,
                .resource_type_symbol_id = ref.resource_type_symbol_id,
                .drop_glue_symbol_id = ref.drop_glue_symbol_id,
                .generation = ref.generation,
                .block_id = ref.block_id,
                .location = .{ .span_id = spanIdAtSource(function, ref.source), .source = ref.source },
            } },
            .defer_cleanup => |ref| .{ .defer_cleanup = .{
                .block_id = ref.block_id,
                .instruction_index = ref.instruction_index,
                .location = .{ .span_id = spanIdAtSource(function, ref.source), .source = ref.source },
            } },
        };
        edges[edge_index] = .{
            .kind = edge.kind,
            .source_block = edge.source_block,
            .target_block = edge.target_block,
            .location = .{ .span_id = spanIdAtSource(function, edge.source), .source = edge.source },
            .actions = actions,
        };
    }
    return edges;
}

fn freeBlocks(allocator: std.mem.Allocator, blocks: []const BlockPlan) void {
    for (blocks) |block| {
        allocator.free(block.instructions);
        allocator.free(block.successors);
    }
    allocator.free(blocks);
}

fn freeCleanupEdges(allocator: std.mem.Allocator, edges: []const CleanupEdgePlan) void {
    for (edges) |edge| allocator.free(edge.actions);
    allocator.free(edges);
}

fn typeIdentity(function: *const mir.Function, id: mir.TypeId) ?mir.TypeIdentity {
    if (!id.isValid() or id.index() >= function.type_identities.len) return null;
    const identity = function.type_identities[id.index()];
    return if (identity.id.eql(id)) identity else null;
}

fn spanIdentity(function: *const mir.Function, id: mir.SpanId) ?mir.SpanIdentity {
    if (!id.isValid() or id.index() >= function.span_identities.len) return null;
    const identity = function.span_identities[id.index()];
    return if (identity.id.eql(id)) identity else null;
}

fn valueIdentity(function: *const mir.Function, id: mir.ValueId) ?mir.ValueIdentity {
    if (!id.isValid() or id.index() >= function.value_identities.len) return null;
    const identity = function.value_identities[id.index()];
    return if (identity.id.eql(id)) identity else null;
}

fn blockExists(function: *const mir.Function, id: mir.BlockId) bool {
    return blockById(function, id) != null;
}

fn blockById(function: *const mir.Function, id: mir.BlockId) ?mir.Block {
    if (!id.isValid()) return null;
    for (function.blocks) |block| if (block.typed_id.eql(id)) return block;
    return null;
}

fn normalSuccessorCount(function: *const mir.Function, block: mir.Block) usize {
    var count: usize = 0;
    for (block.successors) |successor| {
        if (!isTrapSuccessor(function, block.id, successor)) count += 1;
    }
    return count;
}

fn normalSuccessorListed(function: *const mir.Function, block: mir.Block, target: usize) bool {
    return successorListed(block, target) and !isTrapSuccessor(function, block.id, target);
}

fn isTrapSuccessor(function: *const mir.Function, from: usize, target: usize) bool {
    for (function.trap_edges) |edge| if (edge.from_block == from and edge.trap_block == target) return true;
    return false;
}

fn successorListed(block: mir.Block, target: usize) bool {
    for (block.successors) |successor| if (successor == target) return true;
    return false;
}

fn spanIdAtSource(function: *const mir.Function, source: mir.SourcePoint) mir.SpanId {
    var found: mir.SpanId = .invalid;
    for (function.span_identities) |identity| {
        if (!sourceEquivalent(identity.source, source)) continue;
        if (found.isValid()) return .invalid;
        found = identity.id;
    }
    return found;
}

fn sourceOf(function: *const mir.Function, instruction: mir.Instruction) mir.SourcePoint {
    return if (spanIdentity(function, instruction.typed_span_id)) |identity|
        identity.source
    else
        .{ .line = 1, .column = 1 };
}

fn sourceEquivalent(a: mir.SourcePoint, b: mir.SourcePoint) bool {
    return a.line == b.line and a.column == b.column and a.offset == b.offset and a.len == b.len and a.file_id == b.file_id;
}

/// `SpanId` is the authority for instruction provenance. The fallback only
/// preserves line/column for malformed hand-built fixtures; admitted MIR must
/// resolve every instruction span through the identity table.
fn instructionSourceMatches(span_source: mir.SourcePoint, instruction_source: mir.SourcePoint) bool {
    if (span_source.line != instruction_source.line or span_source.column != instruction_source.column) return false;
    if (span_source.offset == 0 and span_source.len == 0 and instruction_source.offset == 0 and instruction_source.len == 0) return true;
    return span_source.offset == instruction_source.offset and span_source.len == instruction_source.len;
}

test "MIR body plan normalizes typed CFG, identities, and cleanup edges" {
    var fixture = Fixture{};
    fixture.init();
    var plan = try build(std.testing.allocator, &fixture.function);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), plan.blocks.len);
    try std.testing.expect(plan.block(mir.BlockId.fromIndex(0)) != null);
    try std.testing.expectEqual(mir.BlockId.fromIndex(1), plan.blocks[0].successors[0]);
    switch (plan.blocks[0].terminator) {
        .branch => |branch| {
            try std.testing.expectEqual(mir.BlockId.fromIndex(1), branch.true_block);
            try std.testing.expectEqual(mir.BlockId.fromIndex(2), branch.false_block);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("input", plan.value(mir.ValueId.fromIndex(0)).?.spelling);
    try std.testing.expectEqualStrings("u32", plan.typeIdentity(mir.TypeId.fromIndex(0)).?.spelling);
    try std.testing.expectEqual(@as(usize, 1), plan.cleanup_edges.len);
    switch (plan.cleanup_edges[0].actions[0]) {
        .ownership => |action| try std.testing.expectEqual(mir.ValueId.fromIndex(0), action.root_value_id),
        .defer_cleanup => return error.TestUnexpectedResult,
    }
}

test "MIR body plan verifier rejects inconsistent typed successor" {
    var fixture = Fixture{};
    fixture.init();
    fixture.entry_typed_successors[0] = mir.BlockId.fromIndex(2);
    try std.testing.expectError(error.InconsistentTypedSuccessor, verify(&fixture.function));
}

test "MIR body plan verifier rejects invalid value identity" {
    var fixture = Fixture{};
    fixture.init();
    fixture.instruction[0].typed_value_id = mir.ValueId.fromIndex(1);
    try std.testing.expectError(error.InvalidValueReference, verify(&fixture.function));
}

test "MIR body plan verifier rejects stale cleanup action reference" {
    var fixture = Fixture{};
    fixture.init();
    var stale_ref = fixture.cleanup_refs[0].ownership;
    stale_ref.cleanup_action_index = 1;
    fixture.cleanup_refs[0] = .{ .ownership = stale_ref };
    try std.testing.expectError(error.InvalidCleanupAction, verify(&fixture.function));
}

const Fixture = struct {
    instruction: [1]mir.Instruction = undefined,
    entry_successors: [2]usize = .{ 1, 2 },
    entry_typed_successors: [2]mir.BlockId = .{ mir.BlockId.fromIndex(1), mir.BlockId.fromIndex(2) },
    blocks: [3]mir.Block = undefined,
    type_identities: [1]mir.TypeIdentity = .{.{ .id = mir.TypeId.fromIndex(0), .spelling = "u32" }},
    span_identities: [1]mir.SpanIdentity = .{.{ .id = mir.SpanId.fromIndex(0), .source = point() }},
    value_identities: [1]mir.ValueIdentity = .{.{ .id = mir.ValueId.fromIndex(0), .spelling = "input" }},
    cleanup_actions: [1]mir.CleanupActionPlanEntry = undefined,
    cleanup_refs: [1]mir.CleanupCfgActionRef = undefined,
    cleanup_edges: [1]mir.CleanupCfgEdge = undefined,
    function: mir.Function = undefined,

    fn init(self: *Fixture) void {
        self.instruction = .{.{
            .kind = .param,
            .result_ty = .{ .integer = "u32" },
            .typed_result_ty = mir.TypeId.fromIndex(0),
            .detail = "input",
            .typed_value_id = mir.ValueId.fromIndex(0),
            .typed_span_id = mir.SpanId.fromIndex(0),
        }};
        self.blocks = .{
            .{
                .id = 0,
                .typed_id = mir.BlockId.fromIndex(0),
                .kind = "entry",
                .instructions = self.instruction[0..],
                .successors = self.entry_successors[0..],
                .typed_successors = self.entry_typed_successors[0..],
                .terminator = .{ .branch = .{ .true_block = 1, .false_block = 2 } },
            },
            .{ .id = 1, .typed_id = mir.BlockId.fromIndex(1), .kind = "return", .instructions = &.{}, .successors = &.{}, .typed_successors = &.{}, .terminator = .{ .return_ = .{ .integer = "u32" } } },
            .{ .id = 2, .typed_id = mir.BlockId.fromIndex(2), .kind = "unreachable", .instructions = &.{}, .successors = &.{}, .typed_successors = &.{}, .terminator = .unreachable_ },
        };
        self.cleanup_actions = .{.{
            .kind = .auto_drop,
            .primary_event_index = 0,
            .place = .{ .root_value_id = mir.ValueId.fromIndex(0) },
            .drop_glue_symbol_id = .invalid,
            .block_id = mir.BlockId.fromIndex(0),
            .source = point(),
        }};
        self.cleanup_refs = .{.{ .ownership = .{
            .cleanup_action_index = 0,
            .kind = .auto_drop,
            .primary_event_index = 0,
            .root_value_id = mir.ValueId.fromIndex(0),
            .resource_type_symbol_id = .invalid,
            .drop_glue_symbol_id = .invalid,
            .block_id = mir.BlockId.fromIndex(0),
            .source = point(),
        } }};
        self.cleanup_edges = .{.{
            .kind = .return_exit,
            .source_block = mir.BlockId.fromIndex(0),
            .source = point(),
            .actions = self.cleanup_refs[0..],
        }};
        self.function = .{
            .name = "sample",
            .return_ty = .{ .integer = "u32" },
            .no_lang_trap = false,
            .irq_context = false,
            .blocks = self.blocks[0..],
            .trap_edges = &.{},
            .contract_regions = &.{},
            .range_facts = &.{},
            .span_identities = self.span_identities[0..],
            .type_identities = self.type_identities[0..],
            .value_identities = self.value_identities[0..],
            .ownership_cleanup_plan = .{ .actions = self.cleanup_actions[0..] },
            .cleanup_cfg = .{ .edges = self.cleanup_edges[0..] },
            .pointer_provenance_facts = &.{},
            .representation_facts = &.{},
            .elided_bounds = &.{},
        };
    }
};

fn point() mir.SourcePoint {
    return .{ .line = 1, .column = 3, .offset = 2, .len = 5 };
}
