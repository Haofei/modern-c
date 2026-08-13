const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const mir = @import("mir.zig");

pub const AutoDropLocalCleanup = struct {
    fn_name: []const u8,
    local_name: []const u8,
    span: ast.Span,
    cleanup_action_index: usize = std.math.maxInt(usize),
    root_value_id: mir.ValueId = .invalid,
    resource_type_symbol_id: mir.SymbolId = .invalid,
    drop_glue_symbol_id: mir.SymbolId = .invalid,
    auto_drop_event_index: usize = std.math.maxInt(usize),
    explicit_drop_event_index: usize = std.math.maxInt(usize),
    storage_dead_event_index: usize = std.math.maxInt(usize),
};

pub const OwnershipCleanupActionRef = struct {
    local_name: []const u8,
    source: mir.SourcePoint,
    cleanup_action_index: usize,
    root_value_id: mir.ValueId,
    resource_type_symbol_id: mir.SymbolId,
    drop_glue_symbol_id: mir.SymbolId,
};

pub const OwnershipCleanupRemovalRef = struct {
    local_name: []const u8,
    cleanup_action_index: usize,
    root_value_id: mir.ValueId,
    resource_type_symbol_id: mir.SymbolId,
    drop_glue_symbol_id: mir.SymbolId,
};

pub fn ownershipCleanupActionRef(cleanup: AutoDropLocalCleanup) OwnershipCleanupActionRef {
    return .{
        .local_name = cleanup.local_name,
        .source = mir.sourcePointFromSpan(cleanup.span),
        .cleanup_action_index = cleanup.cleanup_action_index,
        .root_value_id = cleanup.root_value_id,
        .resource_type_symbol_id = cleanup.resource_type_symbol_id,
        .drop_glue_symbol_id = cleanup.drop_glue_symbol_id,
    };
}

pub fn autoDropEligibleTypeName(module: *const mir.Module, type_name: []const u8) bool {
    for (module.type_ownership_facts) |fact| {
        if (!std.mem.eql(u8, fact.type_name, type_name)) continue;
        return fact.kind == .affine and fact.drop_glue_symbol_id.isValid();
    }
    return false;
}

pub fn autoDropEligibleTypeNameForDropGlue(module: *const mir.Module, type_name: []const u8, release_symbol_id: mir.SymbolId) bool {
    for (module.type_ownership_facts) |fact| {
        if (!std.mem.eql(u8, fact.type_name, type_name)) continue;
        return fact.kind == .affine and fact.drop_glue_symbol_id.isValid() and fact.drop_glue_symbol_id.eql(release_symbol_id);
    }
    return false;
}

