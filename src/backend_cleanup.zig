const std = @import("std");

const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");

/// Transitional backend cleanup stack entry.
///
/// Ordinary `defer` expressions are still emitted from backend-local lexical
/// stacks while cleanup edges migrate into MIR. Direct-call cleanup shapes carry
/// a typed MIR-admitted payload, and deferred blocks are kept structured. Other
/// expression cleanups must be admitted as typed direct-call/call-target payloads
/// before either backend will lower them.
/// Auto-drop payloads remain produced by MIR ownership authority; this module
/// only owns the temporary stack mechanics shared by C and LLVM.
pub const OrdinaryDeferCallCleanup = struct {
    defer_ref: mir.DeferCleanupRef,
    fn_name: []const u8,
    span: ast.Span,
    callee_span: ast.Span,
    args: []const ast.Expr,
};

pub const CallTargetDeferCleanup = struct {
    defer_ref: mir.DeferCleanupRef,
    kind: mir.CallTargetKind,
    span: ast.Span,
    callee: ast.Expr,
    callee_span: ast.Span,
    type_args: []const ast.TypeExpr,
    args: []const ast.Expr,
};

pub const DeferBlockCleanup = struct {
    defer_ref: mir.DeferCleanupRef,
    block: ast.Block,
};

pub const DeferredCleanup = union(enum) {
    block: DeferBlockCleanup,
    direct_call: OrdinaryDeferCallCleanup,
    call_target: CallTargetDeferCleanup,
    auto_drop: mir_ownership_authority.OwnershipCleanupActionRef,
    explicit_drop: mir_ownership_authority.OwnershipCleanupActionRef,
};

pub const AutoDropStackDecision = enum {
    applied,
    ignored,
    rejected,
};

pub const CleanupEdgeKind = enum {
    scope_exit,
    return_exit,
    break_exit,
    continue_exit,
    error_exit,
};

pub const CleanupRef = union(enum) {
    defer_ref: mir.DeferCleanupRef,
    ownership_action: mir_ownership_authority.OwnershipCleanupActionRef,
};

pub const CleanupEdge = struct {
    kind: CleanupEdgeKind,
    source_block: mir.BlockId = .invalid,
    target_block: ?mir.BlockId = null,
    source: mir.SourcePoint = .{ .line = 0, .column = 0 },
    start: usize = 0,
    cleanups: []DeferredCleanup = &.{},
    refs: []CleanupRef = &.{},
};

pub const CleanupEdgeTable = struct {
    edges: []CleanupEdge = &.{},

    pub fn deinit(self: *CleanupEdgeTable, allocator: std.mem.Allocator) void {
        for (self.edges) |edge| {
            allocator.free(edge.cleanups);
            allocator.free(edge.refs);
        }
        allocator.free(self.edges);
        self.edges = &.{};
    }
};

pub fn cleanupEdgeTableValid(
    table: CleanupEdgeTable,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
) bool {
    for (table.edges) |edge| {
        if (edge.cleanups.len != edge.refs.len) return false;
        if (!cleanupEdgeValid(edge, module, function, cleanup_plan)) return false;
        if (!cleanupEdgeOwnershipRefsAdmittedByMir(edge, ownership_edges)) return false;
    }
    return true;
}

pub const CleanupEdgePlan = struct {
    kind: CleanupEdgeKind,
    start: usize,
    cleanups: []DeferredCleanup,

    pub fn deinit(self: *CleanupEdgePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.cleanups);
        self.cleanups = &.{};
    }
};

