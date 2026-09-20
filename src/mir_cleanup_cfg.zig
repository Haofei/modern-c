//! Cleanup CFG and ownership-event authority for MIR.
//!
//! Source-point identity, the defer and ownership cleanup edge tables, the
//! merged `CleanupCfg`, and the ownership-event / drop-glue validators that
//! the cleanup edges are derived from.
//!
//! Split out of `mir.zig` with no behavior change; `mir.zig` re-exports the
//! public entry points so existing `mir.X` call sites compile unchanged.

const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const mir_model = @import("mir_model.zig");

const Block = mir_model.Block;
const BlockId = mir_model.BlockId;
const CallTargetFact = mir_model.CallTargetFact;
const CleanupActionPlanEntry = mir_model.CleanupActionPlanEntry;
const CleanupCancellationPlanEntry = mir_model.CleanupCancellationPlanEntry;
const CleanupCfg = mir_model.CleanupCfg;
const CleanupCfgActionRef = mir_model.CleanupCfgActionRef;
const CleanupCfgEdge = mir_model.CleanupCfgEdge;
const CleanupCfgEdgeKind = mir_model.CleanupCfgEdgeKind;
const DeferCleanupEdge = mir_model.DeferCleanupEdge;
const DeferCleanupEdgeActionRef = mir_model.DeferCleanupEdgeActionRef;
const DeferCleanupEdgeKind = mir_model.DeferCleanupEdgeKind;
const DeferCleanupEdgeTable = mir_model.DeferCleanupEdgeTable;
const DropGlueFact = mir_model.DropGlueFact;
const Function = mir_model.Function;
const Instruction = mir_model.Instruction;
const Module = mir_model.Module;
const OwnershipCleanupEdge = mir_model.OwnershipCleanupEdge;
const OwnershipCleanupEdgeActionRef = mir_model.OwnershipCleanupEdgeActionRef;
const OwnershipCleanupEdgeKind = mir_model.OwnershipCleanupEdgeKind;
const OwnershipCleanupEdgeTable = mir_model.OwnershipCleanupEdgeTable;
const OwnershipCleanupPlan = mir_model.OwnershipCleanupPlan;
const OwnershipEvent = mir_model.OwnershipEvent;
const OwnershipPlace = mir_model.OwnershipPlace;
const OwnershipPlaceProjection = mir_model.OwnershipPlaceProjection;
const SourcePoint = mir_model.SourcePoint;
const SpanId = mir_model.SpanId;
const SymbolId = mir_model.SymbolId;
const TargetTypeFact = mir_model.TargetTypeFact;
const TargetTypeKind = mir_model.TargetTypeKind;
const TypeOwnershipFact = mir_model.TypeOwnershipFact;
const ValueId = mir_model.ValueId;

pub fn sourcePointSpan(point: SourcePoint) diagnostics.Span {
    return .{ .offset = 0, .len = 0, .line = point.line, .column = @intCast(point.column), .file_id = point.file_id };
}

pub fn sourcePointFromSpan(span: ast.Span) SourcePoint {
    return .{ .line = span.line, .column = span.column, .offset = span.offset, .len = span.len, .file_id = span.file_id };
}

pub fn canonicalOperatorOperand(expr: ast.Expr) ast.Expr {
    return switch (expr.kind) {
        .grouped => |inner| canonicalOperatorOperand(inner.*),
        else => expr,
    };
}

pub const DeferCleanupRef = struct {
    block_id: BlockId,
    instruction_index: usize,
    source: SourcePoint,
};

/// The opaque span ID is the sole source identity carried by an instruction.
/// Consumers may materialize coordinates only at diagnostics or rendering
/// boundaries through the owning function table.
pub fn instructionSourcePoint(function: Function, instruction: Instruction) ?SourcePoint {
    return sourcePointForSpanId(function, instruction.typed_span_id);
}

fn sourcePointMatchesInstruction(function: Function, source: SourcePoint, instruction: Instruction) bool {
    const span_id = spanIdAtSource(function, source) orelse return false;
    return instructionMatchesSpanId(function, instruction, span_id);
}

pub fn deferCleanupRefAtSource(function: Function, source: SourcePoint) ?DeferCleanupRef {
    for (function.blocks, 0..) |block, block_index| {
        for (block.instructions, 0..) |instruction, instruction_index| {
            if (instruction.kind != .defer_cleanup) continue;
            if (!sourcePointMatchesInstruction(function, source, instruction)) continue;
            return .{
                .block_id = BlockId.fromIndex(block_index),
                .instruction_index = instruction_index,
                .source = source,
            };
        }
    }
    return null;
}

pub fn spanIdAtSource(function: Function, source: SourcePoint) ?SpanId {
    for (function.span_identities) |identity| {
        if (!sourcePointEquivalent(identity.source, source)) continue;
        return identity.id;
    }
    return null;
}

pub fn sourcePointForSpanId(function: Function, typed_span_id: SpanId) ?SourcePoint {
    if (!typed_span_id.isValid() or typed_span_id.index() >= function.span_identities.len) return null;
    const identity = function.span_identities[typed_span_id.index()];
    return if (identity.id.eql(typed_span_id)) identity.source else null;
}

pub fn instructionMatchesSpanId(function: Function, instruction: Instruction, typed_span_id: SpanId) bool {
    if (sourcePointForSpanId(function, typed_span_id) == null) return false;
    return instruction.typed_span_id.isValid() and instruction.typed_span_id.eql(typed_span_id);
}

pub fn targetTypeFactMatchesSpanId(function: Function, fact: TargetTypeFact, typed_span_id: SpanId) bool {
    if (sourcePointForSpanId(function, typed_span_id) == null) return false;
    return fact.typed_span_id.isValid() and fact.typed_span_id.eql(typed_span_id);
}

pub fn callTargetFactMatchesSpanId(function: Function, fact: CallTargetFact, typed_span_id: SpanId) bool {
    if (sourcePointForSpanId(function, typed_span_id) == null) return false;
    return fact.typed_span_id.isValid() and fact.typed_span_id.eql(typed_span_id);
}

pub fn deferCleanupRefValid(function: Function, ref: DeferCleanupRef) bool {
    if (!ref.block_id.isValid() or ref.block_id.index() >= function.blocks.len) return false;
    const block = function.blocks[ref.block_id.index()];
    if (ref.instruction_index >= block.instructions.len) return false;
    const instruction = block.instructions[ref.instruction_index];
    return instruction.kind == .defer_cleanup and sourcePointMatchesInstruction(function, ref.source, instruction);
}

