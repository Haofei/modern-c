const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const eval = @import("eval.zig");
const type_layout = @import("layout.zig");
const lower_c_builtin = @import("lower_c_builtin.zig");
const lower_c_const = @import("lower_c_const.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const mir = @import("mir.zig");

const PackedBitsInfo = lower_c_model.PackedBitsInfo;
const OverlayUnionInfo = lower_c_model.OverlayUnionInfo;
const MmioStruct = lower_c_model.MmioStruct;
const ComptimeStructLayout = type_layout.ComptimeStructLayout;
const cTaggedUnionTagSize = lower_c_type.cTaggedUnionTagSize;
const constArrayLenValue = lower_c_const.constArrayLenValue;
const comptimeArraySize = type_layout.comptimeArraySize;
const comptimeBitOffsetFromBytes = type_layout.comptimeBitOffset;
const comptimeTaggedOptionalLayout = type_layout.comptimeTaggedOptionalLayout;
const isArithmeticLayoutGeneric = ast_query.isArithmeticLayoutGeneric;
const isPointerLikeGeneric = ast_query.isPointerLikeGeneric;
const reflectionFieldName = ast_query.reflectionFieldName;
const scalarLayout = type_layout.scalarLayout;
const simpleNameType = ast_query.simpleNameType;
const typeName = ast_query.typeName;

pub const ReflectEnv = struct {
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    structs: *const std.StringHashMap(ast.StructDecl),
    enums: *const std.StringHashMap(ast.EnumDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    const_fns: *const std.StringHashMap(ast.FnDecl),
    const_globals: *const std.StringHashMap(eval.ComptimeValue),
};

pub const CTypeFn = *const fn (ctx: *anyopaque, ty: ast.TypeExpr) anyerror![]const u8;
pub const MirCallTargetKindFn = *const fn (ctx: *anyopaque, span: ast.Span) ?mir.CallTargetKind;
pub const MirTargetTypeFn = *const fn (ctx: *anyopaque, kind: mir.TargetTypeKind, span: ast.Span) ?ast.TypeExpr;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    enums: *const std.StringHashMap(ast.EnumDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    mmio_structs: *const std.StringHashMap(MmioStruct),
    type_ctx: *anyopaque,
    c_type: CTypeFn,
    mir_call_target_kind: MirCallTargetKindFn,
    mir_target_type: MirTargetTypeFn,
};

pub fn comptimeReflectThunk(ctx: ?*anyopaque, call: ast.Expr) ?i128 {
    const env: *const ReflectEnv = @ptrCast(@alignCast(ctx orelse return null));
    return comptimeReflect(env, call);
}

pub fn emitReflectionCall(ctx: EmitContext, call: anytype) !bool {
    const kind = ctx.mir_call_target_kind(ctx.type_ctx, call.callee.*.span) orelse return false;
    if (kind != .reflection_size and kind != .reflection_alignment and kind != .reflection_field_offset and kind != .reflection_bit_offset and kind != .reflection_repr) return false;
    const target_ty = ctx.mir_target_type(ctx.type_ctx, .reflection_target, call.callee.*.span) orelse return error.UnsupportedCEmission;
    _ = ctx.mir_target_type(ctx.type_ctx, .reflection_result, call.callee.*.span) orelse return error.UnsupportedCEmission;
    if (call.type_args.len != 1) return error.UnsupportedCEmission;
    switch (kind) {
        .reflection_size => {
            if (call.args.len != 0) return error.UnsupportedCEmission;
            try ctx.out.print(ctx.allocator, "((uintptr_t)sizeof({s}))", .{try reflectionCTypeFor(ctx, target_ty)});
            return true;
        },
        .reflection_alignment => {
            if (call.args.len != 0) return error.UnsupportedCEmission;
            try ctx.out.print(ctx.allocator, "((uintptr_t)alignof({s}))", .{try reflectionCTypeFor(ctx, target_ty)});
            return true;
        },
        .reflection_field_offset => {
            if (call.args.len != 1) return error.UnsupportedCEmission;
            const field_name = reflectionFieldName(call.args[0]) orelse return error.UnsupportedCEmission;
            if (typeName(target_ty)) |type_name| {
                if (ctx.overlay_unions.get(type_name)) |overlay| {
                    if (!overlay.fields.contains(field_name)) return error.UnsupportedCEmission;
                    try ctx.out.appendSlice(ctx.allocator, "((uintptr_t)0)");
                    return true;
                }
            }
            try ctx.out.print(ctx.allocator, "((uintptr_t)offsetof({s}, {s}))", .{ try reflectionCTypeFor(ctx, target_ty), field_name });
            return true;
        },
        .reflection_bit_offset => {
            if (call.args.len != 1) return error.UnsupportedCEmission;
            const field_name = reflectionFieldName(call.args[0]) orelse return error.UnsupportedCEmission;
            const name = typeName(target_ty) orelse return error.UnsupportedCEmission;
            if (ctx.packed_bits.get(name)) |info| {
                const field = info.fields.get(field_name) orelse return error.UnsupportedCEmission;
                try ctx.out.print(ctx.allocator, "((uintptr_t){d})", .{field.bit_index});
                return true;
            }
            try ctx.out.print(ctx.allocator, "((uintptr_t)(offsetof({s}, {s}) * CHAR_BIT))", .{ try reflectionCTypeFor(ctx, target_ty), field_name });
            return true;
        },
        .reflection_repr => {
            if (call.args.len != 0) return error.UnsupportedCEmission;
            if (typeName(target_ty)) |name| {
                if (ctx.enums.get(name)) |enum_decl| {
                    const repr = enum_decl.repr orelse simpleNameType("isize", target_ty.span);
                    try ctx.out.print(ctx.allocator, "((uintptr_t)sizeof({s}))", .{try reflectionCTypeFor(ctx, repr)});
                    return true;
                }
                if (ctx.packed_bits.get(name)) |info| {
                    try ctx.out.print(ctx.allocator, "((uintptr_t)sizeof({s}))", .{info.repr_c_type});
                    return true;
                }
                if (ctx.tagged_unions.contains(name)) {
                    try ctx.out.print(ctx.allocator, "((uintptr_t)sizeof({s}Tag))", .{name});
                    return true;
                }
            }
            try ctx.out.print(ctx.allocator, "((uintptr_t)sizeof({s}))", .{try reflectionCTypeFor(ctx, target_ty)});
            return true;
        },
        else => unreachable,
    }
}

fn reflectionCTypeFor(ctx: EmitContext, ty: ast.TypeExpr) ![]const u8 {
    if (typeName(ty)) |name| {
        if (ctx.mmio_structs.contains(name)) return name;
    }
    if (ty.kind == .generic) {
        const generic = ty.kind.generic;
        if (std.mem.eql(u8, generic.base.text, "DmaBuf") and generic.args.len == 2) return "uintptr_t";
    }
    return ctx.c_type(ctx.type_ctx, ty);
}

pub fn comptimeReflect(env: *const ReflectEnv, call: ast.Expr) ?i128 {
    const node = switch (call.kind) {
        .call => |n| n,
        else => return null,
    };
    const kind = lower_c_builtin.reflectionCallKind(node.callee.*) orelse return null;
    if (node.type_args.len != 1) return null;
    const ty = node.type_args[0];
    return switch (kind) {
        .size => if (node.args.len == 0) comptimeSizeOf(env, ty, 0) else null,
        .alignment => if (node.args.len == 0) comptimeAlignOf(env, ty, 0) else null,
        .field_offset => if (node.args.len == 1) comptimeFieldOffset(env, ty, reflectionFieldName(node.args[0]) orelse return null, 0) else null,
        .bit_offset => if (node.args.len == 1) comptimeBitOffset(env, ty, reflectionFieldName(node.args[0]) orelse return null, 0) else null,
        .repr => if (node.args.len == 0) comptimeReprOf(env, ty, 0) else null,
    };
}

pub fn comptimeSizeOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.type_aliases.get(name.text)) |aliased| return comptimeSizeOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| return comptimeStructSize(env, info, depth + 1);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeSizeOf(env, repr, depth + 1);
            }
            return null;
        },
        .pointer, .raw_many_pointer, .fn_pointer => return 8,
        .dyn_trait, .closure_type => return 16,
        .nullable => |child| {
            const layout = comptimeNullableLayout(env, child.*, depth + 1) orelse return null;
            return layout.size;
        },
        .slice => return 16,
        .generic => |g| {
            if (isPointerLikeGeneric(g.base.text)) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            if (isArithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| {
            const len = constArrayLenValue(node.len, env.const_fns, env.const_globals, comptimeReflectThunk, @constCast(env)) orelse return null;
            const elem = comptimeSizeOf(env, node.child.*, depth + 1) orelse return null;
            return comptimeArraySize(len, elem);
        },
        .qualified => |node| return comptimeSizeOf(env, node.child.*, depth + 1),
        else => return null,
    }
}

