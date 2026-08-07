const std = @import("std");

const mir = @import("mir.zig");

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

pub const AutoDropLocalRegistrationDecision = enum {
    reject,
    emit_auto_drop_cleanup,
    legacy_cancellable_cleanup,
};

pub fn autoDropLocalRegistrationDecision(
    module: *const mir.Module,
    function: *const mir.Function,
    local_name: []const u8,
    type_name: []const u8,
    drop_fn: []const u8,
) AutoDropLocalRegistrationDecision {
    const root_value_id = valueIdForLocal(function, local_name) orelse return .reject;
    const drop_glue = dropGlueFactFor(module, type_name, drop_fn) orelse return .reject;

    var saw_legacy_cancellable_cleanup = false;
    for (function.ownership_events) |event| {
        if (!simpleOwnershipRootMatches(event.place, root_value_id)) continue;
        if (!event.place.root_type_symbol_id.eql(drop_glue.typed_resource_symbol_id)) continue;
        switch (event.kind) {
            .auto_drop => {
                if (!event.drop_glue_symbol_id.eql(drop_glue.typed_release_symbol_id)) continue;
                return .emit_auto_drop_cleanup;
            },
            // Transitional allowance: path-sensitive cleanup edges are not yet
            // fully represented in MIR. A matching consumption event proves MIR
            // at least owns the local's obligation state. Legacy backend
            // cleanup stacks may create a cancellable stack entry for the
            // transfer/release path, but this is not true auto-drop cleanup
            // authority and is removed once C/LLVM consume MIR cleanup edges
            // directly.
            .move_out, .explicit_drop => saw_legacy_cancellable_cleanup = true,
            else => {},
        }
    }
    return if (saw_legacy_cancellable_cleanup) .legacy_cancellable_cleanup else .reject;
}

pub fn authorizesExplicitDropLocal(
    module: *const mir.Module,
    function: *const mir.Function,
    local_name: []const u8,
    drop_fn: []const u8,
    source: mir.SourcePoint,
) bool {
    const root_value_id = valueIdForLocal(function, local_name) orelse return false;
    const drop_glue = dropGlueFactForReleaseFunction(module, drop_fn) orelse return false;

    for (function.ownership_events) |event| {
        if (event.kind != .explicit_drop) continue;
        if (!simpleOwnershipRootMatches(event.place, root_value_id)) continue;
        if (!sourceMatches(event.source, source)) continue;
        if (!event.place.root_type_symbol_id.eql(drop_glue.typed_resource_symbol_id)) continue;
        if (!event.drop_glue_symbol_id.eql(drop_glue.typed_release_symbol_id)) continue;
        return true;
    }
    return false;
}

pub fn localHasAutoDropOwnershipEvent(
    module: *const mir.Module,
    function: *const mir.Function,
    local_name: []const u8,
) bool {
    const root_value_id = valueIdForLocal(function, local_name) orelse return false;
    for (function.ownership_events) |event| {
        if (!simpleOwnershipRootMatches(event.place, root_value_id)) continue;
        if (!autoDropTypeSymbolHasGlue(module, event.place.root_type_symbol_id)) continue;
        return true;
    }
    return false;
}

pub fn authorizesMoveOutLocalAutoDrop(
    module: *const mir.Module,
    function: *const mir.Function,
    local_name: []const u8,
    source: mir.SourcePoint,
) bool {
    const root_value_id = valueIdForLocal(function, local_name) orelse return false;

    for (function.ownership_events) |event| {
        if (event.kind != .move_out) continue;
        if (!simpleOwnershipRootMatches(event.place, root_value_id)) continue;
        if (!sourceMatches(event.source, source)) continue;
        if (!autoDropTypeSymbolHasGlue(module, event.place.root_type_symbol_id)) continue;
        return true;
    }
    return false;
}

fn sourceMatches(event_source: mir.SourcePoint, expected: mir.SourcePoint) bool {
    if (event_source.line != expected.line or event_source.column != expected.column) return false;
    if (event_source.offset == 0 and event_source.len == 0 and expected.offset == 0 and expected.len == 0) return true;
    return event_source.offset == expected.offset and event_source.len == expected.len;
}

fn dropGlueFactFor(module: *const mir.Module, type_name: []const u8, drop_fn: []const u8) ?mir.DropGlueFact {
    for (module.drop_glue_facts) |fact| {
        if (!std.mem.eql(u8, fact.resource_type, type_name)) continue;
        if (!std.mem.eql(u8, fact.release_fn, drop_fn)) continue;
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

fn autoDropTypeSymbolHasGlue(module: *const mir.Module, type_symbol_id: mir.SymbolId) bool {
    if (!type_symbol_id.isValid()) return false;
    for (module.type_ownership_facts) |fact| {
        if (!fact.typed_type_symbol_id.eql(type_symbol_id)) continue;
        return fact.kind == .affine and fact.drop_glue_symbol_id.isValid();
    }
    return false;
}

fn valueIdForLocal(function: *const mir.Function, local_name: []const u8) ?mir.ValueId {
    for (function.value_identities) |identity| {
        if (std.mem.eql(u8, identity.spelling, local_name)) return identity.id;
    }
    return null;
}

fn simpleOwnershipRootMatches(place: mir.OwnershipPlace, root_value_id: mir.ValueId) bool {
    return place.root_value_id.eql(root_value_id) and
        !place.root_symbol_id.isValid() and
        place.projection_count == 0;
}