pub fn buildDeferCleanupEdgeTable(
    allocator: std.mem.Allocator,
    function: Function,
) error{ OutOfMemory, InvalidSpanReference }!DeferCleanupEdgeTable {
    var refs: std.ArrayList(DeferCleanupEdgeActionRef) = .empty;
    defer refs.deinit(allocator);

    var block_index: usize = function.blocks.len;
    while (block_index > 0) {
        block_index -= 1;
        const block = function.blocks[block_index];
        var instruction_index: usize = block.instructions.len;
        while (instruction_index > 0) {
            instruction_index -= 1;
            const instruction = block.instructions[instruction_index];
            if (instruction.kind != .defer_cleanup) continue;
            try refs.append(allocator, .{
                .block_id = BlockId.fromIndex(block_index),
                .instruction_index = instruction_index,
                .source = sourcePointFromInstruction(function, instruction) orelse return error.InvalidSpanReference,
            });
        }
    }

    if (refs.items.len == 0) return .{};
    const actions = try refs.toOwnedSlice(allocator);
    defer allocator.free(actions);

    var edge_list: std.ArrayList(DeferCleanupEdge) = .empty;
    errdefer {
        for (edge_list.items) |*edge| allocator.free(edge.actions);
        edge_list.deinit(allocator);
    }

    try appendDeferCleanupCfgEdge(allocator, &edge_list, .scope_exit, .invalid, null, .{ .line = 0, .column = 0 }, actions);
    try appendDeferCleanupCfgEdge(allocator, &edge_list, .error_exit, .invalid, null, .{ .line = 0, .column = 0 }, actions);

    for (function.blocks) |block| {
        const source = cleanupEdgeSourceForBlock(function, block) orelse return error.InvalidSpanReference;
        switch (block.terminator) {
            .return_ => try appendDeferCleanupCfgEdge(allocator, &edge_list, .return_exit, block.id, null, source, actions),
            .jump => |target| {
                const target_block: ?BlockId = if (target.isValid() and target.index() < function.blocks.len) function.blocks[target.index()].id else null;
                try appendDeferCleanupCfgEdge(allocator, &edge_list, .break_exit, block.id, target_block, source, actions);
                try appendDeferCleanupCfgEdge(allocator, &edge_list, .continue_exit, block.id, target_block, source, actions);
            },
            .fallthrough, .branch, .trap_, .unreachable_, .switch_ => {},
        }
    }

    const edges = try edge_list.toOwnedSlice(allocator);
    var table: DeferCleanupEdgeTable = .{ .edges = edges };
    if (!deferCleanupEdgeTableValid(function, table)) {
        table.deinit(allocator);
        return .{};
    }
    return table;
}

fn appendDeferCleanupCfgEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(DeferCleanupEdge),
    kind: DeferCleanupEdgeKind,
    source_block: BlockId,
    target_block: ?BlockId,
    source: SourcePoint,
    actions: []const DeferCleanupEdgeActionRef,
) error{OutOfMemory}!void {
    const edge_actions = try allocator.dupe(DeferCleanupEdgeActionRef, actions);
    errdefer allocator.free(edge_actions);
    try edges.append(allocator, .{
        .kind = kind,
        .source_block = source_block,
        .target_block = target_block,
        .source = source,
        .actions = edge_actions,
    });
}

fn cleanupEdgeSourceForBlock(function: Function, block: Block) ?SourcePoint {
    if (block.instructions.len == 0) return .{ .line = 0, .column = 0 };
    return sourcePointFromInstruction(function, block.instructions[block.instructions.len - 1]);
}

pub fn cleanupCfgEdgeKindFromOwnership(kind: OwnershipCleanupEdgeKind) CleanupCfgEdgeKind {
    return switch (kind) {
        .scope_exit => .scope_exit,
        .return_exit => .return_exit,
        .break_exit => .break_exit,
        .continue_exit => .continue_exit,
        .error_exit => .error_exit,
    };
}

pub fn cleanupCfgEdgeKindFromDefer(kind: DeferCleanupEdgeKind) CleanupCfgEdgeKind {
    return switch (kind) {
        .scope_exit => .scope_exit,
        .return_exit => .return_exit,
        .break_exit => .break_exit,
        .continue_exit => .continue_exit,
        .error_exit => .error_exit,
    };
}

pub fn buildCleanupCfg(
    allocator: std.mem.Allocator,
    module: Module,
    function: Function,
    ownership_plan: OwnershipCleanupPlan,
) error{ InvalidMirOwnershipEvents, InvalidSpanReference, OutOfMemory }!CleanupCfg {
    var ownership_edges = try buildOwnershipCleanupEdgeTable(allocator, module, function, ownership_plan);
    defer ownership_edges.deinit(allocator);
    var defer_edges = try buildDeferCleanupEdgeTable(allocator, function);
    defer defer_edges.deinit(allocator);
    return try buildCleanupCfgFromEdgeTables(allocator, module, function, ownership_plan, ownership_edges, defer_edges);
}

pub fn buildCleanupCfgFromEdgeTables(
    allocator: std.mem.Allocator,
    module: Module,
    function: Function,
    ownership_plan: OwnershipCleanupPlan,
    ownership_edges: OwnershipCleanupEdgeTable,
    defer_edges: DeferCleanupEdgeTable,
) error{ InvalidMirOwnershipEvents, OutOfMemory }!CleanupCfg {
    if (!ownershipCleanupEdgeTableValid(module, function, ownership_plan, ownership_edges)) return error.InvalidMirOwnershipEvents;
    if (!deferCleanupEdgeTableValid(function, defer_edges)) return error.InvalidMirOwnershipEvents;

    var cfg_edges: std.ArrayList(CleanupCfgEdge) = .empty;
    errdefer {
        for (cfg_edges.items) |*edge| allocator.free(edge.actions);
        cfg_edges.deinit(allocator);
    }

    for (ownership_edges.edges) |edge| {
        var actions = try allocator.alloc(CleanupCfgActionRef, edge.actions.len);
        errdefer allocator.free(actions);
        for (edge.actions, 0..) |action, index| actions[index] = .{ .ownership = action };
        try cfg_edges.append(allocator, .{
            .kind = cleanupCfgEdgeKindFromOwnership(edge.kind),
            .source_block = edge.source_block,
            .target_block = edge.target_block,
            .source = edge.source,
            .actions = actions,
        });
    }

    for (defer_edges.edges) |edge| {
        var actions = try allocator.alloc(CleanupCfgActionRef, edge.actions.len);
        errdefer allocator.free(actions);
        for (edge.actions, 0..) |action, index| actions[index] = .{ .defer_cleanup = action };
        try cfg_edges.append(allocator, .{
            .kind = cleanupCfgEdgeKindFromDefer(edge.kind),
            .source_block = edge.source_block,
            .target_block = edge.target_block,
            .source = edge.source,
            .actions = actions,
        });
    }

    const edges = try cfg_edges.toOwnedSlice(allocator);
    var cfg: CleanupCfg = .{ .edges = edges };
    if (!cleanupCfgValid(module, function, ownership_plan, cfg)) {
        cfg.deinit(allocator);
        return error.InvalidMirOwnershipEvents;
    }
    return cfg;
}

pub fn cleanupCfgValid(
    module: Module,
    function: Function,
    ownership_plan: OwnershipCleanupPlan,
    cfg: CleanupCfg,
) bool {
    if (!ownershipCleanupPlanValid(module, function, ownership_plan)) return false;
    for (cfg.edges) |edge| {
        for (edge.actions) |action| {
            switch (action) {
                .ownership => |ref| if (!ownershipCleanupEdgeActionRefValid(module, function, ownership_plan, ref)) return false,
                .defer_cleanup => |ref| if (!deferCleanupEdgeActionRefValid(function, ref)) return false,
            }
        }
    }
    return true;
}

pub fn ownershipCleanupPlanEquivalent(a: OwnershipCleanupPlan, b: OwnershipCleanupPlan) bool {
    if (a.actions.len != b.actions.len or a.cancellations.len != b.cancellations.len) return false;
    for (a.actions, b.actions) |left, right| {
        if (!cleanupActionPlanEntryEquivalent(left, right)) return false;
    }
    for (a.cancellations, b.cancellations) |left, right| {
        if (!cleanupCancellationPlanEntryEquivalent(left, right)) return false;
    }
    return true;
}

