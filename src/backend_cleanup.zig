const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const mir = @import("mir.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");

/// Backend cleanup payload admitted by MIR cleanup facts.
///
/// C and LLVM lowering keep backend-specific expression payloads here, but all
/// cleanup registration, cancellation, and exit-edge emission is routed through
/// MIR cleanup CFG actions. Backends must not make cleanup lifetime decisions
/// from source syntax alone.
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

pub const CleanupEdgePlan = struct {
    kind: CleanupEdgeKind,
    refs: []CleanupRef,

    pub fn deinit(self: *CleanupEdgePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.refs);
        self.refs = &.{};
    }
};

pub fn registerAutoDropLocalCleanup(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup_cfg: ?*const mir.CleanupCfg,
    local_name: []const u8,
    type_name: []const u8,
    local_span: ast.Span,
) AutoDropStackDecision {
    if (!mir_ownership_authority.autoDropEligibleTypeName(module, type_name)) return .ignored;
    _ = autoDropLocalCleanupFromMirCfg(module, function, cleanup_plan, cleanup_cfg, local_name, type_name, local_span) orelse {
        const ownership = typeOwnershipFactForTypeName(module, type_name) orelse return .rejected;
        const root_value_id = valueIdForLocal(function, local_name) orelse return .rejected;
        if (mir.ownershipLocalHasConsumingResourceEvent(function.*, root_value_id, ownership.typed_type_symbol_id)) return .ignored;
        return .rejected;
    };
    return .applied;
}

pub fn cancelAutoDropForMove(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    expr: ast.Expr,
    move_span: ast.Span,
) AutoDropStackDecision {
    const plan = cleanup_plan orelse return .rejected;
    const source = mir.sourcePointFromSpan(move_span);
    _ = cleanupRemovalRefFromMirCancellation(function, plan, .move_out, source) orelse {
        if (cleanupCancellationEntryFromMirPlan(plan, .move_out, source) != null) return .ignored;
        if (directMoveLocalName(expr)) |local_name| {
            if (localHasConsumingAutoDropResourceEvent(module, function, local_name, .move_out)) return .rejected;
            if (localHasAutoDropCancellationObligation(function, local_name)) return .rejected;
        }
        return .ignored;
    };
    return .applied;
}

pub fn cancelAutoDropForExplicitDrop(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    expr: ast.Expr,
) AutoDropStackDecision {
    const plan = cleanup_plan orelse return .rejected;
    const source = mir.sourcePointFromSpan(expr.span);
    _ = cleanupRemovalRefFromMirCancellation(function, plan, .explicit_drop, source) orelse {
        if (cleanupCancellationEntryFromMirPlan(plan, .explicit_drop, source) != null) return .ignored;
        if (cleanupRemovalRefFromMirExplicitDropAction(function, plan, source)) |action_ref| {
            _ = action_ref;
            return .applied;
        }
        if (explicitDropActionEntryFromMirPlan(plan, source) != null) return .ignored;
        if (ast_query.dropPointerLocalReleaseCall(expr)) |release| {
            if (localHasConsumingAutoDropResourceEvent(module, function, release.local_name, .explicit_drop)) return .rejected;
            if (localHasAutoDropCancellationObligation(function, release.local_name)) return .rejected;
        }
        return .ignored;
    };
    return .applied;
}

pub fn registerDeferredExplicitDropCleanup(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    expr: ast.Expr,
) AutoDropStackDecision {
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return .ignored;
    if (!dropGlueReleaseFunctionExists(module, release.fn_name)) return .ignored;
    _ = explicitDropLocalCleanupFromMirAction(module, function, cleanup_plan, expr) orelse return .rejected;
    return .applied;
}

