const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

pub const AutoDropCleanup = struct {
    fn_name: []const u8,
    local_name: []const u8,
};

/// Extract the canonical resource type name from the narrow `#[drop]` ABI:
///
///     #[drop] fn release(x: *mut T) -> void
///
/// Shape validation (exactly one parameter, non-variadic, runtime parameter,
/// void return, checked-resource eligibility, duplicate glue) belongs to sema.
/// This helper is shared so sema and both backends agree on the type identity
/// carried by the first `*mut T` parameter.
pub fn dropPointerReleaseParamTypeName(fn_decl: ast.FnDecl) ?[]const u8 {
    if (fn_decl.params.len == 0) return null;
    const first = fn_decl.params[0].ty;
    const child = switch (first.kind) {
        .pointer => |p| blk: {
            if (p.mutability != .mut) return null;
            break :blk p.child.*;
        },
        else => return null,
    };
    return leadingTypeName(child);
}

/// Backend-side auto-drop eligibility for concrete AST struct declarations.
/// Sema remains the authority that validates unique `#[drop]` glue; this helper
/// prevents C and LLVM from drifting while deciding whether a validated drop
/// function should be registered for lexical auto-drop emission.
pub fn autoDropEligibleTypeName(
    type_name: []const u8,
    structs: *const std.StringHashMap(ast.StructDecl),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) bool {
    const decl = structs.get(type_name) orelse return false;
    if (decl.is_linear) return false;
    if (decl.is_move) return true;
    const self_ty = ast.TypeExpr{ .span = decl.name.span, .kind = .{ .name = decl.name } };
    return typeEmbedsMoveByValue(self_ty, structs, aliases, 0) and
        !typeEmbedsLinearByValue(self_ty, structs, aliases, 0);
}

pub fn dropGlueDeclMatches(
    resource_type: []const u8,
    release_fn: []const u8,
    fn_decl: ast.FnDecl,
    attrs: []const ast.Attr,
    is_extern: bool,
    structs: *const std.StringHashMap(ast.StructDecl),
    aliases: *const std.StringHashMap(ast.TypeExpr),
) bool {
    if (is_extern) return false;
    if (!std.mem.eql(u8, fn_decl.name.text, release_fn)) return false;
    if (!hasNamedAttr(attrs, "drop")) return false;
    const declared_resource = dropPointerReleaseParamTypeName(fn_decl) orelse return false;
    if (!std.mem.eql(u8, declared_resource, resource_type)) return false;
    return autoDropEligibleTypeName(declared_resource, structs, aliases);
}

pub fn autoDropPointerCleanup(expr: ast.Expr, auto_drop_fns_by_type: *const std.StringHashMap([]const u8)) ?AutoDropCleanup {
    const call = switch (expr.kind) {
        .call => |node| node,
        else => return null,
    };
    const fn_name = ast_query.calleeIdentName(call.callee.*) orelse return null;
    if (!autoDropReleaseFunctionName(fn_name, auto_drop_fns_by_type)) return null;
    if (call.args.len != 1) return null;
    const local_name = addressOfIdentName(call.args[0]) orelse return null;
    return .{ .fn_name = fn_name, .local_name = local_name };
}

pub fn addressOfIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| addressOfIdentName(inner.*),
        .address_of => |inner| switch (inner.kind) {
            .grouped => addressOfIdentName(inner.*),
            .ident => |ident| ident.text,
            else => null,
        },
        else => null,
    };
}

