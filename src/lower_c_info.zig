//! C backend state-aware type info builders.
//!
//! These helpers construct `LocalInfo`/`GlobalInfo` records that need emitter
//! state such as aliases, enum reprs, emitted C type spelling, and array length
//! text. The emitter supplies only the formatting callbacks; the classification
//! logic lives here.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const lower_c_alias = @import("lower_c_alias.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");

const GlobalElementInfo = lower_c_model.GlobalElementInfo;
const GlobalInfo = lower_c_model.GlobalInfo;
const FnInfo = lower_c_model.FnInfo;
const LocalInfo = lower_c_model.LocalInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const StructTypeStyle = lower_c_model.StructTypeStyle;
const arrayElementType = lower_c_shape.arrayElementType;
const isPointerLikeGlobalType = lower_c_shape.isPointerLikeGlobalType;
const primitiveCTypeName = lower_c_type.primitiveCTypeName;
const intTypeRange = lower_c_type.intTypeRange;
const isOpaqueAddressTypeName = ast_query.isOpaqueAddressTypeName;
const mmioPointee = ast_query.mmioPointee;
const mmioMapCallPayloadType = ast_query.mmioMapCallPayloadType;
const calleeIdentName = ast_query.calleeIdentName;
const typeName = ast_query.typeName;
const widthBits = lower_c_op.widthBits;

pub const CTypeForFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr, style: StructTypeStyle) anyerror![]const u8;
pub const ArrayLenTextForExprFn = *const fn (ctx: *anyopaque, expr: ast.Expr) anyerror![]const u8;

pub const Context = struct {
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    functions: *const std.StringHashMap(FnInfo),
    structs: *const std.StringHashMap(ast.StructDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    enums: *const std.StringHashMap(ast.EnumDecl),
    emit_ctx: *anyopaque,
    c_type_for: CTypeForFn,
    array_len_text_for_expr: ArrayLenTextForExprFn,
};

pub fn localInfoFromType(ctx: Context, ty: ast.TypeExpr) anyerror!LocalInfo {
    const resolved_ty = resolveAliasType(ctx, ty);
    const source_type_name = typeName(resolved_ty);
    const mmio_pointee = mmioPointee(resolved_ty);
    return switch (resolved_ty.kind) {
        .array => |node| .{
            .source_ty = resolved_ty,
            .c_type = try cTypeFor(ctx, resolved_ty),
            .source_type_name = source_type_name,
            .array_len = try ctx.array_len_text_for_expr(ctx.emit_ctx, node.len),
            .array_elems_field = "elems",
            .iterable_element_c_type = try cTypeFor(ctx, node.child.*),
            .mmio_pointee = mmio_pointee,
        },
        .slice => |node| .{
            .source_ty = resolved_ty,
            .c_type = try cTypeFor(ctx, resolved_ty),
            .source_type_name = source_type_name,
            .slice_ptr_field = "ptr",
            .slice_len_field = "len",
            .iterable_element_c_type = try cTypeFor(ctx, node.child.*),
            .mmio_pointee = mmio_pointee,
        },
        .nullable => |child| .{
            .source_ty = resolved_ty,
            .c_type = try cTypeFor(ctx, resolved_ty),
            .source_type_name = source_type_name,
            .nullable_inner_c_type = try nullableInnerCType(ctx, child.*),
            .mmio_pointee = mmio_pointee,
        },
        .generic => |node| .{
            .source_ty = resolved_ty,
            .c_type = try cTypeFor(ctx, resolved_ty),
            .source_type_name = source_type_name,
            .result_ty = if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) resolved_ty else null,
            .result_ok_c_type = if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) try cTypeFor(ctx, node.args[0]) else null,
            .result_err_c_type = if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) try cTypeFor(ctx, node.args[1]) else null,
            .mmio_pointee = mmio_pointee,
        },
        else => .{
            .source_ty = resolved_ty,
            .c_type = try cTypeFor(ctx, resolved_ty),
            .source_type_name = source_type_name,
            .mmio_pointee = mmio_pointee,
        },
    };
}