pub fn cleanupCfgEquivalent(a: CleanupCfg, b: CleanupCfg) bool {
    if (a.edges.len != b.edges.len) return false;
    for (a.edges, b.edges) |left, right| {
        if (left.kind != right.kind) return false;
        if (!left.source_block.eql(right.source_block)) return false;
        if (left.target_block == null and right.target_block != null) return false;
        if (left.target_block != null and right.target_block == null) return false;
        if (left.target_block) |left_target| {
            if (!left_target.eql(right.target_block.?)) return false;
        }
        if (!sourcePointEquivalent(left.source, right.source)) return false;
        if (left.actions.len != right.actions.len) return false;
        for (left.actions, right.actions) |left_action, right_action| {
            if (!cleanupCfgActionRefEquivalent(left_action, right_action)) return false;
        }
    }
    return true;
}

fn cleanupActionPlanEntryEquivalent(a: CleanupActionPlanEntry, b: CleanupActionPlanEntry) bool {
    return a.kind == b.kind and
        a.primary_event_index == b.primary_event_index and
        a.storage_dead_event_index == b.storage_dead_event_index and
        ownershipPlaceEquivalent(a.place, b.place) and
        a.generation == b.generation and
        a.drop_glue_symbol_id.eql(b.drop_glue_symbol_id) and
        a.block_id.eql(b.block_id) and
        sourcePointEquivalent(a.source, b.source);
}

fn cleanupCancellationPlanEntryEquivalent(a: CleanupCancellationPlanEntry, b: CleanupCancellationPlanEntry) bool {
    return a.kind == b.kind and
        a.event_index == b.event_index and
        ownershipPlaceEquivalent(a.place, b.place) and
        a.generation == b.generation and
        a.drop_glue_symbol_id.eql(b.drop_glue_symbol_id) and
        a.block_id.eql(b.block_id) and
        sourcePointEquivalent(a.source, b.source);
}

fn ownershipPlaceEquivalent(a: OwnershipPlace, b: OwnershipPlace) bool {
    if (!a.root_value_id.eql(b.root_value_id)) return false;
    if (!a.root_symbol_id.eql(b.root_symbol_id)) return false;
    if (!a.root_type_symbol_id.eql(b.root_type_symbol_id)) return false;
    if (a.projection_count != b.projection_count) return false;
    var index: usize = 0;
    while (index < a.projection_count) : (index += 1) {
        if (!ownershipPlaceProjectionEquivalent(a.projections[index], b.projections[index])) return false;
    }
    return true;
}

fn ownershipPlaceProjectionEquivalent(a: OwnershipPlaceProjection, b: OwnershipPlaceProjection) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .field => |field| field.eql(b.field),
        .constant_index => |constant_index| constant_index == b.constant_index,
        .deref => true,
        .wildcard_index => true,
    };
}

fn cleanupCfgActionRefEquivalent(a: CleanupCfgActionRef, b: CleanupCfgActionRef) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .ownership => |left| ownershipCleanupEdgeActionRefEquivalent(left, b.ownership),
        .defer_cleanup => |left| deferCleanupEdgeActionRefEquivalent(left, b.defer_cleanup),
    };
}

fn ownershipCleanupEdgeActionRefEquivalent(a: OwnershipCleanupEdgeActionRef, b: OwnershipCleanupEdgeActionRef) bool {
    return a.cleanup_action_index == b.cleanup_action_index and
        a.kind == b.kind and
        a.primary_event_index == b.primary_event_index and
        a.storage_dead_event_index == b.storage_dead_event_index and
        a.root_value_id.eql(b.root_value_id) and
        a.resource_type_symbol_id.eql(b.resource_type_symbol_id) and
        a.drop_glue_symbol_id.eql(b.drop_glue_symbol_id) and
        a.generation == b.generation and
        a.block_id.eql(b.block_id) and
        sourcePointEquivalent(a.source, b.source);
}

fn deferCleanupEdgeActionRefEquivalent(a: DeferCleanupEdgeActionRef, b: DeferCleanupEdgeActionRef) bool {
    return a.block_id.eql(b.block_id) and
        a.instruction_index == b.instruction_index and
        sourcePointEquivalent(a.source, b.source);
}

fn sourcePointEquivalent(a: SourcePoint, b: SourcePoint) bool {
    return a.line == b.line and a.column == b.column and a.offset == b.offset and a.len == b.len and a.file_id == b.file_id;
}

pub fn deferCleanupEdgeTableValid(function: Function, table: DeferCleanupEdgeTable) bool {
    for (table.edges) |edge| {
        for (edge.actions) |ref| {
            if (!deferCleanupEdgeActionRefValid(function, ref)) return false;
        }
    }
    return true;
}

pub fn deferCleanupEdgeTableContainsRef(table: DeferCleanupEdgeTable, ref: DeferCleanupRef) bool {
    for (table.edges) |edge| {
        for (edge.actions) |action| {
            if (!deferCleanupEdgeActionRefMatchesDeferRef(action, ref)) continue;
            return true;
        }
    }
    return false;
}

fn deferCleanupEdgeActionRefValid(function: Function, ref: DeferCleanupEdgeActionRef) bool {
    if (!ref.block_id.isValid() or ref.block_id.index() >= function.blocks.len) return false;
    const block = function.blocks[ref.block_id.index()];
    if (ref.instruction_index >= block.instructions.len) return false;
    const instruction = block.instructions[ref.instruction_index];
    return instruction.kind == .defer_cleanup and sourcePointMatchesInstruction(function, ref.source, instruction);
}

fn deferCleanupEdgeActionRefMatchesDeferRef(action: DeferCleanupEdgeActionRef, ref: DeferCleanupRef) bool {
    return action.block_id.eql(ref.block_id) and
        action.instruction_index == ref.instruction_index and
        sourcePointMatches(action.source, ref.source);
}

fn sourcePointFromInstruction(function: Function, instruction: Instruction) ?SourcePoint {
    return instructionSourcePoint(function, instruction);
}

fn sourcePointMatches(actual: SourcePoint, expected: SourcePoint) bool {
    if (actual.line != expected.line or actual.column != expected.column) return false;
    if (actual.offset == 0 and actual.len == 0 and expected.offset == 0 and expected.len == 0) return true;
    return actual.offset == expected.offset and actual.len == expected.len;
}

pub fn targetOwnerIdBySpelling(function: Function, spelling: []const u8) ?SymbolId {
    for (function.target_owner_identities) |identity| {
        if (!identity.id.isValid()) continue;
        if (std.mem.eql(u8, identity.spelling, spelling)) return identity.id;
    }
    return null;
}

pub fn targetOwnerSpelling(function: Function, owner_id: SymbolId) ?[]const u8 {
    if (!owner_id.isValid() or owner_id.index() >= function.target_owner_identities.len) return null;
    const identity = function.target_owner_identities[owner_id.index()];
    if (!identity.id.eql(owner_id)) return null;
    return identity.spelling;
}

fn targetTypeFactAtSource(function: Function, kind: TargetTypeKind, source: SourcePoint) bool {
    const typed_span_id = spanIdAtSource(function, source) orelse return false;
    for (function.target_type_facts) |fact| {
        if (fact.kind != kind) continue;
        if (!fact.typed_span_id.eql(typed_span_id)) continue;
        return true;
    }
    return false;
}

