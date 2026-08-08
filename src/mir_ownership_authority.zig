const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const mir = @import("mir.zig");

pub const FunctionDeclArtifact = struct {
    fn_decl: ast.FnDecl,
    attrs: []const ast.Attr,
    is_extern: bool,
};

pub const AutoDropLocalCleanup = struct {
    fn_name: []const u8,
    local_name: []const u8,
    span: ast.Span,
    root_value_id: mir.ValueId = .invalid,
    resource_type_symbol_id: mir.SymbolId = .invalid,
    drop_glue_symbol_id: mir.SymbolId = .invalid,
    auto_drop_event_index: usize = std.math.maxInt(usize),
    explicit_drop_event_index: usize = std.math.maxInt(usize),
    storage_dead_event_index: usize = std.math.maxInt(usize),
};

pub const AutoDropCleanupKey = struct {
    local_name: []const u8,
    root_value_id: mir.ValueId,
    resource_type_symbol_id: mir.SymbolId = .invalid,
    drop_glue_symbol_id: mir.SymbolId = .invalid,
};

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

pub fn dropGlueDeclMatches(module: *const mir.Module, type_name: []const u8, release_fn: []const u8) bool {
    const drop_glue = dropGlueFactForReleaseFunction(module, release_fn) orelse return false;
    if (!std.mem.eql(u8, drop_glue.resource_type, type_name)) return false;
    return autoDropEligibleTypeNameForDropGlue(module, type_name, drop_glue.typed_release_symbol_id);
}

pub fn dropGlueFactsMatchDeclArtifacts(
    module: *const mir.Module,
    artifacts: []const FunctionDeclArtifact,
) bool {
    for (module.drop_glue_facts) |fact| {
        var matched = false;
        for (artifacts) |artifact| {
            if (!dropGlueDeclArtifactMatches(module, fact, artifact)) continue;
            matched = true;
            break;
        }
        if (!matched) return false;
    }
    return true;
}

fn dropGlueDeclArtifactMatches(
    module: *const mir.Module,
    fact: mir.DropGlueFact,
    artifact: FunctionDeclArtifact,
) bool {
    if (artifact.is_extern) return false;
    if (!std.mem.eql(u8, artifact.fn_decl.name.text, fact.release_fn)) return false;
    if (!hasNamedAttr(artifact.attrs, "drop")) return false;
    const declared_resource = ast_query.dropPointerReleaseParamTypeName(artifact.fn_decl) orelse return false;
    if (!std.mem.eql(u8, declared_resource, fact.resource_type)) return false;
    return dropGlueDeclMatches(module, declared_resource, fact.release_fn);
}

pub const AutoDropLocalRegistrationDecision = union(enum) {
    reject,
    emit_auto_drop_cleanup: AutoDropLocalCleanup,
    skip_cleanup_registration,
};

pub const AutoDropCancellationDecision = union(enum) {
    ignore,
    remove_auto_drop: AutoDropCleanupKey,
    reject,
};

pub const ExplicitDropCleanupDecision = union(enum) {
    ignore,
    emit_explicit_drop_cleanup: AutoDropLocalCleanup,
    reject,
};

pub fn autoDropLocalRegistrationDecision(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    local_name: []const u8,
    type_name: []const u8,
    local_span: ast.Span,
) error{OutOfMemory}!AutoDropLocalRegistrationDecision {
    const root_value_id = valueIdForLocal(function, local_name) orelse return .reject;
    const ownership = typeOwnershipFactFor(module, type_name) orelse return .reject;
    if (ownership.kind != .affine or !ownership.drop_glue_symbol_id.isValid()) return .reject;
    const drop_glue = dropGlueFactForSymbols(module, ownership.typed_type_symbol_id, ownership.drop_glue_symbol_id) orelse return .reject;

    var cleanup_plan: std.ArrayList(mir.CleanupActionPlanEntry) = .empty;
    defer cleanup_plan.deinit(allocator);
    mir.appendOwnershipCleanupPlan(allocator, module.*, function.*, &cleanup_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return .reject,
        error.OutOfMemory => return error.OutOfMemory,
    };

    for (cleanup_plan.items) |entry| {
        if (entry.kind != .auto_drop) continue;
        if (!simpleOwnershipRootMatches(entry.place, root_value_id)) continue;
        if (!entry.place.root_type_symbol_id.eql(ownership.typed_type_symbol_id)) continue;
        if (!entry.drop_glue_symbol_id.eql(ownership.drop_glue_symbol_id)) continue;
        return .{ .emit_auto_drop_cleanup = .{
            .fn_name = drop_glue.release_fn,
            .local_name = local_name,
            .span = local_span,
            .root_value_id = root_value_id,
            .resource_type_symbol_id = ownership.typed_type_symbol_id,
            .drop_glue_symbol_id = ownership.drop_glue_symbol_id,
            .auto_drop_event_index = entry.primary_event_index,
            .storage_dead_event_index = entry.storage_dead_event_index,
        } };
    }
    if (mir.ownershipLocalHasConsumingResourceEvent(function.*, root_value_id, ownership.typed_type_symbol_id)) return .skip_cleanup_registration;
    return .reject;
}