pub const DeferCleanupStackSnapshot = struct {
    items: []DeferredCleanup,

    pub fn deinit(self: *DeferCleanupStackSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub fn captureDeferCleanupStack(
    allocator: std.mem.Allocator,
    stack: []const DeferredCleanup,
) !DeferCleanupStackSnapshot {
    return .{ .items = try allocator.dupe(DeferredCleanup, stack) };
}

pub fn restoreDeferCleanupStack(
    stack: *std.ArrayList(DeferredCleanup),
    snapshot: DeferCleanupStackSnapshot,
) void {
    stack.items.len = snapshot.items.len;
    @memcpy(stack.items[0..snapshot.items.len], snapshot.items);
}

pub fn restoreDeferCleanupStackLength(stack: *std.ArrayList(DeferredCleanup), len: usize) void {
    std.debug.assert(len <= stack.capacity);
    stack.items.len = len;
}

pub fn deferCleanupRef(cleanup: DeferredCleanup) ?mir.DeferCleanupRef {
    return switch (cleanup) {
        .block => |entry| entry.defer_ref,
        .direct_call => |entry| entry.defer_ref,
        .call_target => |entry| entry.defer_ref,
        .auto_drop, .explicit_drop => null,
    };
}

pub fn registerAutoDropLocalCleanup(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
    stack: *std.ArrayList(DeferredCleanup),
    local_name: []const u8,
    type_name: []const u8,
    local_span: ast.Span,
) error{OutOfMemory}!AutoDropStackDecision {
    if (!mir_ownership_authority.autoDropEligibleTypeName(module, type_name)) return .ignored;
    const cleanup = autoDropLocalCleanupFromMirEdge(module, function, cleanup_plan, ownership_edges, local_name, type_name, local_span) orelse {
        const ownership = typeOwnershipFactForTypeName(module, type_name) orelse return .rejected;
        const root_value_id = valueIdForLocal(function, local_name) orelse return .rejected;
        if (mir.ownershipLocalHasConsumingResourceEvent(function.*, root_value_id, ownership.typed_type_symbol_id)) return .ignored;
        return .rejected;
    };
    try stack.append(allocator, .{ .auto_drop = mir_ownership_authority.ownershipCleanupActionRef(cleanup) });
    return .applied;
}

pub fn cancelAutoDropForMove(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    stack: *std.ArrayList(DeferredCleanup),
    expr: ast.Expr,
    move_span: ast.Span,
) error{OutOfMemory}!AutoDropStackDecision {
    return cancelAutoDropWithDecision(stack, try mir_ownership_authority.moveAutoDropCancellationDecision(allocator, module, function, cleanup_plan, expr, move_span));
}

pub fn cancelAutoDropForExplicitDrop(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    stack: *std.ArrayList(DeferredCleanup),
    expr: ast.Expr,
) error{OutOfMemory}!AutoDropStackDecision {
    return cancelAutoDropWithDecision(stack, try mir_ownership_authority.explicitDropCancellationDecision(allocator, module, function, cleanup_plan, expr));
}

pub fn registerDeferredExplicitDropCleanup(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    stack: *std.ArrayList(DeferredCleanup),
    expr: ast.Expr,
) error{OutOfMemory}!AutoDropStackDecision {
    const cleanup = switch (try mir_ownership_authority.deferredExplicitDropCleanupDecision(allocator, module, function, cleanup_plan, expr)) {
        .ignore => return .ignored,
        .emit_explicit_drop_cleanup => |entry| entry,
        .reject => return .rejected,
    };
    try stack.append(allocator, .{ .explicit_drop = mir_ownership_authority.ownershipCleanupActionRef(cleanup) });
    return .applied;
}

pub fn registerOrdinaryDirectDeferCleanup(
    allocator: std.mem.Allocator,
    function: *const mir.Function,
    stack: *std.ArrayList(DeferredCleanup),
    cleanup: OrdinaryDeferCallCleanup,
) error{OutOfMemory}!AutoDropStackDecision {
    return appendValidatedCleanup(allocator, function, stack, .{ .direct_call = cleanup });
}

pub fn registerOrdinaryCallTargetDeferCleanup(
    allocator: std.mem.Allocator,
    function: *const mir.Function,
    stack: *std.ArrayList(DeferredCleanup),
    cleanup: CallTargetDeferCleanup,
) error{OutOfMemory}!AutoDropStackDecision {
    return appendValidatedCleanup(allocator, function, stack, .{ .call_target = cleanup });
}

pub fn registerOrdinaryBlockDeferCleanup(
    allocator: std.mem.Allocator,
    function: *const mir.Function,
    stack: *std.ArrayList(DeferredCleanup),
    defer_ref: mir.DeferCleanupRef,
    block: ast.Block,
) error{OutOfMemory}!AutoDropStackDecision {
    return appendValidatedCleanup(allocator, function, stack, .{ .block = .{ .defer_ref = defer_ref, .block = block } });
}

fn cancelAutoDropWithDecision(
    stack: *std.ArrayList(DeferredCleanup),
    decision: mir_ownership_authority.AutoDropCancellationDecision,
) AutoDropStackDecision {
    return switch (decision) {
        .ignore => .ignored,
        .remove_auto_drop => |ref| if (removeAutoDropCleanup(stack, ref)) .applied else .rejected,
        .reject => .rejected,
    };
}

fn appendValidatedCleanup(
    allocator: std.mem.Allocator,
    function: *const mir.Function,
    stack: *std.ArrayList(DeferredCleanup),
    cleanup: DeferredCleanup,
) error{OutOfMemory}!AutoDropStackDecision {
    const old_len = stack.items.len;
    try stack.append(allocator, cleanup);
    if (deferCleanupStackRefsValid(function.*, stack.items)) return .applied;
    restoreDeferCleanupStackLength(stack, old_len);
    return .rejected;
}

pub fn deferCleanupStackRefsValid(function: mir.Function, stack: []const DeferredCleanup) bool {
    for (stack, 0..) |cleanup, index| {
        const ref = deferCleanupRef(cleanup) orelse continue;
        if (!mir.deferCleanupRefValid(function, ref)) return false;
        var previous_index: usize = 0;
        while (previous_index < index) : (previous_index += 1) {
            const previous = deferCleanupRef(stack[previous_index]) orelse continue;
            if (sameDeferCleanupRef(previous, ref)) return false;
            if (deferCleanupRefAfter(function, previous, ref)) return false;
        }
    }
    return true;
}

pub fn deferCleanupEmissionRangeValid(function: mir.Function, stack: []const DeferredCleanup, start: usize) bool {
    if (start > stack.len) return false;
    if (!deferCleanupStackRefsValid(function, stack)) return false;
    for (stack[start..]) |cleanup| {
        const ref = deferCleanupRef(cleanup) orelse continue;
        if (!mir.deferCleanupRefValid(function, ref)) return false;
    }
    return true;
}

pub fn deferCleanupEmissionCount(stack: []const DeferredCleanup, start: usize) ?usize {
    if (start > stack.len) return null;
    return stack.len - start;
}

pub fn deferCleanupAtEmissionIndex(
    function: mir.Function,
    stack: []const DeferredCleanup,
    start: usize,
    emission_index: usize,
) ?DeferredCleanup {
    const count = deferCleanupEmissionCount(stack, start) orelse return null;
    if (emission_index >= count) return null;
    if (!deferCleanupEmissionRangeValid(function, stack, start)) return null;
    return stack[stack.len - 1 - emission_index];
}

pub fn buildTransitionalCleanupEdgeTable(
    allocator: std.mem.Allocator,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
    stack: []const DeferredCleanup,
    start: usize,
    kind: CleanupEdgeKind,
) !?CleanupEdgeTable {
    const count = deferCleanupEmissionCount(stack, start) orelse return null;
    if (!deferCleanupEmissionRangeValid(function, stack, start)) return null;

    const edges = try allocator.alloc(CleanupEdge, 1);
    errdefer allocator.free(edges);
    var cleanups = try allocator.alloc(DeferredCleanup, count);
    errdefer allocator.free(cleanups);
    var refs = try allocator.alloc(CleanupRef, count);
    errdefer allocator.free(refs);

    var emission_index: usize = 0;
    while (emission_index < count) : (emission_index += 1) {
        const cleanup = deferCleanupAtEmissionIndex(function, stack, start, emission_index) orelse return null;
        cleanups[emission_index] = cleanup;
        refs[emission_index] = cleanupRef(cleanup);
    }

    edges[0] = .{
        .kind = kind,
        .start = start,
        .cleanups = cleanups,
        .refs = refs,
    };
    var table: CleanupEdgeTable = .{ .edges = edges };
    if (!cleanupEdgeTableValid(table, module, function, cleanup_plan, ownership_edges)) {
        table.deinit(allocator);
        return null;
    }
    return table;
}

pub fn buildCleanupEdgePlan(
    allocator: std.mem.Allocator,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
    stack: []const DeferredCleanup,
    start: usize,
    kind: CleanupEdgeKind,
) !?CleanupEdgePlan {
    var table = (try buildTransitionalCleanupEdgeTable(allocator, module, function, cleanup_plan, ownership_edges, stack, start, kind)) orelse return null;
    defer table.deinit(allocator);
    return try cleanupEdgePlanFromTable(allocator, table, kind, start);
}

pub fn cleanupEdgePlanFromTable(
    allocator: std.mem.Allocator,
    table: CleanupEdgeTable,
    kind: CleanupEdgeKind,
    start: usize,
) !?CleanupEdgePlan {
    const edge = cleanupEdgeFor(table, kind, start) orelse return null;
    const cleanups = try allocator.dupe(DeferredCleanup, edge.cleanups);
    return .{
        .kind = edge.kind,
        .start = edge.start,
        .cleanups = cleanups,
    };
}

pub fn cleanupEdgeFor(table: CleanupEdgeTable, kind: CleanupEdgeKind, start: usize) ?CleanupEdge {
    for (table.edges) |edge| {
        if (edge.kind != kind) continue;
        if (edge.start != start) continue;
        return edge;
    }
    return null;
}

pub fn cleanupRef(cleanup: DeferredCleanup) CleanupRef {
    return switch (cleanup) {
        .block => |entry| .{ .defer_ref = entry.defer_ref },
        .direct_call => |entry| .{ .defer_ref = entry.defer_ref },
        .call_target => |entry| .{ .defer_ref = entry.defer_ref },
        .auto_drop => |entry| .{ .ownership_action = entry },
        .explicit_drop => |entry| .{ .ownership_action = entry },
    };
}

fn cleanupEdgeValid(
    edge: CleanupEdge,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
) bool {
    for (edge.cleanups, edge.refs) |cleanup, ref| {
        if (!cleanupRefMatchesCleanup(ref, cleanup)) return false;
        if (!cleanupValidForEdge(cleanup, module, function, cleanup_plan)) return false;
    }
    return true;
}

fn cleanupEdgeOwnershipRefsAdmittedByMir(
    edge: CleanupEdge,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
) bool {
    var saw_ownership_ref = false;
    for (edge.refs) |ref| {
        switch (ref) {
            .defer_ref => {},
            .ownership_action => |action_ref| {
                saw_ownership_ref = true;
                const table = ownership_edges orelse return false;
                if (!mirOwnershipEdgeTableContainsActionRef(table.*, action_ref)) return false;
            },
        }
    }
    return !saw_ownership_ref or ownership_edges != null;
}

fn mirOwnershipEdgeTableContainsActionRef(
    table: mir.OwnershipCleanupEdgeTable,
    ref: mir_ownership_authority.OwnershipCleanupActionRef,
) bool {
    for (table.edges) |edge| {
        for (edge.actions) |action| {
            if (action.cleanup_action_index != ref.cleanup_action_index) continue;
            if (!action.root_value_id.eql(ref.root_value_id)) continue;
            if (!action.resource_type_symbol_id.eql(ref.resource_type_symbol_id)) continue;
            if (!action.drop_glue_symbol_id.eql(ref.drop_glue_symbol_id)) continue;
            return true;
        }
    }
    return false;
}

fn autoDropLocalCleanupFromMirEdge(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
    local_name: []const u8,
    type_name: []const u8,
    local_span: ast.Span,
) ?mir_ownership_authority.AutoDropLocalCleanup {
    const plan = cleanup_plan orelse return null;
    const edges = ownership_edges orelse return null;
    const ownership = typeOwnershipFactForTypeName(module, type_name) orelse return null;
    if (ownership.kind != .affine or !ownership.drop_glue_symbol_id.isValid()) return null;
    const root_value_id = valueIdForLocal(function, local_name) orelse return null;

    for (edges.edges) |edge| {
        for (edge.actions) |action| {
            if (action.kind != .auto_drop) continue;
            if (!action.root_value_id.eql(root_value_id)) continue;
            if (!action.resource_type_symbol_id.eql(ownership.typed_type_symbol_id)) continue;
            if (!action.drop_glue_symbol_id.eql(ownership.drop_glue_symbol_id)) continue;
            const ref: mir_ownership_authority.OwnershipCleanupActionRef = .{
                .local_name = local_name,
                .span = local_span,
                .cleanup_action_index = action.cleanup_action_index,
                .root_value_id = action.root_value_id,
                .resource_type_symbol_id = action.resource_type_symbol_id,
                .drop_glue_symbol_id = action.drop_glue_symbol_id,
            };
            return mir_ownership_authority.autoDropLocalCleanupFromActionRef(module, function, plan, ref);
        }
    }
    return null;
}

fn typeOwnershipFactForTypeName(module: *const mir.Module, type_name: []const u8) ?mir.TypeOwnershipFact {
    for (module.type_ownership_facts) |fact| {
        if (std.mem.eql(u8, fact.type_name, type_name)) return fact;
    }
    return null;
}

fn valueIdForLocal(function: *const mir.Function, local_name: []const u8) ?mir.ValueId {
    for (function.value_identities) |identity| {
        if (!std.mem.eql(u8, identity.spelling, local_name)) continue;
        if (!identity.id.isValid()) return null;
        return identity.id;
    }
    return null;
}

fn cleanupRefMatchesCleanup(ref: CleanupRef, cleanup: DeferredCleanup) bool {
    const expected = cleanupRef(cleanup);
    return switch (expected) {
        .defer_ref => |expected_ref| switch (ref) {
            .defer_ref => |actual_ref| sameDeferCleanupRef(actual_ref, expected_ref),
            .ownership_action => false,
        },
        .ownership_action => |expected_ref| switch (ref) {
            .defer_ref => false,
            .ownership_action => |actual_ref| ownershipCleanupActionRefsEqual(actual_ref, expected_ref),
        },
    };
}

fn cleanupValidForEdge(
    cleanup: DeferredCleanup,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
) bool {
    return switch (cleanup) {
        .block => |entry| mir.deferCleanupRefValid(function, entry.defer_ref),
        .direct_call => |entry| mir.deferCleanupRefValid(function, entry.defer_ref),
        .call_target => |entry| mir.deferCleanupRefValid(function, entry.defer_ref),
        .auto_drop => |ref| {
            const concrete_module = module orelse return false;
            const concrete_plan = cleanup_plan orelse return false;
            return mir_ownership_authority.autoDropLocalCleanupFromActionRef(concrete_module, &function, concrete_plan, ref) != null;
        },
        .explicit_drop => |ref| {
            const concrete_module = module orelse return false;
            const concrete_plan = cleanup_plan orelse return false;
            return mir_ownership_authority.explicitDropLocalCleanupFromActionRef(concrete_module, &function, concrete_plan, ref) != null;
        },
    };
}

fn ownershipCleanupActionRefsEqual(
    a: mir_ownership_authority.OwnershipCleanupActionRef,
    b: mir_ownership_authority.OwnershipCleanupActionRef,
) bool {
    if (a.cleanup_action_index != b.cleanup_action_index) return false;
    if (!a.root_value_id.eql(b.root_value_id)) return false;
    if (!a.resource_type_symbol_id.eql(b.resource_type_symbol_id)) return false;
    if (!a.drop_glue_symbol_id.eql(b.drop_glue_symbol_id)) return false;
    return std.mem.eql(u8, a.local_name, b.local_name);
}

fn sameDeferCleanupRef(a: mir.DeferCleanupRef, b: mir.DeferCleanupRef) bool {
    return a.block_id.eql(b.block_id) and a.instruction_index == b.instruction_index;
}

fn deferCleanupRefAfter(function: mir.Function, a: mir.DeferCleanupRef, b: mir.DeferCleanupRef) bool {
    const a_offset = deferCleanupSourceOrder(function, a) orelse return true;
    const b_offset = deferCleanupSourceOrder(function, b) orelse return true;
    return a_offset > b_offset;
}

fn deferCleanupSourceOrder(function: mir.Function, ref: mir.DeferCleanupRef) ?usize {
    if (!mir.deferCleanupRefValid(function, ref)) return null;
    const instruction = function.blocks[ref.block_id.index()].instructions[ref.instruction_index];
    if (instruction.source_offset != 0) return instruction.source_offset;
    return instruction.line * 1_000_000 + instruction.column;
}

/// Remove the most recent auto-drop cleanup for a MIR ownership action from a
/// transitional backend cleanup stack. Returning `false` is a backend invariant
/// failure: MIR identified a live cleanup obligation, but the backend-local stack
/// no longer contains it. Callers must fail closed instead of continuing with a
/// silently divergent cleanup model.
pub fn removeAutoDropCleanup(stack: *std.ArrayList(DeferredCleanup), ref: mir_ownership_authority.OwnershipCleanupRemovalRef) bool {
    var index = stack.items.len;
    while (index > 0) {
        index -= 1;
        switch (stack.items[index]) {
            .auto_drop => |cleanup| {
                if (!autoDropCleanupMatchesRef(cleanup, ref)) continue;
                _ = stack.orderedRemove(index);
                return true;
            },
            .block, .direct_call, .call_target => continue,
            .explicit_drop => continue,
        }
    }
    return false;
}

fn autoDropCleanupMatchesRef(
    cleanup: mir_ownership_authority.OwnershipCleanupActionRef,
    ref: mir_ownership_authority.OwnershipCleanupRemovalRef,
) bool {
    if (cleanup.cleanup_action_index != ref.cleanup_action_index) return false;
    if (!cleanup.root_value_id.isValid() or !ref.root_value_id.isValid()) return false;
    if (!cleanup.root_value_id.eql(ref.root_value_id)) return false;
    if (!cleanup.resource_type_symbol_id.eql(ref.resource_type_symbol_id)) return false;
    if (!cleanup.drop_glue_symbol_id.eql(ref.drop_glue_symbol_id)) return false;
    return true;
}

test "auto-drop cleanup stack removal uses typed local identity" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    var stack: std.ArrayList(DeferredCleanup) = .empty;
    defer stack.deinit(std.testing.allocator);

    const root_old = mir.ValueId.fromIndex(1);
    const root_shadow = mir.ValueId.fromIndex(2);
    const resource_type = mir.SymbolId.fromIndex(3);
    const drop_glue = mir.SymbolId.fromIndex(4);

    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .local_name = "g", .span = span, .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });
    try stack.append(std.testing.allocator, .{ .auto_drop = .{ .local_name = "g", .span = span, .cleanup_action_index = 1, .root_value_id = root_shadow, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });

    try std.testing.expect(removeAutoDropCleanup(&stack, .{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
    try std.testing.expectEqual(@as(usize, 1), stack.items.len);
    switch (stack.items[0]) {
        .auto_drop => |cleanup| try std.testing.expect(cleanup.root_value_id.eql(root_shadow)),
        .block, .direct_call, .call_target, .explicit_drop => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!removeAutoDropCleanup(&stack, .{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
    try std.testing.expect(!removeAutoDropCleanup(&stack, .{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_shadow, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
}

test "defer cleanup stack refs must be valid ordered and unique" {
    const span = ast.Span{ .offset = 10, .len = 1, .line = 1, .column = 10 };
    const later_span = ast.Span{ .offset = 20, .len = 1, .line = 1, .column = 20 };
    var instructions = [_]mir.Instruction{
        .{ .kind = .defer_cleanup, .detail = "cleanup", .result_ty = .void, .line = span.line, .column = span.column, .source_offset = span.offset, .source_len = span.len },
        .{ .kind = .defer_cleanup, .detail = "cleanup", .result_ty = .void, .line = later_span.line, .column = later_span.column, .source_offset = later_span.offset, .source_len = later_span.len },
    };
    var blocks = [_]mir.Block{
        .{
            .id = 0,
            .typed_id = mir.BlockId.fromIndex(0),
            .kind = "entry",
            .instructions = instructions[0..],
            .successors = &.{},
            .terminator = .fallthrough,
        },
    };
    const function: mir.Function = .{
        .name = "f",
        .return_ty = .void,
        .no_lang_trap = false,
        .irq_context = false,
        .blocks = blocks[0..],
        .trap_edges = &.{},
        .contract_regions = &.{},
        .range_facts = &.{},
        .pointer_provenance_facts = &.{},
        .representation_facts = &.{},
        .elided_bounds = &.{},
    };
    const first: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 0, .source = mir.sourcePointFromSpan(span) };
    const second: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 1, .source = mir.sourcePointFromSpan(later_span) };
    const block: ast.Block = .{ .span = span, .items = &.{} };

    try std.testing.expect(deferCleanupStackRefsValid(function, &.{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = second, .block = block } },
    }));
    try std.testing.expect(!deferCleanupStackRefsValid(function, &.{
        .{ .block = .{ .defer_ref = second, .block = block } },
        .{ .block = .{ .defer_ref = first, .block = block } },
    }));
    try std.testing.expect(!deferCleanupStackRefsValid(function, &.{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = first, .block = block } },
    }));

    const stack = [_]DeferredCleanup{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = second, .block = block } },
    };
    try std.testing.expectEqual(@as(?usize, 2), deferCleanupEmissionCount(stack[0..], 0));
    const first_emit = deferCleanupAtEmissionIndex(function, stack[0..], 0, 0) orelse return error.TestUnexpectedResult;
    const second_emit = deferCleanupAtEmissionIndex(function, stack[0..], 0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect((deferCleanupRef(first_emit) orelse return error.TestUnexpectedResult).instruction_index == 1);
    try std.testing.expect((deferCleanupRef(second_emit) orelse return error.TestUnexpectedResult).instruction_index == 0);
    try std.testing.expect(deferCleanupAtEmissionIndex(function, stack[0..], 0, 2) == null);

    var plan = (try buildCleanupEdgePlan(std.testing.allocator, null, function, null, null, stack[0..], 0, .return_exit)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(CleanupEdgeKind.return_exit, plan.kind);
    try std.testing.expectEqual(@as(usize, 0), plan.start);
    try std.testing.expectEqual(@as(usize, 2), plan.cleanups.len);
    try std.testing.expect((deferCleanupRef(plan.cleanups[0]) orelse return error.TestUnexpectedResult).instruction_index == 1);
    try std.testing.expect((deferCleanupRef(plan.cleanups[1]) orelse return error.TestUnexpectedResult).instruction_index == 0);

    var table = (try buildTransitionalCleanupEdgeTable(std.testing.allocator, null, function, null, null, stack[0..], 0, .return_exit)) orelse return error.TestUnexpectedResult;
    defer table.deinit(std.testing.allocator);
    const edge = cleanupEdgeFor(table, .return_exit, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CleanupEdgeKind.return_exit, edge.kind);
    try std.testing.expectEqual(@as(usize, 2), edge.cleanups.len);
    try std.testing.expectEqual(@as(usize, 2), edge.refs.len);
    try std.testing.expect((deferCleanupRef(edge.cleanups[0]) orelse return error.TestUnexpectedResult).instruction_index == 1);
    switch (edge.refs[0]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 1),
        .ownership_action => return error.TestUnexpectedResult,
    }

    var queried_plan = (try cleanupEdgePlanFromTable(std.testing.allocator, table, .return_exit, 0)) orelse return error.TestUnexpectedResult;
    defer queried_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), queried_plan.cleanups.len);
    try std.testing.expect((deferCleanupRef(queried_plan.cleanups[0]) orelse return error.TestUnexpectedResult).instruction_index == 1);
}

