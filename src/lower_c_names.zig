//! C backend generated type-name helpers.
//!
//! These build stable typedef/helper names for aggregate, slice, result,
//! closure, and function-pointer types. They are pure name construction over
//! collected type metadata; C emission stays in `lower_c_emitter.zig`.

const std = @import("std");

const ast = @import("ast.zig");
const lower_c_alias = @import("lower_c_alias.zig");

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
    return signatureTypeName(ctx, "mc_fnptr", node.ret.*, node.params);
}

pub fn closureTypeName(ctx: Context, node: anytype) ![]const u8 {
    return closureTypeNameForTypes(ctx, node.ret.*, node.params);
}

pub fn closureTypeNameForTypes(ctx: Context, ret_ty: ast.TypeExpr, params: []const ast.TypeExpr) ![]const u8 {
    return signatureTypeName(ctx, "mc_closure", ret_ty, params);
}

pub fn closureTypeNameForParams(ctx: Context, ret_ty: ast.TypeExpr, params: []const ast.Param) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "mc_closure");
    try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, ret_ty));
    for (params) |param| {
        try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, param.ty));
    }
    return buf.toOwnedSlice(ctx.allocator);
}

fn signatureTypeName(ctx: Context, prefix: []const u8, ret_ty: ast.TypeExpr, params: []const ast.TypeExpr) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, prefix);
    try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, ret_ty));
    for (params) |param| {
        try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, param));
    }
    return buf.toOwnedSlice(ctx.allocator);
}

pub fn typeSuffix(ctx: Context, ty: ast.TypeExpr) ![]const u8 {
    const resolved_ty = lower_c_alias.resolveAliasType(ctx.type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| if (ctx.structs.contains(name.text))
            std.fmt.allocPrint(ctx.allocator, "mc_type_struct_{d}_{s}", .{ name.text.len, name.text })
        else if (isBuiltinTypeName(name.text))
            name.text
        else
            std.fmt.allocPrint(ctx.allocator, "mc_type_name_{d}_{s}", .{ name.text.len, name.text }),
        .pointer => |node| framedUnary(ctx, "mc_type_ptr", node.mutability, node.child.*),
        .raw_many_pointer => |node| framedUnary(ctx, "mc_type_manyptr", node.mutability, node.child.*),
        .slice => |node| framedUnary(ctx, "mc_type_slice", node.mutability, node.child.*),
        .array => |node| blk: {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(ctx.allocator, "mc_type_array");
            try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, node.child.*));
            try appendFramed(ctx.allocator, &buf, try ctx.array_len_text(ctx.len_ctx, node.len));
            break :blk buf.toOwnedSlice(ctx.allocator);
        },
        .nullable => |child| framedChild(ctx, "mc_type_nullable", child.*),
        .qualified => |node| framedUnary(ctx, "mc_type_qualified", node.mutability, node.child.*),
        .generic => |node| {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(ctx.allocator, "mc_type_generic");
            try appendFramed(ctx.allocator, &buf, node.base.text);
            try buf.print(ctx.allocator, "_{d}", .{node.args.len});
            for (node.args) |arg| try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, arg));
            return buf.toOwnedSlice(ctx.allocator);
        },
        .fn_pointer => |node| fnPtrSuffix(ctx, node),
        .closure_type => |node| signatureTypeName(ctx, "mc_type_closure", node.ret.*, node.params),
        .dyn_trait => |node| std.fmt.allocPrint(ctx.allocator, "mc_type_dyn_{s}_{d}_{s}", .{ mutabilityCode(node.mutability), node.trait_name.text.len, node.trait_name.text }),
        .member => |node| blk: {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(ctx.allocator, "mc_type_member");
            try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, node.base.*));
            try appendFramed(ctx.allocator, &buf, node.field.text);
            break :blk buf.toOwnedSlice(ctx.allocator);
        },
        .enum_literal => |literal| std.fmt.allocPrint(ctx.allocator, "mc_type_enum_{d}_{s}", .{ literal.text.len, literal.text }),
    };
}

fn fnPtrSuffix(ctx: Context, node: anytype) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "mc_type_fnptr");
    try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, node.ret.*));
    for (node.params) |param| try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, param));
    return buf.toOwnedSlice(ctx.allocator);
}

fn framedChild(ctx: Context, prefix: []const u8, child: ast.TypeExpr) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, prefix);
    try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, child));
    return buf.toOwnedSlice(ctx.allocator);
}

fn framedUnary(ctx: Context, prefix: []const u8, mutability: ast.Mutability, child: ast.TypeExpr) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(ctx.allocator, "{s}_{s}", .{ prefix, mutabilityCode(mutability) });
    try appendFramed(ctx.allocator, &buf, try typeSuffix(ctx, child));
    return buf.toOwnedSlice(ctx.allocator);
}

fn appendFramed(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    try buf.print(allocator, "_{d}_{s}", .{ value.len, value });
}

fn mutabilityCode(mutability: ast.Mutability) []const u8 {
    return switch (mutability) {
        .none => "n",
        .mut => "m",
        .@"const" => "c",
    };
}

fn isBuiltinTypeName(name: []const u8) bool {
    const names = [_][]const u8{
        "void",            "never",    "bool",    "u8",      "u16",    "u32",   "u64",   "u128",                 "usize",
        "i8",              "i16",      "i32",     "i64",     "i128",   "isize", "f32",   "f64",                  "cstr",
        "c_void",          "PAddr",    "VAddr",   "DmaAddr", "IrqOff", "Order", "Error", "AmbiguousSerialOrder", "AmbiguousCounterInterval",
        "ConversionError", "Overflow", "va_list",
    };
    for (names) |builtin| if (std.mem.eql(u8, name, builtin)) return true;
    return false;
}