pub fn globalInfoFromType(ctx: Context, ty: ast.TypeExpr) anyerror!GlobalInfo {
    const resolved_ty = resolveAliasType(ctx, ty);
    const name = typeName(resolved_ty) orelse "unknown";
    const c_type = try cTypeFor(ctx, resolved_ty);
    if (arrayElementType(resolved_ty)) |element_ty| {
        const element_info = try globalElementInfoFromType(ctx, element_ty);
        return .{
            .type_name = name,
            .c_type = c_type,
            .race_type_name = name,
            .race_c_type = c_type,
            .width_bits = widthBits(name),
            .pointer_like = false,
            .aggregate = true,
            .source_ty = resolved_ty,
            .array_element_info = element_info,
            .array_len = try arrayLenText(ctx, resolved_ty),
        };
    }
    if (resolved_ty.kind == .closure_type) {
        return .{
            .type_name = name,
            .c_type = c_type,
            .race_type_name = name,
            .race_c_type = c_type,
            .width_bits = widthBits(name),
            .pointer_like = false,
            .aggregate = true,
            .source_ty = resolved_ty,
        };
    }
    if (resolved_ty.kind == .fn_pointer) {
        return .{
            .type_name = name,
            .c_type = c_type,
            .race_type_name = name,
            .race_c_type = c_type,
            .width_bits = widthBits(name),
            .pointer_like = true,
            .source_ty = resolved_ty,
        };
    }
    if (ctx.enums.get(name)) |enum_decl| {
        if (enum_decl.repr) |repr| {
            const repr_name = typeName(repr) orelse name;
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = repr_name,
                .race_c_type = try cTypeFor(ctx, repr),
                .width_bits = widthBits(repr_name),
                .pointer_like = false,
                .source_ty = resolved_ty,
            };
        }
        return .{
            .type_name = name,
            .c_type = c_type,
            .race_type_name = "isize",
            .race_c_type = "intptr_t",
            .width_bits = widthBits("isize"),
            .pointer_like = false,
            .source_ty = resolved_ty,
        };
    }
    if (ctx.packed_bits.get(name)) |packed_bits| {
        return .{
            .type_name = name,
            .c_type = c_type,
            .race_type_name = packed_bits.repr_name,
            .race_c_type = packed_bits.repr_c_type,
            .width_bits = widthBits(packed_bits.repr_name),
            .pointer_like = false,
            .source_ty = resolved_ty,
        };
    }
    const is_aggregate = isAggregateGlobalType(ctx, resolved_ty);
    if (isOpaqueAddressTypeName(name)) {
        return .{
            .type_name = name,
            .c_type = c_type,
            .race_type_name = "usize",
            .race_c_type = "uintptr_t",
            .width_bits = widthBits("usize"),
            .pointer_like = false,
            .source_ty = resolved_ty,
        };
    }
    if (underlyingIntTypeName(ctx, resolved_ty)) |repr_name| {
        if (!std.mem.eql(u8, repr_name, name)) {
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = repr_name,
                .race_c_type = primitiveCTypeName(repr_name) orelse c_type,
                .width_bits = widthBits(repr_name),
                .pointer_like = false,
                .source_ty = resolved_ty,
            };
        }
    }
    return .{
        .type_name = name,
        .c_type = c_type,
        .race_type_name = name,
        .race_c_type = c_type,
        .width_bits = widthBits(name),
        .pointer_like = !is_aggregate and isPointerLikeGlobalType(resolved_ty),
        .aggregate = is_aggregate,
        .source_ty = resolved_ty,
    };
}

pub fn globalElementInfoFromType(ctx: Context, ty: ast.TypeExpr) anyerror!GlobalElementInfo {
    const resolved_ty = resolveAliasType(ctx, ty);
    const name = typeName(resolved_ty) orelse "unknown";
    const c_type = try cTypeFor(ctx, resolved_ty);
    if (ctx.enums.get(name)) |enum_decl| {
        const repr = enum_decl.repr orelse return .{
            .source_ty = resolved_ty,
            .c_type = c_type,
            .race_type_name = "isize",
            .race_c_type = "intptr_t",
        };
        const repr_name = typeName(repr) orelse name;
        return .{
            .source_ty = resolved_ty,
            .c_type = c_type,
            .race_type_name = repr_name,
            .race_c_type = try cTypeFor(ctx, repr),
        };
    }
    if (ctx.packed_bits.get(name)) |packed_bits| {
        return .{
            .source_ty = resolved_ty,
            .c_type = c_type,
            .race_type_name = packed_bits.repr_name,
            .race_c_type = packed_bits.repr_c_type,
        };
    }
    if (underlyingIntTypeName(ctx, resolved_ty)) |repr_name| {
        if (!std.mem.eql(u8, repr_name, name)) {
            return .{
                .source_ty = resolved_ty,
                .c_type = c_type,
                .race_type_name = repr_name,
                .race_c_type = primitiveCTypeName(repr_name) orelse c_type,
            };
        }
    }
    const is_aggregate = isAggregateGlobalType(ctx, resolved_ty);
    return .{
        .source_ty = resolved_ty,
        .c_type = c_type,
        .race_type_name = name,
        .race_c_type = c_type,
        .aggregate = is_aggregate,
        .pointer_like = !is_aggregate and (isPointerLikeGlobalType(resolved_ty) or resolved_ty.kind == .fn_pointer),
    };
}