pub fn typeEmbedsMoveByValue(
    ty: ast.TypeExpr,
    structs: *const std.StringHashMap(ast.StructDecl),
    aliases: *const std.StringHashMap(ast.TypeExpr),
    depth: usize,
) bool {
    if (depth >= 64) return true;
    return switch (ty.kind) {
        .name => |n| blk: {
            if (aliases.get(n.text)) |target| break :blk typeEmbedsMoveByValue(target, structs, aliases, depth + 1);
            const decl = structs.get(n.text) orelse break :blk false;
            if (decl.is_move) break :blk true;
            for (decl.fields) |field| if (typeEmbedsMoveByValue(field.ty, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .generic => |g| blk: {
            if (structs.get(g.base.text)) |decl| if (decl.is_move) break :blk true;
            for (g.args) |arg| if (typeEmbedsMoveByValue(arg, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .array => |node| typeEmbedsMoveByValue(node.child.*, structs, aliases, depth + 1),
        .qualified => |node| typeEmbedsMoveByValue(node.child.*, structs, aliases, depth + 1),
        .nullable => |child| typeEmbedsMoveByValue(child.*, structs, aliases, depth + 1),
        else => false,
    };
}

pub fn typeEmbedsLinearByValue(
    ty: ast.TypeExpr,
    structs: *const std.StringHashMap(ast.StructDecl),
    aliases: *const std.StringHashMap(ast.TypeExpr),
    depth: usize,
) bool {
    if (depth >= 64) return true;
    return switch (ty.kind) {
        .name => |n| blk: {
            if (aliases.get(n.text)) |target| break :blk typeEmbedsLinearByValue(target, structs, aliases, depth + 1);
            const decl = structs.get(n.text) orelse break :blk false;
            if (decl.is_linear) break :blk true;
            for (decl.fields) |field| if (typeEmbedsLinearByValue(field.ty, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .generic => |g| blk: {
            if (structs.get(g.base.text)) |decl| if (decl.is_linear) break :blk true;
            for (g.args) |arg| if (typeEmbedsLinearByValue(arg, structs, aliases, depth + 1)) break :blk true;
            break :blk false;
        },
        .array => |node| typeEmbedsLinearByValue(node.child.*, structs, aliases, depth + 1),
        .qualified => |node| typeEmbedsLinearByValue(node.child.*, structs, aliases, depth + 1),
        .nullable => |child| typeEmbedsLinearByValue(child.*, structs, aliases, depth + 1),
        else => false,
    };
}

fn leadingTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .generic => |g| g.base.text,
        else => ast_query.typeName(ty),
    };
}

fn autoDropReleaseFunctionName(name: []const u8, auto_drop_fns_by_type: *const std.StringHashMap([]const u8)) bool {
    var it = auto_drop_fns_by_type.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, name)) return true;
    }
    return false;
}

fn hasNamedAttr(attrs: []const ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .named => |id| if (std.mem.eql(u8, id.text, name)) return true,
        else => {},
    };
    return false;
}

test "drop pointer release parameter accepts named and generic mut pointers only" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    const name_t = ast.Ident{ .text = "Wrapper", .span = span };
    var arg_t = ast.TypeExpr{ .span = span, .kind = .{ .generic = .{
        .base = name_t,
        .args = &.{},
    } } };
    const ptr_t = ast.TypeExpr{ .span = span, .kind = .{ .pointer = .{
        .mutability = .mut,
        .child = &arg_t,
    } } };
    const param = ast.Param{ .name = .{ .text = "x", .span = span }, .ty = ptr_t };
    var params = [_]ast.Param{param};
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "release", .span = span },
        .abi = null,
        .params = params[0..],
        .return_type = null,
        .body = null,
        .is_const = false,
    };

    try std.testing.expectEqualStrings("Wrapper", dropPointerReleaseParamTypeName(fn_decl).?);
}

test "drop glue declaration matching centralizes attr ABI and eligibility checks" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    const guard_ident = ast.Ident{ .text = "Guard", .span = span };
    var guard_ty = ast.TypeExpr{ .span = span, .kind = .{ .name = guard_ident } };
    const ptr_guard_ty = ast.TypeExpr{ .span = span, .kind = .{ .pointer = .{
        .mutability = .mut,
        .child = &guard_ty,
    } } };
    const param = ast.Param{ .name = .{ .text = "g", .span = span }, .ty = ptr_guard_ty };
    var params = [_]ast.Param{param};
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "close_guard", .span = span },
        .abi = null,
        .params = params[0..],
        .return_type = null,
        .body = null,
        .is_const = false,
    };
    const drop_attr = ast.Attr{ .span = span, .kind = .{ .named = .{ .text = "drop", .span = span } } };
    var attrs = [_]ast.Attr{drop_attr};

    var structs = std.StringHashMap(ast.StructDecl).init(std.testing.allocator);
    defer structs.deinit();
    try structs.put("Guard", .{
        .name = guard_ident,
        .abi = null,
        .fields = &.{},
        .is_move = true,
    });
    var aliases = std.StringHashMap(ast.TypeExpr).init(std.testing.allocator);
    defer aliases.deinit();

    try std.testing.expect(dropGlueDeclMatches("Guard", "close_guard", fn_decl, attrs[0..], false, &structs, &aliases));
    try std.testing.expect(!dropGlueDeclMatches("Other", "close_guard", fn_decl, attrs[0..], false, &structs, &aliases));
    try std.testing.expect(!dropGlueDeclMatches("Guard", "close_guard", fn_decl, &.{}, false, &structs, &aliases));
    try std.testing.expect(!dropGlueDeclMatches("Guard", "close_guard", fn_decl, attrs[0..], true, &structs, &aliases));
}

test "auto-drop cleanup helpers recognize explicit release call shapes" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    var map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    try map.put("Guard", "close_guard");

    const local = ast.Ident{ .text = "g", .span = span };
    const ident = ast.Expr{ .span = span, .kind = .{ .ident = local } };
    const address = ast.Expr{ .span = span, .kind = .{ .address_of = try ast.makePtr(std.testing.allocator, ident) } };
    const args = try std.testing.allocator.dupe(ast.Expr, &[_]ast.Expr{address});
    const call = ast.Expr{
        .span = span,
        .kind = .{ .call = .{
            .callee = try ast.makePtr(std.testing.allocator, ast.Expr{ .span = span, .kind = .{ .ident = .{ .text = "close_guard", .span = span } } }),
            .type_args = &.{},
            .args = args,
        } },
    };
    defer {
        const node = call.kind.call;
        std.testing.allocator.destroy(node.callee);
        std.testing.allocator.destroy(node.args[0].kind.address_of);
        std.testing.allocator.free(node.args);
    }

    const cleanup = autoDropPointerCleanup(call, &map).?;
    try std.testing.expectEqualStrings("close_guard", cleanup.fn_name);
    try std.testing.expectEqualStrings("g", cleanup.local_name);
}