fn sourcePointOffsetsMatch(instruction_offset: usize, instruction_len: usize, source: SourcePoint) bool {
    if (instruction_offset == 0 and instruction_len == 0 and source.offset == 0 and source.len == 0) return true;
    return instruction_offset == source.offset and instruction_len == source.len;
}
pub fn validateDropGlueFactsForLowering(module: Module) error{InvalidMirDropGlueFacts}!void {
    for (module.drop_glue_facts, 0..) |fact, index| {
        if (!dropGlueResourceSymbolIdentityValid(module, fact)) return error.InvalidMirDropGlueFacts;
        if (!dropGlueReleaseSymbolIdentityValid(module, fact)) return error.InvalidMirDropGlueFacts;
        if (!moduleHasConcreteFunction(module, fact.typed_release_symbol_id)) return error.InvalidMirDropGlueFacts;
        if (!dropGlueFactHasMatchingTypeOwnershipFact(module, fact)) return error.InvalidMirDropGlueFacts;
        for (module.drop_glue_facts[0..index]) |previous| {
            if (previous.typed_resource_symbol_id.eql(fact.typed_resource_symbol_id)) return error.InvalidMirDropGlueFacts;
            if (previous.typed_release_symbol_id.eql(fact.typed_release_symbol_id)) return error.InvalidMirDropGlueFacts;
        }
    }
}

pub fn validateTypeOwnershipFactsForLowering(module: Module) error{InvalidMirTypeOwnershipFacts}!void {
    for (module.type_ownership_facts, 0..) |fact, index| {
        if (!typeOwnershipSymbolIdentityValid(module, fact)) return error.InvalidMirTypeOwnershipFacts;
        if (fact.drop_glue_symbol_id.isValid() and !moduleSymbolIdentityValid(module, fact.drop_glue_symbol_id)) return error.InvalidMirTypeOwnershipFacts;
        if (fact.drop_glue_symbol_id.isValid()) {
            if (fact.kind != .affine) return error.InvalidMirTypeOwnershipFacts;
            if (!typeOwnershipFactHasMatchingDropGlueFact(module, fact)) return error.InvalidMirTypeOwnershipFacts;
        } else if (dropGlueFactForResourceSymbol(module, fact.typed_type_symbol_id) != null) {
            return error.InvalidMirTypeOwnershipFacts;
        }
        for (module.type_ownership_facts[0..index]) |previous| {
            if (previous.typed_type_symbol_id.eql(fact.typed_type_symbol_id)) return error.InvalidMirTypeOwnershipFacts;
        }
    }
}

pub fn validateOwnershipEventsForLowering(module: Module) error{ InvalidMirOwnershipEvents, OutOfMemory }!void {
    for (module.functions) |function| {
        for (function.ownership_events) |event| {
            if (!ownershipEventValid(module, function, event)) return error.InvalidMirOwnershipEvents;
        }
        if (!try ownershipEventSequenceValid(module.allocator, function)) return error.InvalidMirOwnershipEvents;
    }
}

pub fn appendOwnershipCleanupPlan(
    allocator: std.mem.Allocator,
    module: Module,
    function: Function,
    out: *std.ArrayList(CleanupActionPlanEntry),
) error{ InvalidMirOwnershipEvents, OutOfMemory }!void {
    for (function.ownership_events) |event| {
        if (!ownershipEventValid(module, function, event)) return error.InvalidMirOwnershipEvents;
    }
    if (!try ownershipEventSequenceValid(allocator, function)) return error.InvalidMirOwnershipEvents;

    for (function.ownership_events, 0..) |event, index| {
        switch (event.kind) {
            .auto_drop => {
                const root = simpleOwnershipRootValue(event.place) orelse return error.InvalidMirOwnershipEvents;
                const storage_dead_index = autoDropClosingStorageDeadIndex(function, index, root) orelse return error.InvalidMirOwnershipEvents;
                try out.append(allocator, .{
                    .kind = .auto_drop,
                    .primary_event_index = index,
                    .storage_dead_event_index = storage_dead_index,
                    .place = event.place,
                    .generation = event.generation,
                    .drop_glue_symbol_id = event.drop_glue_symbol_id,
                    .block_id = event.block_id,
                    .source = event.source,
                });
            },
            .explicit_drop => {
                _ = simpleOwnershipRootValue(event.place) orelse return error.InvalidMirOwnershipEvents;
                try out.append(allocator, .{
                    .kind = .explicit_drop,
                    .primary_event_index = index,
                    .place = event.place,
                    .generation = event.generation,
                    .drop_glue_symbol_id = event.drop_glue_symbol_id,
                    .block_id = event.block_id,
                    .source = event.source,
                });
            },
            else => {},
        }
    }
}

pub fn appendOwnershipCleanupCancellationPlan(
    allocator: std.mem.Allocator,
    module: Module,
    function: Function,
    out: *std.ArrayList(CleanupCancellationPlanEntry),
) error{ InvalidMirOwnershipEvents, OutOfMemory }!void {
    for (function.ownership_events) |event| {
        if (!ownershipEventValid(module, function, event)) return error.InvalidMirOwnershipEvents;
    }
    if (!try ownershipEventSequenceValid(allocator, function)) return error.InvalidMirOwnershipEvents;

    for (function.ownership_events, 0..) |event, index| {
        switch (event.kind) {
            .move_out => {
                _ = simpleOwnershipRootValue(event.place) orelse return error.InvalidMirOwnershipEvents;
                const drop_glue_symbol_id = autoDropGlueSymbolForResourceSymbol(module, event.place.root_type_symbol_id) orelse continue;
                try out.append(allocator, .{
                    .kind = .move_out,
                    .event_index = index,
                    .place = event.place,
                    .generation = event.generation,
                    .drop_glue_symbol_id = drop_glue_symbol_id,
                    .block_id = event.block_id,
                    .source = event.source,
                });
            },
            .explicit_drop => {
                _ = simpleOwnershipRootValue(event.place) orelse return error.InvalidMirOwnershipEvents;
                try out.append(allocator, .{
                    .kind = .explicit_drop,
                    .event_index = index,
                    .place = event.place,
                    .generation = event.generation,
                    .drop_glue_symbol_id = event.drop_glue_symbol_id,
                    .block_id = event.block_id,
                    .source = event.source,
                });
            },
            else => {},
        }
    }
}

pub fn buildOwnershipCleanupPlan(
    allocator: std.mem.Allocator,
    module: Module,
    function: Function,
) error{ InvalidMirOwnershipEvents, OutOfMemory }!OwnershipCleanupPlan {
    var actions: std.ArrayList(CleanupActionPlanEntry) = .empty;
    errdefer actions.deinit(allocator);
    var cancellations: std.ArrayList(CleanupCancellationPlanEntry) = .empty;
    errdefer cancellations.deinit(allocator);

    try appendOwnershipCleanupPlan(allocator, module, function, &actions);
    try appendOwnershipCleanupCancellationPlan(allocator, module, function, &cancellations);

    return .{
        .actions = try actions.toOwnedSlice(allocator),
        .cancellations = try cancellations.toOwnedSlice(allocator),
    };
}