pub fn registerOrdinaryDeferCleanup(
    function: *const mir.Function,
    cleanup_cfg: ?*const mir.CleanupCfg,
    ref: mir.DeferCleanupRef,
) AutoDropStackDecision {
    const cfg = cleanup_cfg orelse return .rejected;
    if (!cleanupCfgContainsRef(cfg.*, .{ .defer_ref = ref })) return .rejected;
    if (!mir.deferCleanupRefValid(function.*, ref)) return .rejected;
    return .applied;
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

pub fn buildCleanupEdgePlan(
    allocator: std.mem.Allocator,
    module: ?*const mir.Module,
    function: mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup_cfg: ?*const mir.CleanupCfg,
    kind: CleanupEdgeKind,
    scope_span: ?ast.Span,
    before_span: ?ast.Span,
) !?CleanupEdgePlan {
    const cfg = cleanup_cfg orelse return .{
        .kind = kind,
        .refs = &.{},
    };
    var refs: std.ArrayList(CleanupRef) = .empty;
    errdefer refs.deinit(allocator);
    for (cfg.edges) |edge| {
        if (edge.kind != cleanupCfgKindFromBackend(kind)) continue;
        for (edge.actions) |action| {
            const ref = cleanupRefFromCleanupCfgAction(function, action) orelse return null;
            if (!cleanupRefEdgeMatchesQuery(ref, edge, before_span)) continue;
            if (!cleanupRefInQueryScope(ref, scope_span, before_span)) continue;
            if (!cleanupRefValidForEdge(ref, module, function, cleanup_plan)) return null;
            if (!cleanupCfgContainsRefOnKind(cfg.*, cleanupCfgKindFromBackend(kind), ref)) return null;
            if (cleanupRefsContain(refs.items, ref)) continue;
            try refs.append(allocator, ref);
        }
    }
    return .{
        .kind = kind,
        .refs = try refs.toOwnedSlice(allocator),
    };
}

fn cleanupRefEdgeMatchesQuery(ref: CleanupRef, edge: mir.CleanupCfgEdge, before_span: ?ast.Span) bool {
    switch (ref) {
        .defer_ref => return true,
        .ownership_action => {},
    }
    const query = before_span orelse return true;
    if (edge.source.offset == 0 and edge.source.len == 0 and edge.source.line == 0 and edge.source.column == 0) return true;
    return sourceMatches(edge.source, mir.sourcePointFromSpan(query));
}

fn cleanupRefsContain(refs: []const CleanupRef, needle: CleanupRef) bool {
    for (refs) |ref| {
        if (cleanupRefEquivalent(ref, needle)) return true;
    }
    return false;
}

fn cleanupRefEquivalent(a: CleanupRef, b: CleanupRef) bool {
    return switch (a) {
        .defer_ref => |a_ref| switch (b) {
            .defer_ref => |b_ref| a_ref.block_id.eql(b_ref.block_id) and a_ref.instruction_index == b_ref.instruction_index,
            .ownership_action => false,
        },
        .ownership_action => |a_ref| switch (b) {
            .defer_ref => false,
            .ownership_action => |b_ref| a_ref.cleanup_action_index == b_ref.cleanup_action_index and
                a_ref.root_value_id.eql(b_ref.root_value_id) and
                a_ref.resource_type_symbol_id.eql(b_ref.resource_type_symbol_id) and
                a_ref.drop_glue_symbol_id.eql(b_ref.drop_glue_symbol_id),
        },
    };
}

fn cleanupRefInQueryScope(ref: CleanupRef, scope_span: ?ast.Span, before_span: ?ast.Span) bool {
    const source = cleanupRefSource(ref);
    if (before_span) |limit| {
        if (limit.offset != 0 and source.offset != 0 and source.offset > limit.offset) return false;
    }
    if (scope_span) |scope| {
        if (scope.offset != 0 and scope.len != 0 and source.offset != 0) {
            if (source.offset < scope.offset) return false;
            if (source.offset >= scope.offset + scope.len) return false;
        }
    }
    return true;
}

fn cleanupRefSource(ref: CleanupRef) mir.SourcePoint {
    return switch (ref) {
        .defer_ref => |defer_ref| defer_ref.source,
        .ownership_action => |action| mir.sourcePointFromSpan(action.span),
    };
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

test "cleanup edge plan comes directly from MIR cleanup cfg" {
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
    try std.testing.expectEqual(AutoDropStackDecision.rejected, registerOrdinaryDeferCleanup(&function, null, first));
    try std.testing.expectEqual(AutoDropStackDecision.applied, registerOrdinaryDeferCleanup(&function, &test_cleanup_cfg, first));
    try std.testing.expectEqual(AutoDropStackDecision.rejected, registerOrdinaryDeferCleanup(&function, &test_cleanup_cfg, stale_second));

    var cleanup_cfg_actions = [_]mir.CleanupCfgActionRef{
        .{ .defer_cleanup = mir_defer_edges.edges[0].actions[0] },
        .{ .defer_cleanup = mir_defer_edges.edges[0].actions[1] },
    };
    var cleanup_cfg_edges = [_]mir.CleanupCfgEdge{.{
        .kind = .return_exit,
        .actions = cleanup_cfg_actions[0..],
    }};
    const cleanup_cfg: mir.CleanupCfg = .{ .edges = cleanup_cfg_edges[0..] };
    var plan = (try buildCleanupEdgePlan(std.testing.allocator, null, function, null, &cleanup_cfg, .return_exit, null, null)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(CleanupEdgeKind.return_exit, plan.kind);
    try std.testing.expectEqual(@as(usize, 2), plan.refs.len);
    switch (plan.refs[0]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 1),
        .ownership_action => return error.TestUnexpectedResult,
    }
    switch (plan.refs[1]) {
        .defer_ref => |ref| try std.testing.expect(ref.instruction_index == 0),
        .ownership_action => return error.TestUnexpectedResult,
    }
}