test "cleanup edge table rejects ownership actions without MIR cleanup plan" {
    const span = ast.Span{ .offset = 1, .len = 1, .line = 1, .column = 1 };
    const cleanup_ref: mir_ownership_authority.OwnershipCleanupActionRef = .{
        .local_name = "g",
        .span = span,
        .cleanup_action_index = 0,
        .root_value_id = mir.ValueId.fromIndex(1),
        .resource_type_symbol_id = mir.SymbolId.fromIndex(2),
        .drop_glue_symbol_id = mir.SymbolId.fromIndex(3),
    };
    const function: mir.Function = .{
        .name = "f",
        .return_ty = .void,
        .no_lang_trap = false,
        .irq_context = false,
        .blocks = &.{},
        .trap_edges = &.{},
        .contract_regions = &.{},
        .range_facts = &.{},
        .pointer_provenance_facts = &.{},
        .representation_facts = &.{},
        .elided_bounds = &.{},
    };
    const stack = [_]DeferredCleanup{.{ .auto_drop = cleanup_ref }};

    try std.testing.expect((try buildTransitionalCleanupEdgeTable(std.testing.allocator, null, function, null, null, stack[0..], 0, .scope_exit)) == null);
}

test "defer cleanup stack snapshot restores full contents" {
    const span = ast.Span{ .offset = 1, .len = 1, .line = 1, .column = 1 };
    const later_span = ast.Span{ .offset = 2, .len = 1, .line = 1, .column = 2 };
    const first: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 0, .source = mir.sourcePointFromSpan(span) };
    const second: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 1, .source = mir.sourcePointFromSpan(later_span) };
    const block: ast.Block = .{ .span = span, .items = &.{} };

    var stack: std.ArrayList(DeferredCleanup) = .empty;
    defer stack.deinit(std.testing.allocator);
    try stack.append(std.testing.allocator, .{ .block = .{ .defer_ref = first, .block = block } });

    var snapshot = try captureDeferCleanupStack(std.testing.allocator, stack.items);
    defer snapshot.deinit(std.testing.allocator);

    stack.items[0] = .{ .block = .{ .defer_ref = second, .block = block } };
    try stack.append(std.testing.allocator, .{ .block = .{ .defer_ref = second, .block = block } });
    restoreDeferCleanupStack(&stack, snapshot);

    try std.testing.expectEqual(@as(usize, 1), stack.items.len);
    try std.testing.expect((deferCleanupRef(stack.items[0]) orelse return error.TestUnexpectedResult).instruction_index == 0);

    restoreDeferCleanupStackLength(&stack, 0);
    try std.testing.expectEqual(@as(usize, 0), stack.items.len);
}
