const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const mir = @import("mir.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");

/// Backend cleanup payload admitted by MIR cleanup facts.
///
/// C and LLVM lowering keep backend-specific expression payloads here, but all
/// cleanup registration, cancellation, and exit-edge emission is routed through
/// MIR-admitted cleanup cursors. Backends must not make cleanup lifetime
/// decisions from source syntax alone.
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

pub const AutoDropStackDecision = enum {
    applied,
    ignored,
    rejected,
};

pub const CleanupCursor = struct {
    index: usize,
};

pub const CleanupState = struct {
    entries: std.ArrayList(CleanupRef) = .empty,

    pub fn deinit(self: *CleanupState, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *CleanupState) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn slice(self: *const CleanupState) []const CleanupRef {
        return self.entries.items;
    }

    pub fn cursor(self: *const CleanupState) CleanupCursor {
        return .{ .index = self.entries.items.len };
    }

    pub fn isAt(self: *const CleanupState, cleanup_cursor: CleanupCursor) bool {
        return self.entries.items.len == cleanup_cursor.index;
    }

    pub fn restoreToCursor(self: *CleanupState, cleanup_cursor: CleanupCursor) void {
        std.debug.assert(cleanup_cursor.index <= self.entries.capacity);
        self.entries.items.len = cleanup_cursor.index;
    }

    pub fn capture(self: *const CleanupState, allocator: std.mem.Allocator) !CleanupStateSnapshot {
        return .{ .items = try allocator.dupe(CleanupRef, self.entries.items) };
    }

    pub fn restore(self: *CleanupState, snapshot: CleanupStateSnapshot) void {
        self.entries.items.len = snapshot.items.len;
        @memcpy(self.entries.items[0..snapshot.items.len], snapshot.items);
    }

    fn append(self: *CleanupState, allocator: std.mem.Allocator, ref: CleanupRef) !void {
        try self.entries.append(allocator, ref);
    }

    fn removeAutoDrop(self: *CleanupState, ref: mir_ownership_authority.OwnershipCleanupRemovalRef) bool {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            switch (self.entries.items[index]) {
                .ownership_action => |cleanup| {
                    if (!autoDropCleanupMatchesRef(cleanup, ref)) continue;
                    _ = self.entries.orderedRemove(index);
                    return true;
                },
                .defer_ref => continue,
            }
        }
        return false;
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
    refs: []CleanupRef = &.{},
};

pub const CleanupEdgeTable = struct {
    edges: []CleanupEdge = &.{},

    pub fn deinit(self: *CleanupEdgeTable, allocator: std.mem.Allocator) void {
        for (self.edges) |edge| {
            allocator.free(edge.refs);
        }
        allocator.free(self.edges);
        self.edges = &.{};
    }
};

fn cleanupEdgeTableValidWithMirEdges(
    table: CleanupEdgeTable,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup_cfg: ?*const mir.CleanupCfg,
) bool {
    for (table.edges) |edge| {
        if (!cleanupEdgeValid(edge, module, function, cleanup_plan)) return false;
        if (!cleanupEdgeRefsAdmittedByCleanupCfg(edge, cleanup_cfg)) return false;
    }
    return true;
}

pub const CleanupEdgePlan = struct {
    kind: CleanupEdgeKind,
    start: CleanupCursor,
    refs: []CleanupRef,

    pub fn deinit(self: *CleanupEdgePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.refs);
        self.refs = &.{};
    }
};