pub fn autoDropCleanupEmissionAllowed(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    cleanup: AutoDropLocalCleanup,
) error{OutOfMemory}!bool {
    if (!cleanup.root_value_id.isValid() or
        !cleanup.resource_type_symbol_id.isValid() or
        !cleanup.drop_glue_symbol_id.isValid() or
        cleanup.auto_drop_event_index == std.math.maxInt(usize) or
        cleanup.storage_dead_event_index == std.math.maxInt(usize))
    {
        return false;
    }
    const local_value_id = valueIdForLocal(function, cleanup.local_name) orelse return false;
    if (!local_value_id.eql(cleanup.root_value_id)) return false;
    const drop_glue = dropGlueFactForSymbols(module, cleanup.resource_type_symbol_id, cleanup.drop_glue_symbol_id) orelse return false;
    if (!std.mem.eql(u8, drop_glue.release_fn, cleanup.fn_name)) return false;

    var cleanup_plan: std.ArrayList(mir.CleanupActionPlanEntry) = .empty;
    defer cleanup_plan.deinit(allocator);
    mir.appendOwnershipCleanupPlan(allocator, module.*, function.*, &cleanup_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };

    for (cleanup_plan.items) |entry| {
        if (entry.kind != .auto_drop) continue;
        if (entry.primary_event_index != cleanup.auto_drop_event_index) continue;
        if (entry.storage_dead_event_index != cleanup.storage_dead_event_index) continue;
        if (!simpleOwnershipRootMatches(entry.place, cleanup.root_value_id)) continue;
        if (!entry.place.root_type_symbol_id.eql(cleanup.resource_type_symbol_id)) continue;
        if (!entry.drop_glue_symbol_id.eql(cleanup.drop_glue_symbol_id)) continue;
        return true;
    }
    return false;
}