pub fn comptimeAlignOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.alignment);
            if (env.type_aliases.get(name.text)) |aliased| return comptimeAlignOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| return comptimeStructAlign(env, info, depth + 1);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeAlignOf(env, repr, depth + 1);
            }
            return null;
        },
        .pointer, .raw_many_pointer, .fn_pointer, .slice, .dyn_trait, .closure_type => return 8,
        .nullable => |child| {
            const layout = comptimeNullableLayout(env, child.*, depth + 1) orelse return null;
            return layout.alignment;
        },
        .generic => |g| {
            if (isPointerLikeGeneric(g.base.text)) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            if (isArithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| return comptimeAlignOf(env, node.child.*, depth + 1),
        .qualified => |node| return comptimeAlignOf(env, node.child.*, depth + 1),
        else => return null,
    }
}

fn comptimeNullableLayout(env: *const ReflectEnv, child: ast.TypeExpr, depth: usize) ?type_layout.ComptimeOptionalLayout {
    const resolved = resolveReflectionAlias(env, child, 0);
    return switch (resolved.kind) {
        .pointer, .raw_many_pointer, .fn_pointer => .{ .size = 8, .alignment = 8, .payload_offset = 0 },
        .dyn_trait => .{ .size = 16, .alignment = 8, .payload_offset = 0 },
        .name => |name| if (std.mem.eql(u8, name.text, "c_void")) null else blk: {
            const size = comptimeSizeOf(env, resolved, depth + 1) orelse break :blk null;
            const alignment = comptimeAlignOf(env, resolved, depth + 1) orelse break :blk null;
            break :blk comptimeTaggedOptionalLayout(size, alignment);
        },
        else => null,
    };
}

