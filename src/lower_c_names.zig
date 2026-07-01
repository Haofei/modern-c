//! C backend generated type-name helpers.
//!
//! These build stable typedef/helper names for aggregate, slice, result,
//! closure, and function-pointer types. They are pure name construction over
//! collected type metadata; C emission stays in `lower_c_emitter.zig`.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");

const typeName = ast_query.typeName;

pub const ArrayLenTextFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror![]const u8;

pub const Context = struct {
    allocator: std.mem.Allocator,
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    structs: *const std.StringHashMap(ast.StructDecl),
    len_ctx: *anyopaque,
    array_len_text: ArrayLenTextFn,
};

pub fn sliceTypeName(ctx: Context, child: ast.TypeExpr, mutability: ast.Mutability) ![]const u8 {
    const prefix = if (mutability == .mut) "mc_slice_mut_" else "mc_slice_const_";
    return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, try typeSuffix(ctx, child) });
}

pub fn arrayTypeName(ctx: Context, child: ast.TypeExpr, len_expr: ast.Expr) ![]const u8 {
    const len = try ctx.array_len_text(ctx.len_ctx, len_expr);
    return std.fmt.allocPrint(ctx.allocator, "mc_array_{s}_{s}", .{ try typeSuffix(ctx, child), len });
}

pub fn resultTypeName(ctx: Context, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) ![]const u8 {
    return std.fmt.allocPrint(ctx.allocator, "mc_result_{s}_{s}", .{ try typeSuffix(ctx, ok_ty), try typeSuffix(ctx, err_ty) });
}

// Value optional `?T` (tagged repr `{ present, value }`) — one typedef per payload type.
pub fn optTypeName(ctx: Context, payload: ast.TypeExpr) ![]const u8 {
    return std.fmt.allocPrint(ctx.allocator, "mc_opt_{s}", .{try typeSuffix(ctx, payload)});
}

pub fn fnPtrTypeName(ctx: Context, node: anytype) ![]const u8 {
    return signatureTypeName(ctx, "mc_fnptr_", node.ret.*, node.params);
}

pub fn closureTypeName(ctx: Context, node: anytype) ![]const u8 {
    return closureTypeNameForTypes(ctx, node.ret.*, node.params);
}

pub fn closureTypeNameForTypes(ctx: Context, ret_ty: ast.TypeExpr, params: []const ast.TypeExpr) ![]const u8 {
    return signatureTypeName(ctx, "mc_closure_", ret_ty, params);
}

pub fn closureTypeNameForParams(ctx: Context, ret_ty: ast.TypeExpr, params: []const ast.Param) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "mc_closure_");
    try buf.appendSlice(ctx.allocator, try typeSuffix(ctx, ret_ty));
    for (params) |param| {
        try buf.append(ctx.allocator, '_');
        try buf.appendSlice(ctx.allocator, try typeSuffix(ctx, param.ty));
    }
    return buf.toOwnedSlice(ctx.allocator);
}

fn signatureTypeName(ctx: Context, prefix: []const u8, ret_ty: ast.TypeExpr, params: []const ast.TypeExpr) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, prefix);
    try buf.appendSlice(ctx.allocator, try typeSuffix(ctx, ret_ty));
    for (params) |param| {
        try buf.append(ctx.allocator, '_');
        try buf.appendSlice(ctx.allocator, try typeSuffix(ctx, param));
    }
    return buf.toOwnedSlice(ctx.allocator);
}

pub fn typeSuffix(ctx: Context, ty: ast.TypeExpr) ![]const u8 {
    const resolved_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, ty);
    if (typeName(resolved_ty)) |name| {
        if (ctx.structs.contains(name)) return std.fmt.allocPrint(ctx.allocator, "struct_{s}", .{name});
        return name;
    }
    return switch (resolved_ty.kind) {
        .pointer => |node| std.fmt.allocPrint(ctx.allocator, "ptr_{s}", .{try typeSuffix(ctx, node.child.*)}),
        .raw_many_pointer => |node| std.fmt.allocPrint(ctx.allocator, "manyptr_{s}", .{try typeSuffix(ctx, node.child.*)}),
        .slice => |node| std.fmt.allocPrint(ctx.allocator, "slice_{s}", .{try typeSuffix(ctx, node.child.*)}),
        .array => |node| std.fmt.allocPrint(ctx.allocator, "array_{s}_{s}", .{ try typeSuffix(ctx, node.child.*), try ctx.array_len_text(ctx.len_ctx, node.len) }),
        .nullable => |child| std.fmt.allocPrint(ctx.allocator, "nullable_{s}", .{try typeSuffix(ctx, child.*)}),
        .qualified => |node| typeSuffix(ctx, node.child.*),
        .generic => |node| {
            if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                return std.fmt.allocPrint(ctx.allocator, "result_{s}_{s}", .{ try typeSuffix(ctx, node.args[0]), try typeSuffix(ctx, node.args[1]) });
            }
            return node.base.text;
        },
        .fn_pointer => |node| fnPtrSuffix(ctx, node),
        else => "unknown",
    };
}

fn fnPtrSuffix(ctx: Context, node: anytype) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "fnptr_");
    try buf.appendSlice(ctx.allocator, try typeSuffix(ctx, node.ret.*));
    for (node.params) |param| {
        try buf.append(ctx.allocator, '_');
        try buf.appendSlice(ctx.allocator, try typeSuffix(ctx, param));
    }
    return buf.toOwnedSlice(ctx.allocator);
}