pub fn buildOwnershipCleanupEdgeTable(
    allocator: std.mem.Allocator,
    module: Module,
    function: Function,
    plan: OwnershipCleanupPlan,
) error{ InvalidMirOwnershipEvents, OutOfMemory, InvalidSpanReference }!OwnershipCleanupEdgeTable {
    if (!ownershipCleanupPlanValid(module, function, plan)) return error.InvalidMirOwnershipEvents;
    if (plan.actions.len == 0) return .{};

    var action_refs: std.ArrayList(OwnershipCleanupEdgeActionRef) = .empty;
    defer action_refs.deinit(allocator);

    var emission_index: usize = 0;
    while (emission_index < plan.actions.len) : (emission_index += 1) {
        const action_index = plan.actions.len - 1 - emission_index;
        const action = plan.actions[action_index];
        switch (action.kind) {
            .auto_drop => {},
            .explicit_drop => continue,
        }
        try action_refs.append(allocator, ownershipCleanupEdgeActionRef(plan, action_index) orelse return error.InvalidMirOwnershipEvents);
    }
    if (action_refs.items.len == 0) return .{};

    var edge_list: std.ArrayList(OwnershipCleanupEdge) = .empty;
    errdefer {
        for (edge_list.items) |*edge| allocator.free(edge.actions);
        edge_list.deinit(allocator);
    }

    try appendOwnershipCleanupCfgEdge(allocator, &edge_list, .scope_exit, .invalid, null, .{ .line = 0, .column = 0 }, action_refs.items, &plan);
    try appendOwnershipCleanupCfgEdge(allocator, &edge_list, .error_exit, .invalid, null, .{ .line = 0, .column = 0 }, action_refs.items, &plan);

    for (function.blocks) |block| {
        const source = cleanupEdgeSourceForBlock(function, block) orelse return error.InvalidSpanReference;
        switch (block.terminator) {
            .return_ => try appendOwnershipCleanupCfgEdge(allocator, &edge_list, .return_exit, block.id, null, source, action_refs.items, &plan),
            .jump => |target| {
                const target_block: ?BlockId = if (target.isValid() and target.index() < function.blocks.len) function.blocks[target.index()].id else null;
                try appendOwnershipCleanupCfgEdge(allocator, &edge_list, .break_exit, block.id, target_block, source, action_refs.items, &plan);
                try appendOwnershipCleanupCfgEdge(allocator, &edge_list, .continue_exit, block.id, target_block, source, action_refs.items, &plan);
            },
            .fallthrough, .branch, .trap_, .unreachable_, .switch_ => {},
        }
    }

    const edges = try edge_list.toOwnedSlice(allocator);
    var table: OwnershipCleanupEdgeTable = .{ .edges = edges };
    if (!ownershipCleanupEdgeTableValid(module, function, plan, table)) {
        table.deinit(allocator);
        return error.InvalidMirOwnershipEvents;
    }
    return table;
}

fn appendOwnershipCleanupCfgEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(OwnershipCleanupEdge),
    kind: OwnershipCleanupEdgeKind,
    source_block: BlockId,
    target_block: ?BlockId,
    source: SourcePoint,
    actions: []const OwnershipCleanupEdgeActionRef,
    plan: *const OwnershipCleanupPlan,
) error{OutOfMemory}!void {
    var filtered_actions: std.ArrayList(OwnershipCleanupEdgeActionRef) = .empty;
    defer filtered_actions.deinit(allocator);
    for (actions) |action| {
        if (ownershipCleanupActionCancelledOnEdge(plan, action, source_block, source)) continue;
        try filtered_actions.append(allocator, action);
    }
    const edge_actions = try allocator.dupe(OwnershipCleanupEdgeActionRef, filtered_actions.items);
    errdefer allocator.free(edge_actions);
    try edges.append(allocator, .{
        .kind = kind,
        .source_block = source_block,
        .target_block = target_block,
        .source = source,
        .actions = edge_actions,
    });
}

fn ownershipCleanupActionCancelledOnEdge(
    plan: *const OwnershipCleanupPlan,
    action: OwnershipCleanupEdgeActionRef,
    source_block: BlockId,
    source: SourcePoint,
) bool {
    const has_source = !(source.offset == 0 and source.len == 0 and source.line == 0 and source.column == 0);
    for (plan.cancellations) |cancellation| {
        const same_source = has_source and sourcePointMatches(cancellation.source, source);
        const same_block = source_block.isValid() and cancellation.block_id.eql(source_block);
        if (!same_source and !same_block) continue;
        if (cancellation.generation != action.generation) continue;
        if (!cancellation.place.root_value_id.eql(action.root_value_id)) continue;
        if (!cancellation.place.root_type_symbol_id.eql(action.resource_type_symbol_id)) continue;
        if (!cancellation.drop_glue_symbol_id.eql(action.drop_glue_symbol_id)) continue;
        return true;
    }
    return false;
}

pub fn ownershipCleanupEdgeTableValid(
    module: Module,
    function: Function,
    plan: OwnershipCleanupPlan,
    table: OwnershipCleanupEdgeTable,
) bool {
    if (!ownershipCleanupPlanValid(module, function, plan)) return false;
    for (table.edges) |edge| {
        for (edge.actions) |ref| {
            if (!ownershipCleanupEdgeActionRefValid(module, function, plan, ref)) return false;
        }
    }
    return true;
}

fn ownershipCleanupPlanValid(module: Module, function: Function, plan: OwnershipCleanupPlan) bool {
    for (plan.actions, 0..) |entry, index| {
        const ref = ownershipCleanupEdgeActionRef(plan, index) orelse return false;
        if (!ownershipCleanupEdgeActionRefMatchesEntry(module, function, entry, ref)) return false;
    }
    return true;
}

fn ownershipCleanupEdgeActionRef(
    plan: OwnershipCleanupPlan,
    action_index: usize,
) ?OwnershipCleanupEdgeActionRef {
    if (action_index >= plan.actions.len) return null;
    const entry = plan.actions[action_index];
    const root_value_id = simpleOwnershipRootValue(entry.place) orelse return null;
    if (!entry.place.root_type_symbol_id.isValid()) return null;
    if (!entry.drop_glue_symbol_id.isValid()) return null;
    if (!entry.block_id.isValid()) return null;
    return .{
        .cleanup_action_index = action_index,
        .kind = entry.kind,
        .primary_event_index = entry.primary_event_index,
        .storage_dead_event_index = entry.storage_dead_event_index,
        .root_value_id = root_value_id,
        .resource_type_symbol_id = entry.place.root_type_symbol_id,
        .drop_glue_symbol_id = entry.drop_glue_symbol_id,
        .generation = entry.generation,
        .block_id = entry.block_id,
        .source = entry.source,
    };
}

fn ownershipCleanupEdgeActionRefValid(
    module: Module,
    function: Function,
    plan: OwnershipCleanupPlan,
    ref: OwnershipCleanupEdgeActionRef,
) bool {
    if (ref.cleanup_action_index >= plan.actions.len) return false;
    return ownershipCleanupEdgeActionRefMatchesEntry(module, function, plan.actions[ref.cleanup_action_index], ref);
}

fn ownershipCleanupEdgeActionRefMatchesEntry(
    module: Module,
    function: Function,
    entry: CleanupActionPlanEntry,
    ref: OwnershipCleanupEdgeActionRef,
) bool {
    if (ref.primary_event_index != entry.primary_event_index) return false;
    if (ref.storage_dead_event_index != entry.storage_dead_event_index) return false;
    if (ref.kind != entry.kind) return false;
    if (ref.generation != entry.generation) return false;
    if (!ref.block_id.eql(entry.block_id)) return false;
    if (ref.block_id.index() >= function.blocks.len) return false;
    const root_value_id = simpleOwnershipRootValue(entry.place) orelse return false;
    if (!ref.root_value_id.eql(root_value_id)) return false;
    if (!ref.resource_type_symbol_id.eql(entry.place.root_type_symbol_id)) return false;
    if (!ref.drop_glue_symbol_id.eql(entry.drop_glue_symbol_id)) return false;
    if (!ownershipPlaceValid(module, function, entry.place)) return false;
    if (!moduleSymbolIdentityValid(module, ref.resource_type_symbol_id)) return false;
    if (!moduleSymbolIdentityValid(module, ref.drop_glue_symbol_id)) return false;
    if (ref.source.line != entry.source.line or ref.source.column != entry.source.column) return false;
    if (ref.source.offset != entry.source.offset or ref.source.len != entry.source.len) return false;
    return true;
}

