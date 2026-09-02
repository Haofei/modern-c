const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const array_len = @import("array_len.zig");
const eval = @import("eval.zig");
const syntax_bridge = @import("syntax_bridge.zig");
const type_layout = @import("layout.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const lower_llvm_query = @import("lower_llvm_query.zig");
const lower_llvm_type = @import("lower_llvm_type.zig");
const type_bridge = @import("type_bridge.zig");

const ComptimeStructLayout = type_layout.ComptimeStructLayout;
const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const OverlayUnionInfo = lower_llvm_model.OverlayUnionInfo;
const TaggedUnionLayout = lower_llvm_model.TaggedUnionLayout;
const alignForward = lower_llvm_type.alignForward;
const exprAsType = lower_llvm_type.exprAsType;
const isDynTraitLlvmType = lower_llvm_type.isDynTraitLlvmType;
const isOpaqueAddressGenericName = lower_llvm_type.isOpaqueAddressGenericName;
const isPayloadDomainGenericName = lower_llvm_type.isPayloadDomainGenericName;
const isPointerLikeType = lower_llvm_type.isPointerLikeType;
const libraryScalarLlvmType = lower_llvm_type.libraryScalarLlvmType;
const reflectionValueCallKind = syntax_bridge.reflectionValueCallKind;
const reflectionFieldName = syntax_bridge.reflectionFieldName;
const scalarLayout = type_layout.scalarLayout;
const typeName = type_bridge.typeName;
const typeNameEql = lower_llvm_type.typeNameEql;
const comptimeArraySize = type_layout.comptimeArraySize;
const comptimeBitOffsetFromBytes = type_layout.comptimeBitOffset;
const comptimeLayoutAdd = type_layout.comptimeLayoutAdd;
const comptimeTaggedOptionalLayout = type_layout.comptimeTaggedOptionalLayout;

pub const ReflectEnv = struct {
    type_aliases: *const std.StringHashMap(ast_bridge.TypeExpr),
    enum_types: *const std.StringHashMap(ast_bridge.EnumDecl),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    tagged_unions: *const std.StringHashMap(ast_bridge.UnionDecl),
    struct_types: *const std.StringHashMap(ast_bridge.StructDecl),
    const_fns: *const std.StringHashMap(eval.ComptimeFunction),
    const_globals: *const std.StringHashMap(eval.ComptimeValue),
    const_global_widths: *const std.StringHashMap(u16),
    const_global_domains: *const std.StringHashMap(eval.DomainWidth),
};

pub fn comptimeReflectThunk(ctx: ?*anyopaque, call: ast_bridge.Expr) ?i128 {
    const env: *const ReflectEnv = @ptrCast(@alignCast(ctx orelse return null));
    return comptimeReflect(env, call);
}

pub fn comptimeReflect(env: *const ReflectEnv, call: ast_bridge.Expr) ?i128 {
    const node = switch (call.kind) {
        .call => |n| n,
        else => return null,
    };
    const kind = reflectionValueCallKind(node.callee.*) orelse return null;
    const ty = reflectionTypeArg(node) orelse return null;
    const field_arg_index: usize = if (node.type_args.len == 1) 0 else 1;
    return switch (kind) {
        .size => comptimeSizeOf(env, ty, 0),
        .repr => comptimeReprOf(env, ty, 0),
        .alignment => comptimeAlignOf(env, ty, 0),
        .field_offset => if (field_arg_index < node.args.len) comptimeFieldOffset(env, ty, reflectionFieldName(node.args[field_arg_index]) orelse return null, 0) else null,
        .bit_offset => if (field_arg_index < node.args.len) comptimeBitOffset(env, ty, reflectionFieldName(node.args[field_arg_index]) orelse return null) else null,
    };
}

pub fn reflectionTypeArg(node: anytype) ?ast_bridge.TypeExpr {
    if (node.type_args.len == 1) return node.type_args[0];
    if (node.type_args.len != 0 or node.args.len == 0) return null;
    return exprAsType(node.args[0]);
}

pub fn arrayLenValue(env: *const ReflectEnv, expr: ast_bridge.Expr) ?u64 {
    if (array_len.parseArrayLenWithReflect(expr, env.const_fns, env.const_globals, comptimeReflectThunk, @constCast(env))) |len| return @intCast(len);
    var fb_arena: ?std.heap.ArenaAllocator = null;
    defer if (fb_arena) |*a| a.deinit();
    const fold_alloc = eval.tryFoldScratch() orelse blk: {
        fb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        break :blk fb_arena.?.allocator();
    };
    defer if (fb_arena == null) eval.releaseFoldScratch();
    var scope = eval.ComptimeScope.init(fold_alloc);
    defer scope.deinit();
    if (!seedConstFoldScope(env, &scope)) return null;
    return switch (eval.foldComptimeExpr(&scope, expr)) {
        .value => |value| switch (value) {
            .int => |n| if (n >= 0 and n <= std.math.maxInt(u64)) @intCast(n) else null,
            else => null,
        },
        else => null,
    };
}

pub fn seedConstFoldScope(env: *const ReflectEnv, scope: *eval.ComptimeScope) bool {
    scope.funcs = env.const_fns;
    scope.globals = env.const_globals;
    scope.global_domains = env.const_global_domains;
    scope.reflect = comptimeReflectThunk;
    scope.reflect_ctx = @constCast(env);
    var widths = env.const_global_widths.iterator();
    while (widths.next()) |entry| scope.bindWidth(entry.key_ptr.*, entry.value_ptr.*) catch return false;
    return true;
}

pub fn comptimeBitOffset(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, field: []const u8) ?i128 {
    if (packedBitsInfoForType(env, ty)) |info| {
        const index = packedBitsFieldIndex(info, field) orelse return null;
        return @intCast(index);
    }
    const byte_offset = comptimeFieldOffset(env, ty, field, 0) orelse return null;
    return comptimeBitOffsetFromBytes(byte_offset);
}

pub fn comptimeReprOf(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    const resolved_ty = resolveAliasType(env, ty);
    return switch (resolved_ty.kind) {
        .name => |name| {
            if (env.enum_types.get(name.text)) |enum_decl| return comptimeSizeOf(env, enumReprType(enum_decl), depth + 1);
            if (env.tagged_unions.get(name.text) != null) return 4;
            return comptimeSizeOf(env, resolved_ty, depth + 1);
        },
        .qualified => |node| comptimeReprOf(env, node.child.*, depth + 1),
        else => comptimeSizeOf(env, resolved_ty, depth + 1),
    };
}

pub fn comptimeSizeOf(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.type_aliases.get(name.text)) |aliased| return comptimeSizeOf(env, aliased, depth + 1);
            if (env.overlay_unions.get(name.text)) |info| return @intCast(info.size);
            if (env.tagged_unions.get(name.text)) |union_decl| {
                const layout = taggedUnionLayout(env, union_decl, depth + 1) orelse return null;
                return @intCast(layout.size);
            }
            if (env.struct_types.get(name.text)) |struct_decl| return comptimeStructSize(env, struct_decl, depth + 1);
            if (env.enum_types.get(name.text)) |enum_decl| return comptimeSizeOf(env, enumReprType(enum_decl), depth + 1);
            if (env.packed_bits.get(name.text)) |info| return comptimeSizeOf(env, info.repr, depth + 1);
            if (libraryScalarLlvmType(name.text) != null) return 1;
            return null;
        },
        .pointer, .raw_many_pointer, .fn_pointer => 8,
        .dyn_trait, .closure_type => 16,
        .nullable => |child| if (isPointerLikeType(resolveAliasType(env, child.*)))
            8
        else if (isDynTraitLlvmType(resolveAliasType(env, child.*)))
            16
        else if (nullablePayloadIsValueType(env, child.*)) blk: {
            const payload_size = comptimeSizeOf(env, child.*, depth + 1) orelse break :blk null;
            const payload_align = comptimeAlignOf(env, child.*, depth + 1) orelse break :blk null;
            const layout = comptimeTaggedOptionalLayout(payload_size, payload_align) orelse break :blk null;
            break :blk layout.size;
        } else null,
        .slice => 16,
        .generic => |g| {
            if (std.mem.eql(u8, g.base.text, "Result") and g.args.len == 2) {
                const ok_size = comptimeResultPayloadSizeOf(env, g.args[0], depth + 1) orelse return null;
                const err_size = comptimeResultPayloadSizeOf(env, g.args[1], depth + 1) orelse return null;
                const ok_align = comptimeResultPayloadAlignOf(env, g.args[0], depth + 1) orelse return null;
                const err_align = comptimeResultPayloadAlignOf(env, g.args[1], depth + 1) orelse return null;
                const max_align = @max(@max(ok_align, err_align), 1);
                var offset: i128 = 1;
                offset = alignForward(offset, ok_align) orelse return null;
                offset = comptimeLayoutAdd(offset, ok_size) orelse return null;
                offset = alignForward(offset, err_align) orelse return null;
                offset = comptimeLayoutAdd(offset, err_size) orelse return null;
                return alignForward(offset, max_align);
            }
            if (isOpaqueAddressGenericName(g.base.text) and g.args.len == 1) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if (std.mem.eql(u8, g.base.text, "atomic") and g.args.len == 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            if (std.mem.eql(u8, g.base.text, "MaybeUninit") and g.args.len == 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            if (std.mem.eql(u8, g.base.text, "MmioPtr") and g.args.len == 1) return 8;
            if (isPayloadDomainGenericName(g.base.text) and g.args.len == 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| {
            const len = arrayLenValue(env, node.len) orelse return null;
            const elem = comptimeSizeOf(env, node.child.*, depth + 1) orelse return null;
            return comptimeArraySize(len, elem);
        },
        .qualified => |node| comptimeSizeOf(env, node.child.*, depth + 1),
        else => null,
    };
}

pub fn comptimeAlignOf(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.alignment);
            if (env.type_aliases.get(name.text)) |aliased| return comptimeAlignOf(env, aliased, depth + 1);
            if (env.overlay_unions.get(name.text)) |info| return @intCast(info.alignment);
            if (env.tagged_unions.get(name.text)) |union_decl| {
                const layout = taggedUnionLayout(env, union_decl, depth + 1) orelse return null;
                return @intCast(layout.alignment);
            }
            if (env.struct_types.get(name.text)) |struct_decl| return comptimeStructAlign(env, struct_decl, depth + 1);
            if (env.enum_types.get(name.text)) |enum_decl| return comptimeAlignOf(env, enumReprType(enum_decl), depth + 1);
            if (env.packed_bits.get(name.text)) |info| return comptimeAlignOf(env, info.repr, depth + 1);
            if (libraryScalarLlvmType(name.text) != null) return 1;
            return null;
        },
        .pointer, .raw_many_pointer, .fn_pointer, .slice, .dyn_trait, .closure_type => 8,
        .nullable => |child| if (isPointerLikeType(resolveAliasType(env, child.*)) or isDynTraitLlvmType(resolveAliasType(env, child.*)))
            8
        else if (nullablePayloadIsValueType(env, child.*)) blk: {
            const payload_size = comptimeSizeOf(env, child.*, depth + 1) orelse break :blk null;
            const payload_align = comptimeAlignOf(env, child.*, depth + 1) orelse break :blk null;
            const layout = comptimeTaggedOptionalLayout(payload_size, payload_align) orelse break :blk null;
            break :blk layout.alignment;
        } else null,
        .generic => |g| {
            if (std.mem.eql(u8, g.base.text, "Result") and g.args.len == 2) {
                const ok_align = comptimeResultPayloadAlignOf(env, g.args[0], depth + 1) orelse return null;
                const err_align = comptimeResultPayloadAlignOf(env, g.args[1], depth + 1) orelse return null;
                return @max(@max(ok_align, err_align), 1);
            }
            if (isOpaqueAddressGenericName(g.base.text) and g.args.len == 1) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if (std.mem.eql(u8, g.base.text, "atomic") and g.args.len == 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            if (std.mem.eql(u8, g.base.text, "MaybeUninit") and g.args.len == 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            if (std.mem.eql(u8, g.base.text, "MmioPtr") and g.args.len == 1) return 8;
            if (isPayloadDomainGenericName(g.base.text) and g.args.len == 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| comptimeAlignOf(env, node.child.*, depth + 1),
        .qualified => |node| comptimeAlignOf(env, node.child.*, depth + 1),
        else => null,
    };
}

pub fn comptimeResultPayloadSizeOf(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
    if (typeNameEql(resolveAliasType(env, ty), "void")) return 1;
    return comptimeSizeOf(env, ty, depth + 1);
}

pub fn comptimeResultPayloadAlignOf(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, depth: usize) ?i128 {
    if (typeNameEql(resolveAliasType(env, ty), "void")) return 1;
    return comptimeAlignOf(env, ty, depth + 1);
}

pub fn comptimeStructSize(env: *const ReflectEnv, struct_decl: ast_bridge.StructDecl, depth: usize) ?i128 {
    const layout = comptimeStructLayout(env, struct_decl, null, depth + 1) orelse return null;
    return layout.size;
}

pub fn comptimeStructAlign(env: *const ReflectEnv, struct_decl: ast_bridge.StructDecl, depth: usize) ?i128 {
    const layout = comptimeStructLayout(env, struct_decl, null, depth + 1) orelse return null;
    return layout.alignment;
}

pub fn comptimeFieldOffset(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = typeName(ty) orelse return null;
    if (env.type_aliases.get(name)) |aliased| return comptimeFieldOffset(env, aliased, field, depth + 1);
    if (env.struct_types.get(name)) |struct_decl| {
        const layout = comptimeStructLayout(env, struct_decl, field, depth + 1) orelse return null;
        return layout.field_offset;
    }
    if (env.overlay_unions.get(name)) |info| {
        for (info.fields) |overlay_field| {
            if (std.mem.eql(u8, overlay_field.name.text, field)) return 0;
        }
    }
    return null;
}

pub fn comptimeStructLayout(env: *const ReflectEnv, struct_decl: ast_bridge.StructDecl, wanted_field: ?[]const u8, depth: usize) ?ComptimeStructLayout {
    return type_layout.comptimeStructLayout(*const ReflectEnv, env, struct_decl, wanted_field, depth, comptimeSizeOf, comptimeAlignOf);
}

pub fn taggedUnionLayout(env: *const ReflectEnv, union_decl: ast_bridge.UnionDecl, depth: usize) ?TaggedUnionLayout {
    return type_layout.comptimeTaggedUnionLayout(*const ReflectEnv, env, union_decl.cases, depth, comptimeSizeOf, comptimeAlignOf);
}

fn packedBitsInfoForType(env: *const ReflectEnv, ty: ast_bridge.TypeExpr) ?PackedBitsInfo {
    const name = typeName(ty) orelse return null;
    return env.packed_bits.get(name);
}

fn packedBitsFieldIndex(info: PackedBitsInfo, field_name: []const u8) ?usize {
    for (info.fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name.text, field_name)) return index;
    }
    return null;
}

pub fn resolveAliasType(env: *const ReflectEnv, ty: ast_bridge.TypeExpr) ast_bridge.TypeExpr {
    return resolveAliasTypeDepth(env, ty, 0);
}

fn nullablePayloadIsValueType(env: *const ReflectEnv, child: ast_bridge.TypeExpr) bool {
    const resolved = resolveAliasType(env, child);
    return switch (resolved.kind) {
        .name => |name| !std.mem.eql(u8, name.text, "c_void"),
        else => false,
    };
}

fn resolveAliasTypeDepth(env: *const ReflectEnv, ty: ast_bridge.TypeExpr, depth: usize) ast_bridge.TypeExpr {
    if (depth > 64) return ty;
    return switch (ty.kind) {
        .name => |name| if (env.type_aliases.get(name.text)) |aliased| resolveAliasTypeDepth(env, aliased, depth + 1) else ty,
        .qualified => |node| resolveAliasTypeDepth(env, node.child.*, depth + 1),
        else => ty,
    };
}

fn enumReprType(enum_decl: ast_bridge.EnumDecl) ast_bridge.TypeExpr {
    return enum_decl.repr orelse ast_bridge.TypeExpr{ .span = enum_decl.name.span, .kind = .{ .name = .{ .text = "isize", .span = enum_decl.name.span } } };
}
