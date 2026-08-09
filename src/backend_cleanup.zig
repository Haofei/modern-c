const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
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

pub const CleanupStackMark = struct {
    index: usize,
};

pub const CleanupState = struct {
    entries: std.ArrayList(DeferredCleanup) = .empty,

    pub fn deinit(self: *CleanupState, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *CleanupState) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn stack(self: *CleanupState) *std.ArrayList(DeferredCleanup) {
        return &self.entries;
    }

    pub fn slice(self: *const CleanupState) []const DeferredCleanup {
        return self.entries.items;
    }

    pub fn mark(self: *const CleanupState) CleanupStackMark {
        return currentCleanupStackMark(self.slice());
    }
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

fn cleanupEdgeTableValid(
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

fn cleanupEdgeTableValidWithMirEdges(
    table: CleanupEdgeTable,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    defer_edges: ?*const mir.DeferCleanupEdgeTable,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
) bool {
    for (table.edges) |edge| {
        if (edge.cleanups.len != edge.refs.len) return false;
        if (!cleanupEdgeValid(edge, module, function, cleanup_plan)) return false;
        if (!cleanupEdgeDeferRefsAdmittedByMir(edge, defer_edges)) return false;
        if (!cleanupEdgeOwnershipRefsAdmittedByMir(edge, ownership_edges)) return false;
    }
    return true;
}

pub const CleanupEdgePlan = struct {
    kind: CleanupEdgeKind,
    start: CleanupStackMark,
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

pub fn currentCleanupStackMark(stack: []const DeferredCleanup) CleanupStackMark {
    return .{ .index = stack.len };
}

pub fn rootCleanupStackMark() CleanupStackMark {
    return .{ .index = 0 };
}

pub fn cleanupStackMarkIndex(mark: CleanupStackMark) usize {
    return mark.index;
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

pub fn restoreDeferCleanupStackToMark(stack: *std.ArrayList(DeferredCleanup), mark: CleanupStackMark) void {
    restoreDeferCleanupStackLength(stack, cleanupStackMarkIndex(mark));
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
    _ = allocator;
    const source = mir.sourcePointFromSpan(move_span);
    const ref = cleanupRemovalRefFromMirCancellation(function, cleanup_plan, .move_out, source) orelse {
        if (cleanupCancellationEntryFromMirPlan(cleanup_plan orelse return .ignored, .move_out, source) != null) return .ignored;
        if (directMoveLocalName(expr)) |local_name| {
            if (localHasConsumingAutoDropResourceEvent(module, function, local_name, .move_out)) return .rejected;
            if (localHasAutoDropCancellationObligation(function, local_name)) return .rejected;
        }
        return .ignored;
    };
    return if (removeAutoDropCleanup(stack, ref)) .applied else .ignored;
}

pub fn cancelAutoDropForExplicitDrop(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    stack: *std.ArrayList(DeferredCleanup),
    expr: ast.Expr,
) error{OutOfMemory}!AutoDropStackDecision {
    _ = allocator;
    const source = mir.sourcePointFromSpan(expr.span);
    const ref = cleanupRemovalRefFromMirCancellation(function, cleanup_plan, .explicit_drop, source) orelse {
        if (cleanupCancellationEntryFromMirPlan(cleanup_plan orelse return .ignored, .explicit_drop, source) != null) return .ignored;
        if (cleanupRemovalRefFromMirExplicitDropAction(function, cleanup_plan, source)) |action_ref| {
            return if (removeAutoDropCleanup(stack, action_ref)) .applied else .ignored;
        }
        if (explicitDropActionEntryFromMirPlan(cleanup_plan orelse return .ignored, source) != null) return .ignored;
        if (ast_query.dropPointerLocalReleaseCall(expr)) |release| {
            if (localHasConsumingAutoDropResourceEvent(module, function, release.local_name, .explicit_drop)) return .rejected;
            if (localHasAutoDropCancellationObligation(function, release.local_name)) return .rejected;
        }
        return .ignored;
    };
    return if (removeAutoDropCleanup(stack, ref)) .applied else .ignored;
}

pub fn registerDeferredExplicitDropCleanup(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    stack: *std.ArrayList(DeferredCleanup),
    expr: ast.Expr,
) error{OutOfMemory}!AutoDropStackDecision {
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return .ignored;
    if (!dropGlueReleaseFunctionExists(module, release.fn_name)) return .ignored;
    const cleanup = explicitDropLocalCleanupFromMirAction(module, function, cleanup_plan, expr) orelse return .rejected;
    try stack.append(allocator, .{ .explicit_drop = mir_ownership_authority.ownershipCleanupActionRef(cleanup) });
    return .applied;
}

pub fn registerOrdinaryDeferCleanup(
    allocator: std.mem.Allocator,
    function: *const mir.Function,
    defer_edges: ?*const mir.DeferCleanupEdgeTable,
    stack: *std.ArrayList(DeferredCleanup),
    cleanup: DeferredCleanup,
) error{OutOfMemory}!AutoDropStackDecision {
    const ref = deferCleanupRef(cleanup) orelse return .ignored;
    const edges = defer_edges orelse return .rejected;
    if (!mir.deferCleanupEdgeTableContainsRef(edges.*, ref)) return .rejected;
    return appendValidatedCleanup(allocator, function, stack, cleanup);
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

pub fn deferCleanupStackAdmittedByMir(
    function: mir.Function,
    defer_edges: ?*const mir.DeferCleanupEdgeTable,
    stack: []const DeferredCleanup,
) bool {
    if (!deferCleanupStackRefsValid(function, stack)) return false;
    for (stack) |cleanup| {
        const ref = deferCleanupRef(cleanup) orelse continue;
        const edges = defer_edges orelse return false;
        if (!mir.deferCleanupEdgeTableContainsRef(edges.*, ref)) return false;
    }
    return true;
}

fn deferCleanupEmissionRangeValid(function: mir.Function, stack: []const DeferredCleanup, start: usize) bool {
    if (start > stack.len) return false;
    if (!deferCleanupStackRefsValid(function, stack)) return false;
    for (stack[start..]) |cleanup| {
        const ref = deferCleanupRef(cleanup) orelse continue;
        if (!mir.deferCleanupRefValid(function, ref)) return false;
    }
    return true;
}

fn deferCleanupEmissionCount(stack: []const DeferredCleanup, start: usize) ?usize {
    if (start > stack.len) return null;
    return stack.len - start;
}

fn deferCleanupAtEmissionIndex(
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

fn buildTransitionalCleanupEdgeTable(
    allocator: std.mem.Allocator,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    defer_edges: ?*const mir.DeferCleanupEdgeTable,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
    stack: []const DeferredCleanup,
    start: CleanupStackMark,
    kind: CleanupEdgeKind,
) !?CleanupEdgeTable {
    const start_index = cleanupStackMarkIndex(start);
    const count = deferCleanupEmissionCount(stack, start_index) orelse return null;
    if (!deferCleanupEmissionRangeValid(function, stack, start_index)) return null;

    const edges = try allocator.alloc(CleanupEdge, 1);
    errdefer allocator.free(edges);
    var cleanups = try allocator.alloc(DeferredCleanup, count);
    errdefer allocator.free(cleanups);
    var refs = try allocator.alloc(CleanupRef, count);
    errdefer allocator.free(refs);

    var emission_index: usize = 0;
    while (emission_index < count) : (emission_index += 1) {
        const cleanup = deferCleanupAtEmissionIndex(function, stack, start_index, emission_index) orelse return null;
        cleanups[emission_index] = cleanup;
        refs[emission_index] = cleanupRef(cleanup);
    }

    edges[0] = .{
        .kind = kind,
        .start = start_index,
        .cleanups = cleanups,
        .refs = refs,
    };
    var table: CleanupEdgeTable = .{ .edges = edges };
    var owned_defer_edges = if (defer_edges == null)
        try mir.buildDeferCleanupEdgeTable(allocator, function)
    else
        null;
    defer if (owned_defer_edges) |*edges_table| edges_table.deinit(allocator);
    const admitted_defer_edges = defer_edges orelse &owned_defer_edges.?;
    if (!cleanupEdgeTableValidWithMirEdges(table, module, function, cleanup_plan, admitted_defer_edges, ownership_edges)) {
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
    defer_edges: ?*const mir.DeferCleanupEdgeTable,
    ownership_edges: ?*const mir.OwnershipCleanupEdgeTable,
    stack: []const DeferredCleanup,
    start: CleanupStackMark,
    kind: CleanupEdgeKind,
) !?CleanupEdgePlan {
    var table = (try buildTransitionalCleanupEdgeTable(allocator, module, function, cleanup_plan, defer_edges, ownership_edges, stack, start, kind)) orelse return null;
    defer table.deinit(allocator);
    return try cleanupEdgePlanFromTable(allocator, table, kind, start);
}

pub fn cleanupEdgePlanFromTable(
    allocator: std.mem.Allocator,
    table: CleanupEdgeTable,
    kind: CleanupEdgeKind,
    start: CleanupStackMark,
) !?CleanupEdgePlan {
    const edge = cleanupEdgeFor(table, kind, start) orelse return null;
    const cleanups = try allocator.dupe(DeferredCleanup, edge.cleanups);
    return .{
        .kind = edge.kind,
        .start = start,
        .cleanups = cleanups,
    };
}

pub fn cleanupEdgeFor(table: CleanupEdgeTable, kind: CleanupEdgeKind, start: CleanupStackMark) ?CleanupEdge {
    for (table.edges) |edge| {
        if (edge.kind != kind) continue;
        if (edge.start != cleanupStackMarkIndex(start)) continue;
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

fn cleanupEdgeDeferRefsAdmittedByMir(
    edge: CleanupEdge,
    defer_edges: ?*const mir.DeferCleanupEdgeTable,
) bool {
    var saw_defer_ref = false;
    for (edge.refs) |ref| {
        switch (ref) {
            .defer_ref => |defer_ref| {
                saw_defer_ref = true;
                const table = defer_edges orelse return false;
                if (!mir.deferCleanupEdgeTableContainsRef(table.*, defer_ref)) return false;
            },
            .ownership_action => {},
        }
    }
    return !saw_defer_ref or defer_edges != null;
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

fn cleanupRemovalRefFromMirCancellation(
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    kind: mir.CleanupCancellationKind,
    source: mir.SourcePoint,
) ?mir_ownership_authority.OwnershipCleanupRemovalRef {
    const plan = cleanup_plan orelse return null;
    const cancellation = cleanupCancellationEntryFromMirPlan(plan, kind, source) orelse return null;
    if (cancellation.place.root_symbol_id.isValid() or cancellation.place.projection_count != 0) return null;
    const root_value_id = cancellation.place.root_value_id;
    const local_name = localNameForValueId(function, root_value_id) orelse return null;

    for (plan.actions, 0..) |action, action_index| {
        if (action.kind != .auto_drop) continue;
        if (action.generation != cancellation.generation) continue;
        if (!action.place.root_value_id.eql(root_value_id)) continue;
        if (!action.place.root_type_symbol_id.eql(cancellation.place.root_type_symbol_id)) continue;
        if (!action.drop_glue_symbol_id.eql(cancellation.drop_glue_symbol_id)) continue;
        return .{
            .local_name = local_name,
            .cleanup_action_index = action_index,
            .root_value_id = root_value_id,
            .resource_type_symbol_id = cancellation.place.root_type_symbol_id,
            .drop_glue_symbol_id = cancellation.drop_glue_symbol_id,
        };
    }
    return null;
}

fn cleanupRemovalRefFromMirExplicitDropAction(
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    source: mir.SourcePoint,
) ?mir_ownership_authority.OwnershipCleanupRemovalRef {
    const plan = cleanup_plan orelse return null;
    const action_match = explicitDropActionEntryFromMirPlan(plan, source) orelse return null;
    if (action_match.entry.place.root_symbol_id.isValid() or action_match.entry.place.projection_count != 0) return null;
    const root_value_id = action_match.entry.place.root_value_id;
    const local_name = localNameForValueId(function, root_value_id) orelse return null;
    for (plan.actions, 0..) |action, action_index| {
        if (action.kind != .auto_drop) continue;
        if (action.generation != action_match.entry.generation) continue;
        if (!action.place.root_value_id.eql(root_value_id)) continue;
        if (!action.place.root_type_symbol_id.eql(action_match.entry.place.root_type_symbol_id)) continue;
        if (!action.drop_glue_symbol_id.eql(action_match.entry.drop_glue_symbol_id)) continue;
        return .{
            .local_name = local_name,
            .cleanup_action_index = action_index,
            .root_value_id = root_value_id,
            .resource_type_symbol_id = action_match.entry.place.root_type_symbol_id,
            .drop_glue_symbol_id = action_match.entry.drop_glue_symbol_id,
        };
    }
    return null;
}

fn explicitDropLocalCleanupFromMirAction(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    expr: ast.Expr,
) ?mir_ownership_authority.AutoDropLocalCleanup {
    const plan = cleanup_plan orelse return null;
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return null;
    const action_match = explicitDropActionEntryFromMirPlan(plan, mir.sourcePointFromSpan(expr.span)) orelse return null;
    if (action_match.entry.place.root_symbol_id.isValid() or action_match.entry.place.projection_count != 0) return null;
    const root_value_id = action_match.entry.place.root_value_id;
    const local_name = localNameForValueId(function, root_value_id) orelse return null;
    if (!std.mem.eql(u8, local_name, release.local_name)) return null;
    const ref: mir_ownership_authority.OwnershipCleanupActionRef = .{
        .local_name = local_name,
        .span = expr.span,
        .cleanup_action_index = action_match.action_index,
        .root_value_id = root_value_id,
        .resource_type_symbol_id = action_match.entry.place.root_type_symbol_id,
        .drop_glue_symbol_id = action_match.entry.drop_glue_symbol_id,
    };
    return mir_ownership_authority.explicitDropLocalCleanupFromActionRef(module, function, plan, ref);
}

const ExplicitDropActionMatch = struct {
    action_index: usize,
    entry: mir.CleanupActionPlanEntry,
};

fn explicitDropActionEntryFromMirPlan(
    plan: *const mir.OwnershipCleanupPlan,
    source: mir.SourcePoint,
) ?ExplicitDropActionMatch {
    var matched: ?ExplicitDropActionMatch = null;
    for (plan.actions, 0..) |entry, action_index| {
        if (entry.kind != .explicit_drop) continue;
        if (!sourceMatches(entry.source, source)) continue;
        if (matched != null) return null;
        matched = .{ .action_index = action_index, .entry = entry };
    }
    return matched;
}

fn localHasAutoDropCancellationObligation(
    function: *const mir.Function,
    local_name: []const u8,
) bool {
    const root_value_id = valueIdForLocal(function, local_name) orelse return false;
    for (function.ownership_events) |event| {
        if (event.kind != .auto_drop) continue;
        if (!event.place.root_value_id.eql(root_value_id)) continue;
        return true;
    }
    return false;
}

fn localHasConsumingAutoDropResourceEvent(
    module: *const mir.Module,
    function: *const mir.Function,
    local_name: []const u8,
    kind: mir.CleanupCancellationKind,
) bool {
    const root_value_id = valueIdForLocal(function, local_name) orelse return false;
    const event_kind: mir.OwnershipEventKind = switch (kind) {
        .move_out => .move_out,
        .explicit_drop => .explicit_drop,
    };
    for (function.ownership_events) |event| {
        if (event.kind != event_kind) continue;
        if (!event.place.root_value_id.eql(root_value_id)) continue;
        if (!typeSymbolHasDropGlue(module, event.place.root_type_symbol_id)) continue;
        return true;
    }
    return false;
}

fn typeSymbolHasDropGlue(module: *const mir.Module, type_symbol_id: mir.SymbolId) bool {
    if (!type_symbol_id.isValid()) return false;
    for (module.type_ownership_facts) |fact| {
        if (!fact.typed_type_symbol_id.eql(type_symbol_id)) continue;
        return fact.drop_glue_symbol_id.isValid();
    }
    return false;
}

fn dropGlueReleaseFunctionExists(module: *const mir.Module, release_fn: []const u8) bool {
    for (module.drop_glue_facts) |fact| {
        if (std.mem.eql(u8, fact.release_fn, release_fn)) return true;
    }
    return false;
}

fn cleanupCancellationEntryFromMirPlan(
    plan: *const mir.OwnershipCleanupPlan,
    kind: mir.CleanupCancellationKind,
    source: mir.SourcePoint,
) ?mir.CleanupCancellationPlanEntry {
    var matched: ?mir.CleanupCancellationPlanEntry = null;
    for (plan.cancellations) |entry| {
        if (entry.kind != kind) continue;
        if (!sourceMatches(entry.source, source)) continue;
        if (matched != null) return null;
        matched = entry;
    }
    return matched;
}

fn directMoveLocalName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| directMoveLocalName(inner.*),
        .move_expr => |inner| switch (inner.kind) {
            .grouped => directMoveLocalName(inner.*),
            .ident => |ident| ident.text,
            else => null,
        },
        .ident => |ident| ident.text,
        else => null,
    };
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

fn localNameForValueId(function: *const mir.Function, value_id: mir.ValueId) ?[]const u8 {
    if (!value_id.isValid()) return null;
    for (function.value_identities) |identity| {
        if (identity.id.eql(value_id)) return identity.spelling;
    }
    return null;
}

fn sourceMatches(actual: mir.SourcePoint, expected: mir.SourcePoint) bool {
    if (actual.line != expected.line or actual.column != expected.column) return false;
    if (actual.offset == 0 and actual.len == 0 and expected.offset == 0 and expected.len == 0) return true;
    return actual.offset == expected.offset and actual.len == expected.len;
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

    var mir_defer_edges = try mir.buildDeferCleanupEdgeTable(std.testing.allocator, function);
    defer mir_defer_edges.deinit(std.testing.allocator);
    try std.testing.expect(mir.deferCleanupEdgeTableValid(function, mir_defer_edges));
    try std.testing.expectEqual(@as(usize, 1), mir_defer_edges.edges.len);
    try std.testing.expectEqual(@as(usize, 2), mir_defer_edges.edges[0].actions.len);
    try std.testing.expectEqual(@as(usize, 1), mir_defer_edges.edges[0].actions[0].instruction_index);
    try std.testing.expect(mir.deferCleanupEdgeTableContainsRef(mir_defer_edges, second));
    var stale_second = second;
    stale_second.source.column += 1;
    try std.testing.expect(!mir.deferCleanupEdgeTableContainsRef(mir_defer_edges, stale_second));
    var registration_stack: std.ArrayList(DeferredCleanup) = .empty;
    defer registration_stack.deinit(std.testing.allocator);
    try std.testing.expectEqual(AutoDropStackDecision.rejected, try registerOrdinaryDeferCleanup(std.testing.allocator, &function, null, &registration_stack, .{ .block = .{ .defer_ref = first, .block = block } }));
    try std.testing.expectEqual(AutoDropStackDecision.applied, try registerOrdinaryDeferCleanup(std.testing.allocator, &function, &mir_defer_edges, &registration_stack, .{ .block = .{ .defer_ref = first, .block = block } }));
    try std.testing.expectEqual(AutoDropStackDecision.rejected, try registerOrdinaryDeferCleanup(std.testing.allocator, &function, &mir_defer_edges, &registration_stack, .{ .block = .{ .defer_ref = stale_second, .block = block } }));

    try std.testing.expect(deferCleanupStackRefsValid(function, &.{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = second, .block = block } },
    }));
    try std.testing.expect(deferCleanupStackAdmittedByMir(function, &mir_defer_edges, &.{
        .{ .block = .{ .defer_ref = first, .block = block } },
        .{ .block = .{ .defer_ref = second, .block = block } },
    }));
    try std.testing.expect(!deferCleanupStackAdmittedByMir(function, null, &.{
        .{ .block = .{ .defer_ref = first, .block = block } },
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

    const root_mark = rootCleanupStackMark();
    var plan = (try buildCleanupEdgePlan(std.testing.allocator, null, function, null, &mir_defer_edges, null, stack[0..], root_mark, .return_exit)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(CleanupEdgeKind.return_exit, plan.kind);
    try std.testing.expectEqual(@as(usize, 0), cleanupStackMarkIndex(plan.start));
    try std.testing.expectEqual(@as(usize, 2), plan.cleanups.len);
    try std.testing.expect((deferCleanupRef(plan.cleanups[0]) orelse return error.TestUnexpectedResult).instruction_index == 1);
    try std.testing.expect((deferCleanupRef(plan.cleanups[1]) orelse return error.TestUnexpectedResult).instruction_index == 0);

    var table = (try buildTransitionalCleanupEdgeTable(std.testing.allocator, null, function, null, &mir_defer_edges, null, stack[0..], root_mark, .return_exit)) orelse return error.TestUnexpectedResult;
    defer table.deinit(std.testing.allocator);
    const edge = cleanupEdgeFor(table, .return_exit, root_mark) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CleanupEdgeKind.return_exit, edge.kind);
    try std.testing.expectEqual(@as(usize, 2), edge.cleanups.len);
    try std.testing.expectEqual(@as(usize, 2), edge.refs.len);
    try std.testing.expect((deferCleanupRef(edge.cleanups[0]) orelse return error.TestUnexpectedResult).instruction_index == 1);
    switch (edge.refs[0]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 1),
        .ownership_action => return error.TestUnexpectedResult,
    }

    var queried_plan = (try cleanupEdgePlanFromTable(std.testing.allocator, table, .return_exit, root_mark)) orelse return error.TestUnexpectedResult;
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
    const root_mark = rootCleanupStackMark();

    try std.testing.expect((try buildTransitionalCleanupEdgeTable(std.testing.allocator, null, function, null, null, null, stack[0..], root_mark, .scope_exit)) == null);
}

test "defer cleanup stack snapshot restores full contents" {
    const span = ast.Span{ .offset = 1, .len = 1, .line = 1, .column = 1 };
    const later_span = ast.Span{ .offset = 2, .len = 1, .line = 1, .column = 2 };
    const first: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 0, .source = mir.sourcePointFromSpan(span) };
    const second: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 1, .source = mir.sourcePointFromSpan(later_span) };
    const block: ast.Block = .{ .span = span, .items = &.{} };
    const root_mark = rootCleanupStackMark();

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

    restoreDeferCleanupStackToMark(&stack, root_mark);
    try std.testing.expectEqual(@as(usize, 0), stack.items.len);
}