pub fn ownershipLocalHasAutoDropResourceEvent(module: Module, function: Function, root_value_id: ValueId) bool {
    if (!root_value_id.isValid()) return false;
    for (function.ownership_events) |event| {
        const event_root = simpleOwnershipRootValue(event.place) orelse continue;
        if (!event_root.eql(root_value_id)) continue;
        if (autoDropGlueSymbolForResourceSymbol(module, event.place.root_type_symbol_id) == null) continue;
        return true;
    }
    return false;
}

pub fn ownershipLocalHasConsumingResourceEvent(function: Function, root_value_id: ValueId, root_type_symbol_id: SymbolId) bool {
    if (!root_value_id.isValid() or !root_type_symbol_id.isValid()) return false;
    for (function.ownership_events) |event| {
        if (event.kind != .move_out and event.kind != .explicit_drop) continue;
        const event_root = simpleOwnershipRootValue(event.place) orelse continue;
        if (!event_root.eql(root_value_id)) continue;
        if (!event.place.root_type_symbol_id.eql(root_type_symbol_id)) continue;
        return true;
    }
    return false;
}

pub fn verifyFunctionOwnershipEvents(module: Module, function: Function, reporter: *diagnostics.Reporter) void {
    for (function.ownership_events) |event| {
        if (ownershipEventValid(module, function, event)) continue;
        reporter.err(
            sourcePointSpan(event.source),
            "E_MIR_OWNERSHIP_EVENT: MIR verifier found malformed ownership event",
            .{},
        );
    }
    // The diagnostic verifier reports, it does not admit. An allocation
    // failure here has no diagnostic to report, so it reports nothing and
    // leaves the fail-closed answer to the lowering admission check.
    const sequence_valid = ownershipEventSequenceValid(module.allocator, function) catch true;
    if (!sequence_valid) {
        reporter.err(
            sourcePointSpan(function.ownership_events[function.ownership_events.len - 1].source),
            "E_MIR_OWNERSHIP_EVENT: MIR verifier found inconsistent ownership event sequence",
            .{},
        );
    }
}

fn ownershipEventValid(module: Module, function: Function, event: OwnershipEvent) bool {
    if (!event.block_id.isValid() or event.block_id.index() >= function.blocks.len) return false;
    if (event.instruction_index) |index| {
        if (index >= function.blocks[event.block_id.index()].instructions.len) return false;
    }
    if (!ownershipPlaceValid(module, function, event.place)) return false;
    return switch (event.kind) {
        .borrow_begin => event.loan_kind != null and event.loan_id != std.math.maxInt(u32) and !event.drop_glue_symbol_id.isValid(),
        .borrow_end => event.loan_kind == null and event.loan_id != std.math.maxInt(u32) and !event.drop_glue_symbol_id.isValid(),
        .explicit_drop => event.loan_kind == null and event.loan_id == std.math.maxInt(u32) and ownershipDropGlueSymbolMatchesPlace(module, event),
        .auto_drop => event.loan_kind == null and event.loan_id == std.math.maxInt(u32) and ownershipDropGlueSymbolMatchesPlace(module, event),
        else => event.loan_kind == null and event.loan_id == std.math.maxInt(u32) and !event.drop_glue_symbol_id.isValid(),
    };
}

fn ownershipPlaceValid(module: Module, function: Function, place: OwnershipPlace) bool {
    const root_value_valid = place.root_value_id.isValid();
    const root_symbol_valid = place.root_symbol_id.isValid();
    if (root_value_valid == root_symbol_valid) return false;
    if (root_value_valid and place.root_value_id.index() >= function.value_identities.len) return false;
    if (root_symbol_valid and !moduleSymbolIdentityValid(module, place.root_symbol_id)) return false;
    if (place.root_type_symbol_id.isValid() and !moduleSymbolIdentityValid(module, place.root_type_symbol_id)) return false;
    if (root_symbol_valid and place.root_type_symbol_id.isValid() and !place.root_type_symbol_id.eql(place.root_symbol_id)) return false;
    if (place.projection_count > mir_model.max_ownership_place_projections) return false;
    for (place.projections[0..place.projection_count]) |projection| {
        switch (projection) {
            .field => |field_id| if (!moduleSymbolIdentityValid(module, field_id)) return false,
            .constant_index, .deref, .wildcard_index => {},
        }
    }
    return true;
}

pub const OwnershipRootState = enum {
    untracked,
    storage_live,
    live,
    consumed,
};

/// The set of ownership states a root may be in at a program point.
///
/// A single state is not enough once the check follows the CFG: at a join the
/// root's state is whatever any predecessor left it in, and the whole point of
/// the check is to tell apart the joins that agree from the ones that do not.
/// `{live}` is "definitely still owned"; `{live, consumed}` is "moved on one
/// path only", which is what makes a second move a double move.
const OwnershipStateSet = struct {
    bits: u4 = 0,

    fn of(state: OwnershipRootState) OwnershipStateSet {
        return .{ .bits = @as(u4, 1) << @intFromEnum(state) };
    }

    fn isEmpty(self: OwnershipStateSet) bool {
        return self.bits == 0;
    }

    fn contains(self: OwnershipStateSet, state: OwnershipRootState) bool {
        return self.bits & of(state).bits != 0;
    }

    fn only(self: OwnershipStateSet, state: OwnershipRootState) bool {
        return self.bits == of(state).bits;
    }

    /// Every state in this set is one of the two named ones.
    fn within(self: OwnershipStateSet, a: OwnershipRootState, b: OwnershipRootState) bool {
        return !self.isEmpty() and self.bits & ~(of(a).bits | of(b).bits) == 0;
    }

    fn unionWith(self: OwnershipStateSet, other: OwnershipStateSet) OwnershipStateSet {
        return .{ .bits = self.bits | other.bits };
    }
};

/// One root's state on entry to, or exit from, a block.
const OwnershipFlow = struct {
    /// False until the dataflow proves control can reach this point.
    reachable: bool = false,
    states: OwnershipStateSet = .{},
    generation: u32 = 0,
    /// Predecessors agreed on the state but not on the generation, so the
    /// generation is not a fact at this point and is not checked against.
    generation_ambiguous: bool = false,

    fn single(state: OwnershipRootState, generation: u32) OwnershipFlow {
        return .{ .reachable = true, .states = OwnershipStateSet.of(state), .generation = generation };
    }

    fn join(self: OwnershipFlow, other: OwnershipFlow) OwnershipFlow {
        if (!other.reachable) return self;
        if (!self.reachable) return other;
        return .{
            .reachable = true,
            .states = self.states.unionWith(other.states),
            .generation = @max(self.generation, other.generation),
            .generation_ambiguous = self.generation_ambiguous or other.generation_ambiguous or
                self.generation != other.generation,
        };
    }

    fn eql(self: OwnershipFlow, other: OwnershipFlow) bool {
        return self.reachable == other.reachable and self.states.bits == other.states.bits and
            self.generation == other.generation and self.generation_ambiguous == other.generation_ambiguous;
    }
};

