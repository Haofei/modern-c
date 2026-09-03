const std = @import("std");

const mir = @import("mir.zig");
const mir_ownership_authority = @import("mir_ownership_authority.zig");

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

pub fn validateFunctionCleanupAuthority(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: *const mir.OwnershipCleanupPlan,
    cleanup_cfg: *const mir.CleanupCfg,
) bool {
    for (cleanup_cfg.edges) |edge| {
        for (edge.actions) |action| {
            const ref = cleanupRefFromCleanupCfgAction(function.*, action) orelse return false;
            if (!cleanupRefValidForEdge(ref, module, function.*, cleanup_plan)) return false;
            if (!cleanupCfgContainsRefOnKind(cleanup_cfg.*, edge.kind, ref)) return false;
        }
    }

    for (cleanup_plan.actions, 0..) |action, action_index| {
        switch (action.kind) {
            .auto_drop => {
                if (!cleanupActionHasCfgRef(cleanup_cfg.*, action_index) and
                    !cleanupActionHasCancellation(cleanup_plan.*, action))
                    return false;
            },
            .explicit_drop => {
                if (!action.drop_glue_symbol_id.isValid()) return false;
                if (!action.place.hasValidRoot()) return false;
            },
        }
    }
    return true;
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
            .source = ref.source,
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
    scope_source: ?mir.SourcePoint,
    before_source: ?mir.SourcePoint,
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
            if (!cleanupRefEdgeMatchesQuery(ref, edge, before_source)) continue;
            if (!cleanupRefInQueryScope(ref, scope_source, before_source)) continue;
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

fn cleanupRefEdgeMatchesQuery(ref: CleanupRef, edge: mir.CleanupCfgEdge, before_source: ?mir.SourcePoint) bool {
    switch (ref) {
        .defer_ref => return true,
        .ownership_action => {},
    }
    const query = before_source orelse return true;
    if (edge.source.offset == 0 and edge.source.len == 0 and edge.source.line == 0 and edge.source.column == 0) return true;
    return sourceMatches(edge.source, query);
}

fn cleanupRefsContain(refs: []const CleanupRef, needle: CleanupRef) bool {
    for (refs) |ref| {
        if (cleanupRefEquivalent(ref, needle)) return true;
    }
    return false;
}

fn cleanupActionHasCfgRef(cfg: mir.CleanupCfg, action_index: usize) bool {
    for (cfg.edges) |edge| {
        for (edge.actions) |action| switch (action) {
            .ownership => |ref| if (ref.cleanup_action_index == action_index) return true,
            .defer_cleanup => {},
        };
    }
    return false;
}

fn cleanupActionHasCancellation(plan: mir.OwnershipCleanupPlan, action: mir.CleanupActionPlanEntry) bool {
    for (plan.cancellations) |cancellation| {
        if (cancellation.generation != action.generation) continue;
        if (!cancellation.drop_glue_symbol_id.eql(action.drop_glue_symbol_id)) continue;
        if (!simpleOwnershipPlacesEquivalent(cancellation.place, action.place)) continue;
        return true;
    }
    return false;
}

fn simpleOwnershipPlacesEquivalent(a: mir.OwnershipPlace, b: mir.OwnershipPlace) bool {
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

fn ownershipPlaceProjectionEquivalent(a: mir.OwnershipPlaceProjection, b: mir.OwnershipPlaceProjection) bool {
    return switch (a) {
        .field => |a_field| switch (b) {
            .field => |b_field| a_field.eql(b_field),
            else => false,
        },
        .constant_index => |a_index| switch (b) {
            .constant_index => |b_index| a_index == b_index,
            else => false,
        },
        .wildcard_index => switch (b) {
            .wildcard_index => true,
            else => false,
        },
        .deref => switch (b) {
            .deref => true,
            else => false,
        },
    };
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

fn cleanupRefInQueryScope(ref: CleanupRef, scope_source: ?mir.SourcePoint, before_source: ?mir.SourcePoint) bool {
    const source = cleanupRefSource(ref);
    if (before_source) |limit| {
        if (limit.offset != 0 and source.offset != 0 and source.offset > limit.offset) return false;
    }
    if (scope_source) |scope| {
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
        .ownership_action => |action| action.source,
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
    const span: mir.SourcePoint = .{ .offset = 10, .len = 1, .line = 1, .column = 10 };
    const later_span: mir.SourcePoint = .{ .offset = 20, .len = 1, .line = 1, .column = 20 };
    var instructions = [_]mir.Instruction{
        .{ .kind = .defer_cleanup, .detail = "cleanup", .result_ty = .void, .line = span.line, .column = span.column, .typed_span_id = mir.SpanId.fromIndex(0) },
        .{ .kind = .defer_cleanup, .detail = "cleanup", .result_ty = .void, .line = later_span.line, .column = later_span.column, .typed_span_id = mir.SpanId.fromIndex(1) },
    };
    var span_identities = [_]mir.SpanIdentity{
        .{ .id = mir.SpanId.fromIndex(0), .source = span },
        .{ .id = mir.SpanId.fromIndex(1), .source = later_span },
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
        .span_identities = span_identities[0..],
    };
    const second: mir.DeferCleanupRef = .{ .block_id = mir.BlockId.fromIndex(0), .instruction_index = 1, .source = later_span };
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
