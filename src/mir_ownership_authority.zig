const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const mir = @import("mir.zig");

pub const AutoDropLocalCleanup = struct {
    fn_name: []const u8,
    local_name: []const u8,
    span: ast.Span,
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

pub fn dropGlueDeclArtifactMatches(
    module: *const mir.Module,
    fact: mir.DropGlueFact,
    fn_decl: ast.FnDecl,
    attrs: []const ast.Attr,
    is_extern: bool,
) bool {
    if (is_extern) return false;
    if (!std.mem.eql(u8, fn_decl.name.text, fact.release_fn)) return false;
    if (!hasNamedAttr(attrs, "drop")) return false;
    const declared_resource = ast_query.dropPointerReleaseParamTypeName(fn_decl) orelse return false;
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
    remove_auto_drop_local: []const u8,
    reject,
};

pub fn autoDropLocalRegistrationDecision(
    module: *const mir.Module,
    function: *const mir.Function,
    local_name: []const u8,
    type_name: []const u8,
    local_span: ast.Span,
) AutoDropLocalRegistrationDecision {
    const root_value_id = valueIdForLocal(function, local_name) orelse return .reject;
    const ownership = typeOwnershipFactFor(module, type_name) orelse return .reject;
    if (ownership.kind != .affine or !ownership.drop_glue_symbol_id.isValid()) return .reject;
    const drop_glue = dropGlueFactForSymbols(module, ownership.typed_type_symbol_id, ownership.drop_glue_symbol_id) orelse return .reject;

    var saw_consuming_event = false;
    for (function.ownership_events) |event| {
        if (!simpleOwnershipRootMatches(event.place, root_value_id)) continue;
        if (!event.place.root_type_symbol_id.eql(ownership.typed_type_symbol_id)) continue;
        switch (event.kind) {
            .auto_drop => {
                if (!event.drop_glue_symbol_id.eql(ownership.drop_glue_symbol_id)) continue;
                return .{ .emit_auto_drop_cleanup = .{
                    .fn_name = drop_glue.release_fn,
                    .local_name = local_name,
                    .span = local_span,
                } };
            },
            .move_out, .explicit_drop => saw_consuming_event = true,
            else => {},
        }
    }
    if (saw_consuming_event) return .skip_cleanup_registration;
    return .reject;
}

fn authorizesExplicitDropLocal(
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

pub fn explicitDropLocalCleanup(module: *const mir.Module, expr: ast.Expr) ?AutoDropLocalCleanup {
    const call = switch (expr.kind) {
        .call => |node| node,
        else => return null,
    };
    const fn_name = ast_query.calleeIdentName(call.callee.*) orelse return null;
    _ = dropGlueFactForReleaseFunction(module, fn_name) orelse return null;
    if (call.args.len != 1) return null;
    const local_name = ast_query.addressOfIdentName(call.args[0]) orelse return null;
    return .{ .fn_name = fn_name, .local_name = local_name, .span = expr.span };
}

pub fn moveAutoDropCancellationDecision(
    module: *const mir.Module,
    function: *const mir.Function,
    expr: ast.Expr,
    move_span: ast.Span,
) AutoDropCancellationDecision {
    const local_name = directMovedLocalName(expr) orelse return .ignore;
    const source = mir.sourcePointFromSpan(move_span);
    if (authorizesMoveOutLocalAutoDrop(module, function, local_name, source)) return .{ .remove_auto_drop_local = local_name };
    if (localHasAutoDropOwnershipEvent(module, function, local_name)) return .reject;
    return .ignore;
}

pub fn explicitDropCancellationDecision(
    module: *const mir.Module,
    function: *const mir.Function,
    expr: ast.Expr,
) AutoDropCancellationDecision {
    const release = explicitDropLocalCleanup(module, expr) orelse return .ignore;
    if (authorizesExplicitDropLocal(module, function, release.local_name, release.fn_name, mir.sourcePointFromSpan(expr.span))) return .{ .remove_auto_drop_local = release.local_name };
    if (localHasAutoDropOwnershipEvent(module, function, release.local_name)) return .reject;
    return .ignore;
}

fn localHasAutoDropOwnershipEvent(
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

fn authorizesMoveOutLocalAutoDrop(
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

fn hasNamedAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .named => |id| if (std.mem.eql(u8, id.text, name)) return true,
        else => {},
    };
    return false;
}

/// Transitional backend cleanup cancellation accepts only direct local moves.
/// MIR remains the authority for whether that syntax is allowed to cancel a
/// drop obligation; this helper only keeps the source-shape boundary shared
/// while C/LLVM still maintain legacy cleanup stacks.
fn directMovedLocalName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| directMovedLocalName(inner.*),
        .ident => |ident| ident.text,
        else => null,
    };
}

test "direct moved local name recognizes only grouped identifiers" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    var ident_expr = ast.Expr{ .span = span, .kind = .{ .ident = .{ .text = "guard", .span = span } } };
    const grouped_expr = ast.Expr{ .span = span, .kind = .{ .grouped = &ident_expr } };
    const literal_expr = ast.Expr{ .span = span, .kind = .{ .int_literal = "1" } };
    const deref_expr = ast.Expr{ .span = span, .kind = .{ .deref = &ident_expr } };

    try std.testing.expectEqualStrings("guard", directMovedLocalName(ident_expr).?);
    try std.testing.expectEqualStrings("guard", directMovedLocalName(grouped_expr).?);
    try std.testing.expect(directMovedLocalName(literal_expr) == null);
    try std.testing.expect(directMovedLocalName(deref_expr) == null);
}