/// Are this function's ownership events a valid sequence along every path?
///
/// The events are recorded in one list, but they do not execute in list order:
/// each carries the block it belongs to, and the blocks form a CFG. Reading
/// the list linearly asks "what did the previous event leave behind", which is
/// the wrong question at a branch -- it let a move on one arm be seen by the
/// other arm, and rejected `move_diverge.mc`, where each arm moves once and
/// the arms never meet.
///
/// So this walks the CFG instead: per-block entry state, events applied in
/// order within a block, and a join at every merge point. The join is a set
/// union, not a pick: a root that is `live` down one edge and `consumed` down
/// another arrives at the join as both, and every operation that requires
/// ownership rejects it. That is exactly a double move across a join, and it
/// stays rejected -- what stops being rejected is an arm that never reaches
/// the join at all.
fn ownershipEventSequenceValid(allocator: std.mem.Allocator, function: Function) error{OutOfMemory}!bool {
    if (function.blocks.len != 0) {
        const entry = try allocator.alloc(OwnershipFlow, function.blocks.len);
        defer allocator.free(entry);
        var seen: std.ArrayList(ValueId) = .empty;
        defer seen.deinit(allocator);
        for (function.ownership_events) |event| {
            const root = simpleOwnershipRootValue(event.place) orelse continue;
            if (!event.place.root_type_symbol_id.isValid()) continue;
            if (!ownershipRootHasStorageLive(function, root)) continue;
            var already = false;
            for (seen.items) |candidate| {
                if (candidate.eql(root)) already = true;
            }
            if (already) continue;
            try seen.append(allocator, root);
            solveOwnershipRootEntryStates(function, root, entry);
            if (!ownershipRootFlowValid(function, root, entry)) return false;
        }
    }
    if (!typedOwnershipRootsClosed(function)) return false;
    return true;
}