fn explicitDropPlanEntryForSource(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    source: mir.SourcePoint,
) error{OutOfMemory}!?mir.CleanupActionPlanEntry {
    var cleanup_plan: std.ArrayList(mir.CleanupActionPlanEntry) = .empty;
    defer cleanup_plan.deinit(allocator);
    mir.appendOwnershipCleanupPlan(allocator, module.*, function.*, &cleanup_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var matched: ?mir.CleanupActionPlanEntry = null;
    for (cleanup_plan.items) |entry| {
        if (entry.kind != .explicit_drop) continue;
        if (!sourceMatches(entry.source, source)) continue;
        if (matched != null) return null;
        matched = entry;
    }
    return matched;
}

fn cleanupCancellationPlanEntryForSource(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    kind: mir.CleanupCancellationKind,
    source: mir.SourcePoint,
) error{OutOfMemory}!?mir.CleanupCancellationPlanEntry {
    var cancellation_plan: std.ArrayList(mir.CleanupCancellationPlanEntry) = .empty;
    defer cancellation_plan.deinit(allocator);
    mir.appendOwnershipCleanupCancellationPlan(allocator, module.*, function.*, &cancellation_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var matched: ?mir.CleanupCancellationPlanEntry = null;
    for (cancellation_plan.items) |entry| {
        if (entry.kind != kind) continue;
        if (!sourceMatches(entry.source, source)) continue;
        if (matched != null) return null;
        matched = entry;
    }
    return matched;
}

pub fn explicitDropLocalCleanup(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    expr: ast.Expr,
) error{OutOfMemory}!?AutoDropLocalCleanup {
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return null;
    const drop_glue = dropGlueFactForReleaseFunction(module, release.fn_name) orelse return null;
    const entry = (try explicitDropPlanEntryForSource(allocator, module, function, mir.sourcePointFromSpan(expr.span))) orelse return null;
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
    cleanup: AutoDropLocalCleanup,
) error{OutOfMemory}!bool {
    if (!cleanup.root_value_id.isValid() or
        !cleanup.resource_type_symbol_id.isValid() or
        !cleanup.drop_glue_symbol_id.isValid() or
        cleanup.explicit_drop_event_index == std.math.maxInt(usize))
    {
        return false;
    }
    const drop_glue = dropGlueFactForSymbols(module, cleanup.resource_type_symbol_id, cleanup.drop_glue_symbol_id) orelse return false;
    if (!std.mem.eql(u8, drop_glue.release_fn, cleanup.fn_name)) return false;
    const local_value_id = valueIdForLocal(function, cleanup.local_name) orelse return false;
    if (!local_value_id.eql(cleanup.root_value_id)) return false;
    var cleanup_plan: std.ArrayList(mir.CleanupActionPlanEntry) = .empty;
    defer cleanup_plan.deinit(allocator);
    mir.appendOwnershipCleanupPlan(allocator, module.*, function.*, &cleanup_plan) catch |err| switch (err) {
        error.InvalidMirOwnershipEvents => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    for (cleanup_plan.items) |entry| {
        if (entry.kind != .explicit_drop) continue;
        if (entry.primary_event_index != cleanup.explicit_drop_event_index) continue;
        if (!simpleOwnershipRootMatches(entry.place, cleanup.root_value_id)) continue;
        if (!sourceMatches(entry.source, mir.sourcePointFromSpan(cleanup.span))) continue;
        if (!entry.place.root_type_symbol_id.eql(cleanup.resource_type_symbol_id)) continue;
        if (!entry.drop_glue_symbol_id.eql(cleanup.drop_glue_symbol_id)) continue;
        return true;
    }
    return false;
}

pub fn deferredExplicitDropCleanupDecision(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    expr: ast.Expr,
) error{OutOfMemory}!ExplicitDropCleanupDecision {
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return .ignore;
    if (dropGlueFactForReleaseFunction(module, release.fn_name) == null) return .ignore;
    const cleanup = (try explicitDropLocalCleanup(allocator, module, function, expr)) orelse return .reject;
    if (!try explicitDropCleanupEmissionAllowed(allocator, module, function, cleanup)) return .reject;
    return .{ .emit_explicit_drop_cleanup = cleanup };
}

pub fn moveAutoDropCancellationDecision(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    expr: ast.Expr,
    move_span: ast.Span,
) error{OutOfMemory}!AutoDropCancellationDecision {
    const source = mir.sourcePointFromSpan(move_span);
    const entry = (try cleanupCancellationPlanEntryForSource(allocator, module, function, .move_out, source)) orelse {
        if (directLocalMoveRootName(expr)) |local_name| {
            if (valueIdForLocal(function, local_name)) |root_value_id| {
                if (mir.ownershipLocalHasAutoDropResourceEvent(module.*, function.*, root_value_id)) return .reject;
            }
        }
        return .ignore;
    };
    if (entry.place.root_symbol_id.isValid() or entry.place.projection_count != 0) return .reject;
    const root_value_id = entry.place.root_value_id;
    const local_name = localNameForValueId(function, root_value_id) orelse return .reject;
    return .{ .remove_auto_drop = .{
        .local_name = local_name,
        .root_value_id = root_value_id,
        .resource_type_symbol_id = entry.place.root_type_symbol_id,
        .drop_glue_symbol_id = entry.drop_glue_symbol_id,
    } };
}

pub fn explicitDropCancellationDecision(
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: *const mir.Function,
    expr: ast.Expr,
) error{OutOfMemory}!AutoDropCancellationDecision {
    const release = ast_query.dropPointerLocalReleaseCall(expr) orelse return .ignore;
    const drop_glue = dropGlueFactForReleaseFunction(module, release.fn_name) orelse return .ignore;
    const entry = (try cleanupCancellationPlanEntryForSource(allocator, module, function, .explicit_drop, mir.sourcePointFromSpan(expr.span))) orelse {
        if (valueIdForLocal(function, release.local_name)) |root_value_id| {
            if (mir.ownershipLocalHasAutoDropResourceEvent(module.*, function.*, root_value_id)) return .reject;
        }
        return .ignore;
    };
    if (entry.place.root_symbol_id.isValid() or entry.place.projection_count != 0) return .reject;
    if (!entry.place.root_type_symbol_id.eql(drop_glue.typed_resource_symbol_id)) return .reject;
    if (!entry.drop_glue_symbol_id.eql(drop_glue.typed_release_symbol_id)) return .reject;
    const root_value_id = entry.place.root_value_id;
    const local_name = localNameForValueId(function, root_value_id) orelse return .reject;
    if (!std.mem.eql(u8, local_name, release.local_name)) return .reject;
    return .{ .remove_auto_drop = .{
        .local_name = local_name,
        .root_value_id = root_value_id,
        .resource_type_symbol_id = entry.place.root_type_symbol_id,
        .drop_glue_symbol_id = entry.drop_glue_symbol_id,
    } };
}

fn sourceMatches(event_source: mir.SourcePoint, expected: mir.SourcePoint) bool {
    if (event_source.line != expected.line or event_source.column != expected.column) return false;
    if (event_source.offset == 0 and event_source.len == 0 and expected.offset == 0 and expected.len == 0) return true;
    return event_source.offset == expected.offset and event_source.len == expected.len;
}

fn typeOwnershipFactFor(module: *const mir.Module, type_name: []const u8) ?mir.TypeOwnershipFact {
    for (module.type_ownership_facts) |fact| {
        if (std.mem.eql(u8, fact.type_name, type_name)) return fact;
    }
    return null;
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

fn directLocalMoveRootName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| directLocalMoveRootName(inner.*),
        .ident => |ident| ident.text,
        else => null,
    };
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