pub const CleanupStateSnapshot = struct {
    items: []CleanupRef,

    pub fn deinit(self: *CleanupStateSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub fn rootCleanupCursor() CleanupCursor {
    return .{ .index = 0 };
}

pub fn cleanupCursorIndex(cursor: CleanupCursor) usize {
    return cursor.index;
}

pub fn registerAutoDropLocalCleanup(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup_cfg: ?*const mir.CleanupCfg,
    state: *CleanupState,
    local_name: []const u8,
    type_name: []const u8,
    local_span: ast.Span,
) error{OutOfMemory}!AutoDropStackDecision {
    if (!mir_ownership_authority.autoDropEligibleTypeName(module, type_name)) return .ignored;
    const cleanup = autoDropLocalCleanupFromMirCfg(module, function, cleanup_plan, cleanup_cfg, local_name, type_name, local_span) orelse {
        const ownership = typeOwnershipFactForTypeName(module, type_name) orelse return .rejected;
        const root_value_id = valueIdForLocal(function, local_name) orelse return .rejected;
        if (mir.ownershipLocalHasConsumingResourceEvent(function.*, root_value_id, ownership.typed_type_symbol_id)) return .ignored;
        return .rejected;
    };
    try state.append(allocator, .{ .ownership_action = mir_ownership_authority.ownershipCleanupActionRef(cleanup) });
    return .applied;
}

pub fn cancelAutoDropForMove(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    state: *CleanupState,
    expr: ast.Expr,
    move_span: ast.Span,
) error{OutOfMemory}!AutoDropStackDecision {
    _ = allocator;
    const plan = cleanup_plan orelse return .rejected;
    const source = mir.sourcePointFromSpan(move_span);
    const ref = cleanupRemovalRefFromMirCancellation(function, plan, .move_out, source) orelse {
        if (cleanupCancellationEntryFromMirPlan(plan, .move_out, source) != null) return .ignored;
        if (directMoveLocalName(expr)) |local_name| {
            if (localHasConsumingAutoDropResourceEvent(module, function, local_name, .move_out)) return .rejected;
            if (localHasAutoDropCancellationObligation(function, local_name)) return .rejected;
        }
        return .ignored;
    };
    return if (state.removeAutoDrop(ref)) .applied else .ignored;
}

pub fn cancelAutoDropForExplicitDrop(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    state: *CleanupState,
    expr: ast.Expr,
) error{OutOfMemory}!AutoDropStackDecision {
    _ = allocator;
    const plan = cleanup_plan orelse return .rejected;
    const source = mir.sourcePointFromSpan(expr.span);
    const ref = cleanupRemovalRefFromMirCancellation(function, plan, .explicit_drop, source) orelse {
        if (cleanupCancellationEntryFromMirPlan(plan, .explicit_drop, source) != null) return .ignored;
        if (cleanupRemovalRefFromMirExplicitDropAction(function, plan, source)) |action_ref| {
            return if (state.removeAutoDrop(action_ref)) .applied else .ignored;
        }
        if (explicitDropActionEntryFromMirPlan(plan, source) != null) return .ignored;
        if (ast_query.dropPointerLocalReleaseCall(expr)) |release| {
            if (localHasConsumingAutoDropResourceEvent(module, function, release.local_name, .explicit_drop)) return .rejected;
            if (localHasAutoDropCancellationObligation(function, release.local_name)) return .rejected;
        }
        return .ignored;
    };
    return if (state.removeAutoDrop(ref)) .applied else .ignored;
}

pub fn registerDeferredExplicitDropCleanup(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    state: *CleanupState,
    expr: ast.Expr,
) error{OutOfMemory}!AutoDropStackDecision {
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return .ignored;
    if (!dropGlueReleaseFunctionExists(module, release.fn_name)) return .ignored;
    const cleanup = explicitDropLocalCleanupFromMirAction(module, function, cleanup_plan, expr) orelse return .rejected;
    try state.append(allocator, .{ .ownership_action = mir_ownership_authority.ownershipCleanupActionRef(cleanup) });
    return .applied;
}

pub fn registerOrdinaryDeferCleanup(
    allocator: std.mem.Allocator,
    function: *const mir.Function,
    cleanup_cfg: ?*const mir.CleanupCfg,
    state: *CleanupState,
    ref: mir.DeferCleanupRef,
) error{OutOfMemory}!AutoDropStackDecision {
    const cfg = cleanup_cfg orelse return .rejected;
    if (!cleanupCfgContainsRef(cfg.*, .{ .defer_ref = ref })) return .rejected;
    return appendValidatedCleanup(allocator, function, state, .{ .defer_ref = ref });
}

fn appendValidatedCleanup(
    allocator: std.mem.Allocator,
    function: *const mir.Function,
    state: *CleanupState,
    ref: CleanupRef,
) error{OutOfMemory}!AutoDropStackDecision {
    const old_cursor = state.cursor();
    try state.append(allocator, ref);
    if (deferCleanupRefsValid(function.*, state.slice())) return .applied;
    state.restoreToCursor(old_cursor);
    return .rejected;
}

fn deferCleanupRefsValid(function: mir.Function, refs: []const CleanupRef) bool {
    for (refs, 0..) |entry, index| {
        const ref = switch (entry) {
            .defer_ref => |ref| ref,
            .ownership_action => continue,
        };
        if (!mir.deferCleanupRefValid(function, ref)) return false;
        var previous_index: usize = 0;
        while (previous_index < index) : (previous_index += 1) {
            const previous = switch (refs[previous_index]) {
                .defer_ref => |previous| previous,
                .ownership_action => continue,
            };
            if (sameDeferCleanupRef(previous, ref)) return false;
            if (deferCleanupRefAfter(function, previous, ref)) return false;
        }
    }
    return true;
}

pub fn cleanupStateAdmittedByMir(
    function: mir.Function,
    cleanup_cfg: ?*const mir.CleanupCfg,
    state: *const CleanupState,
) bool {
    if (!deferCleanupRefsValid(function, state.slice())) return false;
    for (state.slice()) |entry| {
        const ref = switch (entry) {
            .defer_ref => |ref| ref,
            .ownership_action => continue,
        };
        const cfg = cleanup_cfg orelse return false;
        if (!cleanupCfgContainsRef(cfg.*, .{ .defer_ref = ref })) return false;
    }
    return true;
}

fn deferCleanupEmissionRangeValid(function: mir.Function, refs: []const CleanupRef, start: usize) bool {
    if (start > refs.len) return false;
    if (!deferCleanupRefsValid(function, refs)) return false;
    for (refs[start..]) |entry| {
        const ref = switch (entry) {
            .defer_ref => |ref| ref,
            .ownership_action => continue,
        };
        if (!mir.deferCleanupRefValid(function, ref)) return false;
    }
    return true;
}

fn deferCleanupEmissionCount(refs: []const CleanupRef, start: usize) ?usize {
    if (start > refs.len) return null;
    return refs.len - start;
}

fn cleanupRefAtEmissionIndex(
    function: mir.Function,
    refs: []const CleanupRef,
    start: usize,
    emission_index: usize,
) ?CleanupRef {
    const count = deferCleanupEmissionCount(refs, start) orelse return null;
    if (emission_index >= count) return null;
    if (!deferCleanupEmissionRangeValid(function, refs, start)) return null;
    return refs[refs.len - 1 - emission_index];
}

fn buildCleanupEdgeTableFromCursor(
    allocator: std.mem.Allocator,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup_cfg: ?*const mir.CleanupCfg,
    state: *const CleanupState,
    start: CleanupCursor,
    kind: CleanupEdgeKind,
) !?CleanupEdgeTable {
    const refs_active = state.slice();
    const start_index = cleanupCursorIndex(start);
    const active_count = deferCleanupEmissionCount(refs_active, start_index) orelse return null;
    if (!deferCleanupEmissionRangeValid(function, refs_active, start_index)) return null;
    if (active_count == 0) {
        const empty_edges = try allocator.alloc(CleanupEdge, 1);
        errdefer allocator.free(empty_edges);
        empty_edges[0] = .{ .kind = kind, .start = start_index };
        return .{ .edges = empty_edges };
    }

    const cfg = cleanup_cfg orelse return null;
    const cfg_edge = cleanupCfgEdgeForKind(cfg.*, cleanupCfgKindFromBackend(kind)) orelse return null;

    var ref_items: std.ArrayList(CleanupRef) = .empty;
    errdefer ref_items.deinit(allocator);

    for (cfg_edge.actions) |action| {
        const ref = cleanupRefFromCleanupCfgAction(function, action) orelse return null;
        if (!cleanupRefInEmissionRange(function, refs_active, start_index, ref)) continue;
        try ref_items.append(allocator, ref);
    }
    if (ref_items.items.len != active_count) return null;

    const edges = try allocator.alloc(CleanupEdge, 1);
    errdefer allocator.free(edges);
    const refs = try ref_items.toOwnedSlice(allocator);
    errdefer allocator.free(refs);

    edges[0] = .{
        .kind = kind,
        .start = start_index,
        .refs = refs,
    };
    var table: CleanupEdgeTable = .{ .edges = edges };
    if (!cleanupEdgeTableValidWithMirEdges(table, module, function, cleanup_plan, cleanup_cfg)) {
        table.deinit(allocator);
        return null;
    }
    return table;
}

fn cleanupCfgEdgeForKind(cfg: mir.CleanupCfg, kind: mir.CleanupCfgEdgeKind) ?mir.CleanupCfgEdge {
    for (cfg.edges) |edge| {
        if (edge.kind == kind) return edge;
    }
    return null;
}

fn cleanupRefFromCleanupCfgAction(function: mir.Function, action: mir.CleanupCfgActionRef) ?CleanupRef {
    return switch (action) {
        .defer_cleanup => |ref| .{ .defer_ref = .{ .block_id = ref.block_id, .instruction_index = ref.instruction_index, .source = ref.source } },
        .ownership => |ref| .{ .ownership_action = .{
            .local_name = localNameForValueId(&function, ref.root_value_id) orelse return null,
            .span = ast.Span{ .offset = ref.source.offset, .len = ref.source.len, .line = ref.source.line, .column = ref.source.column },
            .cleanup_action_index = ref.cleanup_action_index,
            .root_value_id = ref.root_value_id,
            .resource_type_symbol_id = ref.resource_type_symbol_id,
            .drop_glue_symbol_id = ref.drop_glue_symbol_id,
        } },
    };
}

fn cleanupRefInEmissionRange(
    function: mir.Function,
    refs: []const CleanupRef,
    start: usize,
    ref: CleanupRef,
) bool {
    const count = deferCleanupEmissionCount(refs, start) orelse return false;
    var emission_index: usize = 0;
    while (emission_index < count) : (emission_index += 1) {
        const candidate = cleanupRefAtEmissionIndex(function, refs, start, emission_index) orelse return false;
        if (cleanupRefsEqual(ref, candidate)) return true;
    }
    return false;
}

pub fn buildCleanupEdgePlan(
    allocator: std.mem.Allocator,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup_cfg: ?*const mir.CleanupCfg,
    state: *const CleanupState,
    start: CleanupCursor,
    kind: CleanupEdgeKind,
) !?CleanupEdgePlan {
    var table = (try buildCleanupEdgeTableFromCursor(allocator, module, function, cleanup_plan, cleanup_cfg, state, start, kind)) orelse return null;
    defer table.deinit(allocator);
    return try cleanupEdgePlanFromTable(allocator, table, kind, start);
}

pub fn cleanupEdgePlanFromTable(
    allocator: std.mem.Allocator,
    table: CleanupEdgeTable,
    kind: CleanupEdgeKind,
    start: CleanupCursor,
) !?CleanupEdgePlan {
    const edge = cleanupEdgeFor(table, kind, start) orelse return null;
    const refs = try allocator.dupe(CleanupRef, edge.refs);
    return .{
        .kind = edge.kind,
        .start = start,
        .refs = refs,
    };
}

pub fn cleanupEdgeFor(table: CleanupEdgeTable, kind: CleanupEdgeKind, start: CleanupCursor) ?CleanupEdge {
    for (table.edges) |edge| {
        if (edge.kind != kind) continue;
        if (edge.start != cleanupCursorIndex(start)) continue;
        return edge;
    }
    return null;
}

fn cleanupEdgeValid(
    edge: CleanupEdge,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
) bool {
    for (edge.refs) |ref| {
        if (!cleanupRefValidForEdge(ref, module, function, cleanup_plan)) return false;
    }
    return true;
}

fn cleanupEdgeRefsAdmittedByCleanupCfg(
    edge: CleanupEdge,
    cleanup_cfg: ?*const mir.CleanupCfg,
) bool {
    var saw_ref = false;
    for (edge.refs) |ref| {
        saw_ref = true;
        const cfg = cleanup_cfg orelse return false;
        if (!cleanupCfgContainsRefOnKind(cfg.*, cleanupCfgKindFromBackend(edge.kind), ref)) return false;
    }
    return !saw_ref or cleanup_cfg != null;
}

fn cleanupCfgContainsRef(cfg: mir.CleanupCfg, ref: CleanupRef) bool {
    for (cfg.edges) |edge| {
        for (edge.actions) |action| {
            switch (ref) {
                .defer_ref => |defer_ref| switch (action) {
                    .defer_cleanup => |candidate| {
                        if (candidate.block_id.eql(defer_ref.block_id) and
                            candidate.instruction_index == defer_ref.instruction_index and
                            sourceMatches(candidate.source, defer_ref.source)) return true;
                    },
                    .ownership => {},
                },
                .ownership_action => |ownership_ref| switch (action) {
                    .ownership => |candidate| {
                        if (candidate.cleanup_action_index == ownership_ref.cleanup_action_index and
                            candidate.root_value_id.eql(ownership_ref.root_value_id) and
                            candidate.resource_type_symbol_id.eql(ownership_ref.resource_type_symbol_id) and
                            candidate.drop_glue_symbol_id.eql(ownership_ref.drop_glue_symbol_id)) return true;
                    },
                    .defer_cleanup => {},
                },
            }
        }
    }
    return false;
}

fn cleanupCfgContainsRefOnKind(cfg: mir.CleanupCfg, kind: mir.CleanupCfgEdgeKind, ref: CleanupRef) bool {
    for (cfg.edges) |edge| {
        if (edge.kind != kind) continue;
        for (edge.actions) |action| {
            switch (ref) {
                .defer_ref => |defer_ref| switch (action) {
                    .defer_cleanup => |candidate| {
                        if (candidate.block_id.eql(defer_ref.block_id) and
                            candidate.instruction_index == defer_ref.instruction_index and
                            sourceMatches(candidate.source, defer_ref.source)) return true;
                    },
                    .ownership => {},
                },
                .ownership_action => |ownership_ref| switch (action) {
                    .ownership => |candidate| {
                        if (candidate.cleanup_action_index == ownership_ref.cleanup_action_index and
                            candidate.root_value_id.eql(ownership_ref.root_value_id) and
                            candidate.resource_type_symbol_id.eql(ownership_ref.resource_type_symbol_id) and
                            candidate.drop_glue_symbol_id.eql(ownership_ref.drop_glue_symbol_id)) return true;
                    },
                    .defer_cleanup => {},
                },
            }
        }
    }
    return false;
}

fn cleanupCfgKindFromBackend(kind: CleanupEdgeKind) mir.CleanupCfgEdgeKind {
    return switch (kind) {
        .scope_exit => .scope_exit,
        .return_exit => .return_exit,
        .break_exit => .break_exit,
        .continue_exit => .continue_exit,
        .error_exit => .error_exit,
    };
}

fn autoDropLocalCleanupFromMirCfg(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup_cfg: ?*const mir.CleanupCfg,
    local_name: []const u8,
    type_name: []const u8,
    local_span: ast.Span,
) ?mir_ownership_authority.AutoDropLocalCleanup {
    const plan = cleanup_plan orelse return null;
    const cfg = cleanup_cfg orelse return null;
    const ownership = typeOwnershipFactForTypeName(module, type_name) orelse return null;
    if (ownership.kind != .affine or !ownership.drop_glue_symbol_id.isValid()) return null;
    const root_value_id = valueIdForLocal(function, local_name) orelse return null;

    for (cfg.edges) |edge| {
        for (edge.actions) |action| {
            const ownership_action = switch (action) {
                .ownership => |ref| ref,
                .defer_cleanup => continue,
            };
            if (ownership_action.kind != .auto_drop) continue;
            if (!ownership_action.root_value_id.eql(root_value_id)) continue;
            if (!ownership_action.resource_type_symbol_id.eql(ownership.typed_type_symbol_id)) continue;
            if (!ownership_action.drop_glue_symbol_id.eql(ownership.drop_glue_symbol_id)) continue;
            const ref: mir_ownership_authority.OwnershipCleanupActionRef = .{
                .local_name = local_name,
                .span = local_span,
                .cleanup_action_index = ownership_action.cleanup_action_index,
                .root_value_id = ownership_action.root_value_id,
                .resource_type_symbol_id = ownership_action.resource_type_symbol_id,
                .drop_glue_symbol_id = ownership_action.drop_glue_symbol_id,
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

fn cleanupRefsEqual(a: CleanupRef, b: CleanupRef) bool {
    return switch (a) {
        .defer_ref => |a_ref| switch (b) {
            .defer_ref => |b_ref| sameDeferCleanupRef(a_ref, b_ref),
            .ownership_action => false,
        },
        .ownership_action => |a_ref| switch (b) {
            .defer_ref => false,
            .ownership_action => |b_ref| ownershipCleanupActionRefsEqual(a_ref, b_ref),
        },
    };
}

fn cleanupRefValidForEdge(
    ref: CleanupRef,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
) bool {
    return switch (ref) {
        .defer_ref => |defer_ref| mir.deferCleanupRefValid(function, defer_ref),
        .ownership_action => |action_ref| {
            const concrete_module = module orelse return false;
            const concrete_plan = cleanup_plan orelse return false;
            return mir_ownership_authority.autoDropLocalCleanupFromActionRef(concrete_module, &function, concrete_plan, action_ref) != null or
                mir_ownership_authority.explicitDropLocalCleanupFromActionRef(concrete_module, &function, concrete_plan, action_ref) != null;
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
    return true;
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

test "auto-drop cleanup state removal uses typed local identity" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    var state: CleanupState = .{};
    defer state.deinit(std.testing.allocator);

    const root_old = mir.ValueId.fromIndex(1);
    const root_shadow = mir.ValueId.fromIndex(2);
    const resource_type = mir.SymbolId.fromIndex(3);
    const drop_glue = mir.SymbolId.fromIndex(4);

    try state.append(std.testing.allocator, .{ .ownership_action = .{ .local_name = "g", .span = span, .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });
    try state.append(std.testing.allocator, .{ .ownership_action = .{ .local_name = "g", .span = span, .cleanup_action_index = 1, .root_value_id = root_shadow, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue } });

    try std.testing.expect(state.removeAutoDrop(.{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
    try std.testing.expectEqual(@as(usize, 1), state.slice().len);
    switch (state.slice()[0]) {
        .ownership_action => |cleanup| try std.testing.expect(cleanup.root_value_id.eql(root_shadow)),
        .defer_ref => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!state.removeAutoDrop(.{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_old, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
    try std.testing.expect(!state.removeAutoDrop(.{ .local_name = "g", .cleanup_action_index = 0, .root_value_id = root_shadow, .resource_type_symbol_id = resource_type, .drop_glue_symbol_id = drop_glue }));
}

test "defer cleanup state refs must be valid ordered and unique" {
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
    var mir_defer_edges = try mir.buildDeferCleanupEdgeTable(std.testing.allocator, function);
    defer mir_defer_edges.deinit(std.testing.allocator);
    try std.testing.expect(mir.deferCleanupEdgeTableValid(function, mir_defer_edges));
    try std.testing.expect(mir_defer_edges.edges.len >= 1);
    const scope_defer_edge = for (mir_defer_edges.edges) |edge| {
        if (edge.kind == .scope_exit) break edge;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), scope_defer_edge.actions.len);
    try std.testing.expectEqual(@as(usize, 1), scope_defer_edge.actions[0].instruction_index);
    try std.testing.expect(mir.deferCleanupEdgeTableContainsRef(mir_defer_edges, second));
    var stale_second = second;
    stale_second.source.column += 1;
    try std.testing.expect(!mir.deferCleanupEdgeTableContainsRef(mir_defer_edges, stale_second));
    var test_cfg_actions = [_]mir.CleanupCfgActionRef{
        .{ .defer_cleanup = scope_defer_edge.actions[0] },
        .{ .defer_cleanup = scope_defer_edge.actions[1] },
    };
    var test_cfg_edges = [_]mir.CleanupCfgEdge{.{
        .kind = .scope_exit,
        .actions = test_cfg_actions[0..],
    }};
    const test_cleanup_cfg: mir.CleanupCfg = .{ .edges = test_cfg_edges[0..] };
    var registration_state: CleanupState = .{};
    defer registration_state.deinit(std.testing.allocator);
    try std.testing.expectEqual(AutoDropStackDecision.rejected, try registerOrdinaryDeferCleanup(std.testing.allocator, &function, null, &registration_state, first));
    try std.testing.expectEqual(AutoDropStackDecision.applied, try registerOrdinaryDeferCleanup(std.testing.allocator, &function, &test_cleanup_cfg, &registration_state, first));
    try std.testing.expectEqual(AutoDropStackDecision.rejected, try registerOrdinaryDeferCleanup(std.testing.allocator, &function, &test_cleanup_cfg, &registration_state, stale_second));

    try std.testing.expect(deferCleanupRefsValid(function, &.{
        .{ .defer_ref = first },
        .{ .defer_ref = second },
    }));
    var admitted_state: CleanupState = .{};
    defer admitted_state.deinit(std.testing.allocator);
    try admitted_state.append(std.testing.allocator, .{ .defer_ref = first });
    try admitted_state.append(std.testing.allocator, .{ .defer_ref = second });
    try std.testing.expect(cleanupStateAdmittedByMir(function, &test_cleanup_cfg, &admitted_state));

    var missing_edges_state: CleanupState = .{};
    defer missing_edges_state.deinit(std.testing.allocator);
    try missing_edges_state.append(std.testing.allocator, .{ .defer_ref = first });
    try std.testing.expect(!cleanupStateAdmittedByMir(function, null, &missing_edges_state));
    try std.testing.expect(!deferCleanupRefsValid(function, &.{
        .{ .defer_ref = second },
        .{ .defer_ref = first },
    }));
    try std.testing.expect(!deferCleanupRefsValid(function, &.{
        .{ .defer_ref = first },
        .{ .defer_ref = first },
    }));

    var state: CleanupState = .{};
    defer state.deinit(std.testing.allocator);
    try state.append(std.testing.allocator, .{ .defer_ref = first });
    try state.append(std.testing.allocator, .{ .defer_ref = second });
    try std.testing.expectEqual(@as(?usize, 2), deferCleanupEmissionCount(state.slice(), 0));
    const first_emit = cleanupRefAtEmissionIndex(function, state.slice(), 0, 0) orelse return error.TestUnexpectedResult;
    const second_emit = cleanupRefAtEmissionIndex(function, state.slice(), 0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_emit.defer_ref.instruction_index == 1);
    try std.testing.expect(second_emit.defer_ref.instruction_index == 0);
    try std.testing.expect(cleanupRefAtEmissionIndex(function, state.slice(), 0, 2) == null);

    const root_mark = rootCleanupCursor();
    var cleanup_cfg_actions = [_]mir.CleanupCfgActionRef{
        .{ .defer_cleanup = mir_defer_edges.edges[0].actions[0] },
        .{ .defer_cleanup = mir_defer_edges.edges[0].actions[1] },
    };
    var cleanup_cfg_edges = [_]mir.CleanupCfgEdge{.{
        .kind = .return_exit,
        .actions = cleanup_cfg_actions[0..],
    }};
    const cleanup_cfg: mir.CleanupCfg = .{ .edges = cleanup_cfg_edges[0..] };
    var plan = (try buildCleanupEdgePlan(std.testing.allocator, null, function, null, &cleanup_cfg, &state, root_mark, .return_exit)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(CleanupEdgeKind.return_exit, plan.kind);
    try std.testing.expectEqual(@as(usize, 0), cleanupCursorIndex(plan.start));
    try std.testing.expectEqual(@as(usize, 2), plan.refs.len);
    switch (plan.refs[0]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 1),
        .ownership_action => return error.TestUnexpectedResult,
    }
    switch (plan.refs[1]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 0),
        .ownership_action => return error.TestUnexpectedResult,
    }

    var table = (try buildCleanupEdgeTableFromCursor(std.testing.allocator, null, function, null, &cleanup_cfg, &state, root_mark, .return_exit)) orelse return error.TestUnexpectedResult;
    defer table.deinit(std.testing.allocator);
    const edge = cleanupEdgeFor(table, .return_exit, root_mark) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CleanupEdgeKind.return_exit, edge.kind);
    try std.testing.expectEqual(@as(usize, 2), edge.refs.len);
    switch (edge.refs[0]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 1),
        .ownership_action => return error.TestUnexpectedResult,
    }

    var queried_plan = (try cleanupEdgePlanFromTable(std.testing.allocator, table, .return_exit, root_mark)) orelse return error.TestUnexpectedResult;
    defer queried_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), queried_plan.refs.len);
    switch (queried_plan.refs[0]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 1),
        .ownership_action => return error.TestUnexpectedResult,
    }
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
    var state: CleanupState = .{};
    defer state.deinit(std.testing.allocator);
    try state.append(std.testing.allocator, .{ .ownership_action = cleanup_ref });
    const root_mark = rootCleanupCursor();

    try std.testing.expect((try buildCleanupEdgeTableFromCursor(std.testing.allocator, null, function, null, null, &state, root_mark, .scope_exit)) == null);
}

test "cleanup state snapshot restores full contents" {
    const span = ast.Span{ .offset = 1, .len = 1, .line = 1, .column = 1 };
    const later_span = ast.Span{ .offset = 2, .len = 1, .line = 1, .column = 2 };
    const first: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 0, .source = mir.sourcePointFromSpan(span) };
    const second: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 1, .source = mir.sourcePointFromSpan(later_span) };
    const root_mark = rootCleanupCursor();

    var state: CleanupState = .{};
    defer state.deinit(std.testing.allocator);
    try state.append(std.testing.allocator, .{ .defer_ref = first });

    var snapshot = try state.capture(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);

    state.entries.items[0] = .{ .defer_ref = second };
    try state.append(std.testing.allocator, .{ .defer_ref = second });
    state.restore(snapshot);

    try std.testing.expectEqual(@as(usize, 1), state.slice().len);
    try std.testing.expect(state.slice()[0].defer_ref.instruction_index == 0);

    state.restoreToCursor(root_mark);
    try std.testing.expectEqual(@as(usize, 0), state.slice().len);
}