/// Fixpoint over the CFG: `entry[b]` is the join of every predecessor's exit
/// state for `root`. The lattice is a four-element set plus a reachability
/// bit, so it has no ascending chain longer than the block count; the round
/// bound is a guard, not the termination argument.
fn solveOwnershipRootEntryStates(function: Function, root: ValueId, entry: []OwnershipFlow) void {
    for (entry) |*flow| flow.* = .{};
    entry[0] = OwnershipFlow.single(.untracked, 0);
    var rounds: usize = 0;
    while (rounds <= function.blocks.len) : (rounds += 1) {
        var changed = false;
        for (function.blocks, 0..) |block, index| {
            if (!entry[index].reachable) continue;
            const exit = applyOwnershipBlockEvents(function, root, BlockId.fromIndex(index), entry[index]);
            for (block.successors) |successor| {
                if (!successor.isValid() or successor.index() >= entry.len) continue;
                const joined = entry[successor.index()].join(exit);
                if (!joined.eql(entry[successor.index()])) {
                    entry[successor.index()] = joined;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
}

/// The state `root` is left in by the events `block` records, starting from
/// `incoming`. This is the transfer function; it does not validate.
fn applyOwnershipBlockEvents(
    function: Function,
    root: ValueId,
    block: BlockId,
    incoming: OwnershipFlow,
) OwnershipFlow {
    var flow = incoming;
    for (function.ownership_events) |event| {
        if (!ownershipEventTracksRoot(event, root)) continue;
        if (!event.block_id.eql(block)) continue;
        flow = applyOwnershipEvent(flow, event);
    }
    return flow;
}

fn applyOwnershipEvent(flow: OwnershipFlow, event: OwnershipEvent) OwnershipFlow {
    return switch (event.kind) {
        .storage_live => OwnershipFlow.single(.storage_live, event.generation),
        .init, .reinit => OwnershipFlow.single(.live, event.generation),
        .move_out, .forget, .explicit_drop, .auto_drop => OwnershipFlow.single(.consumed, event.generation),
        .storage_dead => OwnershipFlow.single(.untracked, event.generation),
        .borrow_begin, .borrow_end, .set_drop_flag => flow,
    };
}

fn ownershipEventTracksRoot(event: OwnershipEvent, root: ValueId) bool {
    const event_root = simpleOwnershipRootValue(event.place) orelse return false;
    if (!event.place.root_type_symbol_id.isValid()) return false;
    return event_root.eql(root);
}

/// Validate every event for `root`, block by block, from the solved entry
/// states. A block the dataflow never reached holds no executable event, so it
/// has nothing to validate.
fn ownershipRootFlowValid(function: Function, root: ValueId, entry: []const OwnershipFlow) bool {
    for (function.blocks, 0..) |_, index| {
        if (!entry[index].reachable) continue;
        var flow = entry[index];
        for (function.ownership_events, 0..) |event, event_index| {
            if (!ownershipEventTracksRoot(event, root)) continue;
            if (!event.block_id.isValid() or event.block_id.index() != index) continue;
            if (!ownershipEventValidInFlow(function, event, event_index, root, flow)) return false;
            flow = applyOwnershipEvent(flow, event);
        }
    }
    return true;
}

fn ownershipEventValidInFlow(
    function: Function,
    event: OwnershipEvent,
    event_index: usize,
    root: ValueId,
    flow: OwnershipFlow,
) bool {
    const exact_generation = !flow.generation_ambiguous;
    switch (event.kind) {
        .storage_live => {
            // Entering a slot's storage is an error only if the previous
            // generation is still owned -- that would lose it. A loop body
            // whose back edge left the slot consumed is re-entering the same
            // slot, which the linear reading never saw at all.
            if (flow.states.contains(.live)) return false;
            if (event.generation != 0) return false;
        },
        .init => {
            if (!flow.states.only(.storage_live)) return false;
            if (exact_generation and event.generation != flow.generation) return false;
        },
        .reinit => {
            // A slot may be re-initialized whether it was never owned yet or
            // was consumed; a loop back edge legitimately merges both.
            if (!flow.states.within(.storage_live, .consumed)) return false;
            if (exact_generation and flow.states.only(.storage_live) and event.generation != flow.generation) return false;
            if (exact_generation and flow.states.only(.consumed) and event.generation != flow.generation + 1) return false;
        },
        .move_out, .forget, .explicit_drop, .auto_drop => {
            if (!flow.states.only(.live)) return false;
            if (exact_generation and event.generation != flow.generation) return false;
            if (event.kind == .auto_drop and autoDropClosingStorageDeadIndex(function, event_index, root) == null) return false;
        },
        .borrow_begin, .set_drop_flag => {
            if (!flow.states.only(.live)) return false;
            if (exact_generation and event.generation != flow.generation) return false;
        },
        .borrow_end => {},
        .storage_dead => {
            if (flow.states.contains(.live)) return false;
            if (!flow.states.only(.untracked) and exact_generation and event.generation != flow.generation) return false;
        },
    }
    return true;
}

fn autoDropClosingStorageDeadIndex(function: Function, event_index: usize, root: ValueId) ?usize {
    for (function.ownership_events[event_index + 1 ..], event_index + 1..) |event, index| {
        const event_root = simpleOwnershipRootValue(event.place) orelse continue;
        if (!event_root.eql(root)) continue;
        if (event.kind != .storage_dead) return null;
        return index;
    }
    return null;
}

fn typedOwnershipRootsClosed(function: Function) bool {
    for (function.ownership_events) |event| {
        if (!event.place.root_type_symbol_id.isValid()) continue;
        const root = simpleOwnershipRootValue(event.place) orelse continue;
        if (ownershipRootStateBefore(function, function.ownership_events.len, root) == .live) return false;
    }
    return true;
}

fn ownershipRootStateBefore(function: Function, event_index: usize, root: ValueId) OwnershipRootState {
    var state: OwnershipRootState = .untracked;
    const target_block: ?BlockId = if (event_index < function.ownership_events.len) function.ownership_events[event_index].block_id else null;
    for (function.ownership_events[0..event_index]) |event| {
        const event_root = simpleOwnershipRootValue(event.place) orelse continue;
        if (!event.place.root_type_symbol_id.isValid()) continue;
        if (!event_root.eql(root)) continue;
        if (target_block) |block_id| {
            if (!ownershipEventCanReachBlock(function, event, block_id)) continue;
        }
        switch (event.kind) {
            .storage_live => state = .storage_live,
            .init, .reinit => state = .live,
            .move_out, .forget, .explicit_drop, .auto_drop => state = .consumed,
            .storage_dead => state = .untracked,
            .borrow_begin, .borrow_end, .set_drop_flag => {},
        }
    }
    return state;
}

fn ownershipRootGenerationBefore(function: Function, event_index: usize, root: ValueId) u32 {
    var generation: u32 = 0;
    const target_block: ?BlockId = if (event_index < function.ownership_events.len) function.ownership_events[event_index].block_id else null;
    for (function.ownership_events[0..event_index]) |event| {
        const event_root = simpleOwnershipRootValue(event.place) orelse continue;
        if (!event.place.root_type_symbol_id.isValid()) continue;
        if (!event_root.eql(root)) continue;
        if (target_block) |block_id| {
            if (!ownershipEventCanReachBlock(function, event, block_id)) continue;
        }
        switch (event.kind) {
            .storage_live, .init, .reinit, .move_out, .forget, .explicit_drop, .auto_drop, .storage_dead, .set_drop_flag => generation = event.generation,
            .borrow_begin, .borrow_end => {},
        }
    }
    return generation;
}

fn ownershipEventCanReachBlock(function: Function, event: OwnershipEvent, target: BlockId) bool {
    if (!event.block_id.isValid() or !target.isValid()) return false;
    if (event.block_id.index() >= function.blocks.len or target.index() >= function.blocks.len) return false;
    return blockCanReach(function, event.block_id.index(), target.index(), function.blocks.len + 1);
}

fn blockCanReach(function: Function, from: usize, target: usize, remaining: usize) bool {
    if (from == target) return true;
    if (remaining == 0 or from >= function.blocks.len) return false;
    for (function.blocks[from].successors) |successor| {
        if (!successor.isValid() or successor.index() >= function.blocks.len) continue;
        if (blockCanReach(function, successor.index(), target, remaining - 1)) return true;
    }
    return false;
}

fn ownershipRootHasStorageLive(function: Function, root: ValueId) bool {
    for (function.ownership_events) |event| {
        const event_root = simpleOwnershipRootValue(event.place) orelse continue;
        if (event.kind == .storage_live and event_root.eql(root)) return true;
    }
    return false;
}

pub fn simpleOwnershipRootValue(place: OwnershipPlace) ?ValueId {
    if (!place.root_value_id.isValid() or place.root_symbol_id.isValid() or place.projection_count != 0) return null;
    return place.root_value_id;
}

fn ownershipDropGlueSymbolValid(module: Module, symbol_id: SymbolId) bool {
    if (!moduleSymbolIdentityValid(module, symbol_id)) return false;
    for (module.drop_glue_facts) |fact| {
        if (fact.typed_release_symbol_id.eql(symbol_id)) return true;
    }
    return false;
}

fn ownershipDropGlueSymbolMatchesPlace(module: Module, event: OwnershipEvent) bool {
    if (!ownershipDropGlueSymbolValid(module, event.drop_glue_symbol_id)) return false;
    const fact = dropGlueFactForReleaseSymbol(module, event.drop_glue_symbol_id) orelse return false;
    if (event.place.root_symbol_id.isValid() and !fact.typed_resource_symbol_id.eql(event.place.root_symbol_id)) return false;
    if (event.place.root_type_symbol_id.isValid() and !fact.typed_resource_symbol_id.eql(event.place.root_type_symbol_id)) return false;
    return true;
}

fn dropGlueFactForReleaseSymbol(module: Module, symbol_id: SymbolId) ?DropGlueFact {
    for (module.drop_glue_facts) |fact| {
        if (fact.typed_release_symbol_id.eql(symbol_id)) return fact;
    }
    return null;
}

fn autoDropGlueSymbolForResourceSymbol(module: Module, resource_symbol_id: SymbolId) ?SymbolId {
    for (module.type_ownership_facts) |fact| {
        if (!fact.typed_type_symbol_id.eql(resource_symbol_id)) continue;
        if (fact.kind != .affine or !fact.drop_glue_symbol_id.isValid()) return null;
        if (dropGlueFactForReleaseSymbol(module, fact.drop_glue_symbol_id) == null) return null;
        return fact.drop_glue_symbol_id;
    }
    return null;
}

fn dropGlueFactForResourceSymbol(module: Module, resource_symbol_id: SymbolId) ?DropGlueFact {
    for (module.drop_glue_facts) |fact| {
        if (fact.typed_resource_symbol_id.eql(resource_symbol_id)) return fact;
    }
    return null;
}

fn dropGlueFactHasMatchingTypeOwnershipFact(module: Module, fact: DropGlueFact) bool {
    for (module.type_ownership_facts) |ownership_fact| {
        if (!ownership_fact.typed_type_symbol_id.eql(fact.typed_resource_symbol_id)) continue;
        return ownership_fact.kind == .affine and ownership_fact.drop_glue_symbol_id.eql(fact.typed_release_symbol_id);
    }
    return false;
}

fn typeOwnershipFactHasMatchingDropGlueFact(module: Module, fact: TypeOwnershipFact) bool {
    const drop_glue_fact = dropGlueFactForResourceSymbol(module, fact.typed_type_symbol_id) orelse return false;
    return drop_glue_fact.typed_release_symbol_id.eql(fact.drop_glue_symbol_id);
}

fn typeOwnershipSymbolIdentityValid(module: Module, fact: TypeOwnershipFact) bool {
    return moduleSymbolIdentityValid(module, fact.typed_type_symbol_id);
}

pub fn moduleSymbolIdentityValid(module: Module, symbol_id: SymbolId) bool {
    return symbol_id.isValid() and symbol_id.index() < module.symbol_identities.len;
}

fn dropGlueResourceSymbolIdentityValid(module: Module, fact: DropGlueFact) bool {
    return moduleSymbolIdentityValid(module, fact.typed_resource_symbol_id);
}

fn dropGlueReleaseSymbolIdentityValid(module: Module, fact: DropGlueFact) bool {
    return moduleSymbolIdentityValid(module, fact.typed_release_symbol_id);
}

fn moduleHasConcreteFunction(module: Module, symbol_id: SymbolId) bool {
    for (module.functions) |function| {
        if (!function.typed_symbol_id.eql(symbol_id)) continue;
        return !function.is_extern;
    }
    return false;
}

pub fn moduleSymbolSpelling(module: Module, symbol_id: SymbolId) ?[]const u8 {
    if (!moduleSymbolIdentityValid(module, symbol_id)) return null;
    return module.symbol_identities[symbol_id.index()].spelling;
}