pub fn autoDropCleanupEmissionAllowed(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup: AutoDropLocalCleanup,
) error{OutOfMemory}!bool {
    if (!cleanup.root_value_id.isValid() or
        !cleanup.resource_type_symbol_id.isValid() or
        !cleanup.drop_glue_symbol_id.isValid() or
        cleanup.cleanup_action_index == std.math.maxInt(usize) or
        cleanup.auto_drop_event_index == std.math.maxInt(usize) or
        cleanup.storage_dead_event_index == std.math.maxInt(usize))
    {
        return false;
    }
    const local_value_id = valueIdForLocal(function, cleanup.local_name) orelse return false;
    if (!local_value_id.eql(cleanup.root_value_id)) return false;
    const drop_glue = dropGlueFactForSymbols(module, cleanup.resource_type_symbol_id, cleanup.drop_glue_symbol_id) orelse return false;
    if (!std.mem.eql(u8, drop_glue.release_fn, cleanup.fn_name)) return false;

    var plan_lease = buildCleanupPlanLease(allocator, module, function, cleanup_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer plan_lease.deinit(allocator);
    const plan = plan_lease.get();

    if (cleanup.cleanup_action_index >= plan.actions.len) return false;
    const entry = plan.actions[cleanup.cleanup_action_index];
    if (entry.kind != .auto_drop) return false;
    if (entry.primary_event_index != cleanup.auto_drop_event_index) return false;
    if (entry.storage_dead_event_index != cleanup.storage_dead_event_index) return false;
    if (!simpleOwnershipRootMatches(entry.place, cleanup.root_value_id)) return false;
    if (!entry.place.root_type_symbol_id.eql(cleanup.resource_type_symbol_id)) return false;
    if (!entry.drop_glue_symbol_id.eql(cleanup.drop_glue_symbol_id)) return false;
    return true;
}

pub fn autoDropLocalCleanupFromActionRef(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: *const mir.OwnershipCleanupPlan,
    ref: OwnershipCleanupActionRef,
) ?AutoDropLocalCleanup {
    if (!ref.root_value_id.isValid() or
        !ref.resource_type_symbol_id.isValid() or
        !ref.drop_glue_symbol_id.isValid() or
        ref.cleanup_action_index == std.math.maxInt(usize) or
        ref.cleanup_action_index >= cleanup_plan.actions.len)
    {
        return null;
    }
    const local_value_id = valueIdForLocal(function, ref.local_name) orelse return null;
    if (!local_value_id.eql(ref.root_value_id)) return null;
    const drop_glue = dropGlueFactForSymbols(module, ref.resource_type_symbol_id, ref.drop_glue_symbol_id) orelse return null;
    const entry = cleanup_plan.actions[ref.cleanup_action_index];
    if (entry.kind != .auto_drop) return null;
    if (!simpleOwnershipRootMatches(entry.place, ref.root_value_id)) return null;
    if (!entry.place.root_type_symbol_id.eql(ref.resource_type_symbol_id)) return null;
    if (!entry.drop_glue_symbol_id.eql(ref.drop_glue_symbol_id)) return null;
    return .{
        .fn_name = drop_glue.release_fn,
        .local_name = ref.local_name,
        .span = spanFromSourcePoint(ref.source),
        .cleanup_action_index = ref.cleanup_action_index,
        .root_value_id = ref.root_value_id,
        .resource_type_symbol_id = ref.resource_type_symbol_id,
        .drop_glue_symbol_id = ref.drop_glue_symbol_id,
        .auto_drop_event_index = entry.primary_event_index,
        .storage_dead_event_index = entry.storage_dead_event_index,
    };
}

const ExplicitDropPlanMatch = struct {
    action_index: usize,
    entry: mir.CleanupActionPlanEntry,
};

fn explicitDropPlanEntryForSource(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    source: mir.SourcePoint,
) error{OutOfMemory}!?ExplicitDropPlanMatch {
    var plan_lease = buildCleanupPlanLease(allocator, module, function, cleanup_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer plan_lease.deinit(allocator);
    const plan = plan_lease.get();

    var matched: ?ExplicitDropPlanMatch = null;
    for (plan.actions, 0..) |entry, action_index| {
        if (entry.kind != .explicit_drop) continue;
        if (!sourceMatches(entry.source, source)) continue;
        if (matched != null) return null;
        matched = .{ .action_index = action_index, .entry = entry };
    }
    return matched;
}

pub fn explicitDropLocalCleanup(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    expr: ast.Expr,
) error{OutOfMemory}!?AutoDropLocalCleanup {
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return null;
    const drop_glue = dropGlueFactForReleaseFunction(module, release.fn_name) orelse return null;
    const match = (try explicitDropPlanEntryForSource(allocator, module, function, cleanup_plan, mir.sourcePointFromSpan(expr.span))) orelse return null;
    const entry = match.entry;
    if (entry.place.root_symbol_id.isValid() or entry.place.projection_count != 0) return null;
    if (!entry.place.root_type_symbol_id.eql(drop_glue.typed_resource_symbol_id)) return null;
    if (!entry.drop_glue_symbol_id.eql(drop_glue.typed_release_symbol_id)) return null;
    const root_value_id = entry.place.root_value_id;
    const local_name = localNameForValueId(function, root_value_id) orelse return null;
    if (!std.mem.eql(u8, local_name, release.local_name)) return null;
    return .{
        .fn_name = release.fn_name,
        .local_name = local_name,
        .span = release.span,
        .cleanup_action_index = match.action_index,
        .root_value_id = root_value_id,
        .resource_type_symbol_id = drop_glue.typed_resource_symbol_id,
        .drop_glue_symbol_id = drop_glue.typed_release_symbol_id,
        .explicit_drop_event_index = entry.primary_event_index,
    };
}

pub fn explicitDropCleanupEmissionAllowed(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
    cleanup: AutoDropLocalCleanup,
) error{OutOfMemory}!bool {
    if (!cleanup.root_value_id.isValid() or
        !cleanup.resource_type_symbol_id.isValid() or
        !cleanup.drop_glue_symbol_id.isValid() or
        cleanup.cleanup_action_index == std.math.maxInt(usize) or
        cleanup.explicit_drop_event_index == std.math.maxInt(usize))
    {
        return false;
    }
    const drop_glue = dropGlueFactForSymbols(module, cleanup.resource_type_symbol_id, cleanup.drop_glue_symbol_id) orelse return false;
    if (!std.mem.eql(u8, drop_glue.release_fn, cleanup.fn_name)) return false;
    const local_value_id = valueIdForLocal(function, cleanup.local_name) orelse return false;
    if (!local_value_id.eql(cleanup.root_value_id)) return false;
    var plan_lease = buildCleanupPlanLease(allocator, module, function, cleanup_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer plan_lease.deinit(allocator);
    const plan = plan_lease.get();
    if (cleanup.cleanup_action_index >= plan.actions.len) return false;
    const entry = plan.actions[cleanup.cleanup_action_index];
    if (entry.kind != .explicit_drop) return false;
    if (entry.primary_event_index != cleanup.explicit_drop_event_index) return false;
    if (!simpleOwnershipRootMatches(entry.place, cleanup.root_value_id)) return false;
    if (!sourceMatches(entry.source, mir.sourcePointFromSpan(cleanup.span))) return false;
    if (!entry.place.root_type_symbol_id.eql(cleanup.resource_type_symbol_id)) return false;
    if (!entry.drop_glue_symbol_id.eql(cleanup.drop_glue_symbol_id)) return false;
    return true;
}

pub fn explicitDropLocalCleanupFromActionRef(
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: *const mir.OwnershipCleanupPlan,
    ref: OwnershipCleanupActionRef,
) ?AutoDropLocalCleanup {
    if (!ref.root_value_id.isValid() or
        !ref.resource_type_symbol_id.isValid() or
        !ref.drop_glue_symbol_id.isValid() or
        ref.cleanup_action_index == std.math.maxInt(usize) or
        ref.cleanup_action_index >= cleanup_plan.actions.len)
    {
        return null;
    }
    const local_value_id = valueIdForLocal(function, ref.local_name) orelse return null;
    if (!local_value_id.eql(ref.root_value_id)) return null;
    const drop_glue = dropGlueFactForSymbols(module, ref.resource_type_symbol_id, ref.drop_glue_symbol_id) orelse return null;
    const entry = cleanup_plan.actions[ref.cleanup_action_index];
    if (entry.kind != .explicit_drop) return null;
    if (!simpleOwnershipRootMatches(entry.place, ref.root_value_id)) return null;
    if (!sourceMatches(entry.source, ref.source)) return null;
    if (!entry.place.root_type_symbol_id.eql(ref.resource_type_symbol_id)) return null;
    if (!entry.drop_glue_symbol_id.eql(ref.drop_glue_symbol_id)) return null;
    return .{
        .fn_name = drop_glue.release_fn,
        .local_name = ref.local_name,
        .span = spanFromSourcePoint(ref.source),
        .cleanup_action_index = ref.cleanup_action_index,
        .root_value_id = ref.root_value_id,
        .resource_type_symbol_id = ref.resource_type_symbol_id,
        .drop_glue_symbol_id = ref.drop_glue_symbol_id,
        .explicit_drop_event_index = entry.primary_event_index,
    };
}

fn spanFromSourcePoint(source: mir.SourcePoint) ast.Span {
    return .{
        .offset = source.offset,
        .len = source.len,
        .line = source.line,
        .column = source.column,
    };
}

fn sourceMatches(event_source: mir.SourcePoint, expected: mir.SourcePoint) bool {
    if (event_source.line != expected.line or event_source.column != expected.column) return false;
    if (event_source.offset == 0 and event_source.len == 0 and expected.offset == 0 and expected.len == 0) return true;
    return event_source.offset == expected.offset and event_source.len == expected.len;
}

const CleanupPlanLease = struct {
    borrowed: ?*const mir.OwnershipCleanupPlan = null,
    owned: ?mir.OwnershipCleanupPlan = null,

    fn get(self: *const CleanupPlanLease) *const mir.OwnershipCleanupPlan {
        if (self.borrowed) |plan| return plan;
        return &self.owned.?;
    }

    fn deinit(self: *CleanupPlanLease, allocator: std.mem.Allocator) void {
        if (self.owned) |plan| plan.deinit(allocator);
        self.* = .{};
    }
};

fn buildCleanupPlanLease(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup_plan: ?*const mir.OwnershipCleanupPlan,
) error{ InvalidMirOwnershipEvents, OutOfMemory }!CleanupPlanLease {
    if (cleanup_plan) |plan| return .{ .borrowed = plan };
    return .{ .owned = try mir.buildOwnershipCleanupPlan(allocator, module.*, function.*) };
}

fn dropGlueFactForSymbols(module: *const mir.Module, resource_symbol_id: mir.SymbolId, release_symbol_id: mir.SymbolId) ?mir.DropGlueFact {
    for (module.drop_glue_facts) |fact| {
        if (!fact.typed_resource_symbol_id.eql(resource_symbol_id)) continue;
        if (!fact.typed_release_symbol_id.eql(release_symbol_id)) continue;
        return fact;
    }
    return null;
}

fn dropGlueFactForReleaseFunction(module: *const mir.Module, drop_fn: []const u8) ?mir.DropGlueFact {
    for (module.drop_glue_facts) |fact| {
        if (std.mem.eql(u8, fact.release_fn, drop_fn)) return fact;
    }
    return null;
}

fn valueIdForLocal(function: *const mir.Function, local_name: []const u8) ?mir.ValueId {
    for (function.value_identities) |identity| {
        if (std.mem.eql(u8, identity.spelling, local_name)) return identity.id;
    }
    return null;
}

fn localNameForValueId(function: *const mir.Function, value_id: mir.ValueId) ?[]const u8 {
    for (function.value_identities) |identity| {
        if (identity.id.eql(value_id)) return identity.spelling;
    }
    return null;
}

fn simpleOwnershipRootMatches(place: mir.OwnershipPlace, root_value_id: mir.ValueId) bool {
    return place.root_value_id.eql(root_value_id) and
        !place.root_symbol_id.isValid() and
        place.projection_count == 0;
}

fn hasNamedAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .named => |id| if (std.mem.eql(u8, id.text, name)) return true,
        else => {},
    };
    return false;
}