fn resolveReflectionAlias(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ast.TypeExpr {
    if (depth > 64) return ty;
    return switch (ty.kind) {
        .name => |name| if (env.type_aliases.get(name.text)) |target| resolveReflectionAlias(env, target, depth + 1) else ty,
        .qualified => |node| resolveReflectionAlias(env, node.child.*, depth + 1),
        else => ty,
    };
}

pub fn comptimeStructSize(env: *const ReflectEnv, struct_decl: ast.StructDecl, depth: usize) ?i128 {
    const layout = comptimeStructLayout(env, struct_decl, null, depth + 1) orelse return null;
    return layout.size;
}

pub fn comptimeStructAlign(env: *const ReflectEnv, struct_decl: ast.StructDecl, depth: usize) ?i128 {
    const layout = comptimeStructLayout(env, struct_decl, null, depth + 1) orelse return null;
    return layout.alignment;
}

pub fn comptimeStructLayout(env: *const ReflectEnv, struct_decl: ast.StructDecl, wanted_field: ?[]const u8, depth: usize) ?ComptimeStructLayout {
    return type_layout.comptimeStructLayout(*const ReflectEnv, env, struct_decl, wanted_field, depth, comptimeSizeOf, comptimeAlignOf);
}

pub fn comptimeFieldOffset(env: *const ReflectEnv, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = typeName(ty) orelse return null;
    if (env.type_aliases.get(name)) |aliased| return comptimeFieldOffset(env, aliased, field, depth + 1);
    if (env.structs.get(name)) |info| {
        const layout = comptimeStructLayout(env, info, field, depth + 1) orelse return null;
        return layout.field_offset;
    }
    if (env.overlay_unions.get(name)) |info| {
        if (info.fields.contains(field)) return 0;
    }
    return null;
}

pub fn comptimeBitOffset(env: *const ReflectEnv, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = typeName(ty) orelse return null;
    if (env.type_aliases.get(name)) |aliased| return comptimeBitOffset(env, aliased, field, depth + 1);
    if (env.packed_bits.get(name)) |info| {
        const packed_field = info.fields.get(field) orelse return null;
        return @intCast(packed_field.bit_index);
    }
    const byte_offset = comptimeFieldOffset(env, ty, field, depth + 1) orelse return null;
    return comptimeBitOffsetFromBytes(byte_offset);
}

pub fn comptimeReprOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.type_aliases.get(name.text)) |aliased| return comptimeReprOf(env, aliased, depth + 1);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeSizeOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| {
                return comptimeSizeOf(env, simpleNameType(info.repr_name, ty.span), depth + 1);
            }
            if (env.tagged_unions.contains(name.text)) return cTaggedUnionTagSize();
            return comptimeSizeOf(env, ty, depth + 1);
        },
        .pointer, .raw_many_pointer, .slice, .array, .generic => return comptimeSizeOf(env, ty, depth + 1),
        .qualified => |node| return comptimeReprOf(env, node.child.*, depth + 1),
        else => return null,
    }
}
