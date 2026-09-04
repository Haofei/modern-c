const std = @import("std");

const ast = @import("ast.zig");
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

pub fn autoDropEligibleTypeName(module: *const mir.Module, type_name: []const u8) bool {
    const type_symbol_id = moduleSymbolIdForSpelling(module, type_name) orelse return false;
    for (module.type_ownership_facts) |fact| {
        if (!fact.typed_type_symbol_id.eql(type_symbol_id)) continue;
        return fact.kind == .affine and fact.drop_glue_symbol_id.isValid();
    }
    return false;
}

pub fn autoDropEligibleTypeNameForDropGlue(module: *const mir.Module, type_name: []const u8, release_symbol_id: mir.SymbolId) bool {
    const type_symbol_id = moduleSymbolIdForSpelling(module, type_name) orelse return false;
    for (module.type_ownership_facts) |fact| {
        if (!fact.typed_type_symbol_id.eql(type_symbol_id)) continue;
        return fact.kind == .affine and fact.drop_glue_symbol_id.isValid() and fact.drop_glue_symbol_id.eql(release_symbol_id);
    }
    return false;
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
    const fn_name = moduleSymbolSpelling(module, drop_glue.typed_release_symbol_id) orelse return null;
    return .{
        .fn_name = fn_name,
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
    const fn_name = moduleSymbolSpelling(module, drop_glue.typed_release_symbol_id) orelse return null;
    return .{
        .fn_name = fn_name,
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
        .column = @intCast(source.column),
    };
}

fn sourceMatches(event_source: mir.SourcePoint, expected: mir.SourcePoint) bool {
    if (event_source.line != expected.line or event_source.column != expected.column) return false;
    if (event_source.offset == 0 and event_source.len == 0 and expected.offset == 0 and expected.len == 0) return true;
    return event_source.offset == expected.offset and event_source.len == expected.len;
}

fn dropGlueFactForSymbols(module: *const mir.Module, resource_symbol_id: mir.SymbolId, release_symbol_id: mir.SymbolId) ?mir.DropGlueFact {
    for (module.drop_glue_facts) |fact| {
        if (!fact.typed_resource_symbol_id.eql(resource_symbol_id)) continue;
        if (!fact.typed_release_symbol_id.eql(release_symbol_id)) continue;
        return fact;
    }
    return null;
}

fn moduleSymbolIdForSpelling(module: *const mir.Module, spelling: []const u8) ?mir.SymbolId {
    for (module.symbol_identities) |identity| {
        if (std.mem.eql(u8, identity.spelling, spelling)) return identity.id;
    }
    return null;
}

fn moduleSymbolSpelling(module: *const mir.Module, symbol_id: mir.SymbolId) ?[]const u8 {
    if (!symbol_id.isValid() or symbol_id.index() >= module.symbol_identities.len) return null;
    const identity = module.symbol_identities[symbol_id.index()];
    if (!identity.id.eql(symbol_id)) return null;
    return identity.spelling;
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
