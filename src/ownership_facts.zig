const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

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