pub fn nullableInnerCType(ctx: Context, ty: ast.TypeExpr) anyerror!?[]const u8 {
    const resolved_ty = resolveAliasType(ctx, ty);
    return switch (resolved_ty.kind) {
        .pointer, .raw_many_pointer, .dyn_trait => try cTypeFor(ctx, ty),
        // A value optional's payload: a named value type (scalar/struct/enum/address).
        // `c_void` is only ever a pointer payload, handled above.
        .name => |n| if (std.mem.eql(u8, n.text, "c_void")) null else try cTypeFor(ctx, ty),
        .qualified => |node| try nullableInnerCType(ctx, node.child.*),
        else => null,
    };
}

pub fn nullableInnerCTypeForExpr(ctx: Context, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| blk: {
            const info = locals.get(ident.text) orelse break :blk null;
            break :blk info.nullable_inner_c_type;
        },
        .call => |node| blk: {
            if (mmioMapCallPayloadType(node)) |ty| break :blk try cTypeFor(ctx, ty);
            const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
            const info = ctx.functions.get(fn_name) orelse break :blk null;
            const ret_ty = info.return_type orelse break :blk null;
            break :blk try nullableInnerCTypeForType(ctx, ret_ty);
        },
        .grouped => |inner| try nullableInnerCTypeForExpr(ctx, inner.*, locals),
        else => null,
    };
}

pub fn nullableInnerCTypeForType(ctx: Context, ty: ast.TypeExpr) anyerror!?[]const u8 {
    const resolved_ty = resolveAliasType(ctx, ty);
    return switch (resolved_ty.kind) {
        .nullable => |child| try nullableInnerCType(ctx, child.*),
        .qualified => |node| try nullableInnerCTypeForType(ctx, node.child.*),
        else => null,
    };
}

pub fn isAggregateGlobalType(ctx: Context, ty: ast.TypeExpr) bool {
    const resolved_ty = resolveAliasType(ctx, ty);
    return switch (resolved_ty.kind) {
        .array, .slice, .closure_type => true,
        .generic => |node| {
            if (std.mem.eql(u8, node.base.text, "MaybeUninit") and node.args.len == 1) {
                return isAggregateGlobalType(ctx, node.args[0]);
            }
            return std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2;
        },
        .name => |name| ctx.structs.contains(name.text) or
            ctx.overlay_unions.contains(name.text) or
            ctx.tagged_unions.contains(name.text),
        else => false,
    };
}

pub fn underlyingIntTypeName(ctx: Context, ty: ast.TypeExpr) ?[]const u8 {
    const resolved = resolveAliasType(ctx, ty);
    return switch (resolved.kind) {
        .name => |n| if (intTypeRange(n.text) != null) n.text else null,
        .generic => |g| if ((std.mem.eql(u8, g.base.text, "wrap") or std.mem.eql(u8, g.base.text, "sat") or
            std.mem.eql(u8, g.base.text, "serial") or std.mem.eql(u8, g.base.text, "counter")) and g.args.len == 1)
            underlyingIntTypeName(ctx, g.args[0])
        else
            null,
        .qualified => |q| underlyingIntTypeName(ctx, q.child.*),
        else => null,
    };
}

fn arrayLenText(ctx: Context, ty: ast.TypeExpr) anyerror!?[]const u8 {
    return switch (ty.kind) {
        .array => |node| try ctx.array_len_text_for_expr(ctx.emit_ctx, node.len),
        .qualified => |node| try arrayLenText(ctx, node.child.*),
        else => null,
    };
}

fn cTypeFor(ctx: Context, ty: ast.TypeExpr) anyerror![]const u8 {
    return try ctx.c_type_for(ctx.emit_ctx, ty, .typedef_name);
}

fn resolveAliasType(ctx: Context, ty: ast.TypeExpr) ast.TypeExpr {
    return lower_c_alias.resolveAliasType(ctx.type_aliases, ty);
}
