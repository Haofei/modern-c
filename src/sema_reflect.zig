const std = @import("std");

const array_len = @import("array_len.zig");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const eval = @import("eval.zig");
const numeric = @import("numeric.zig");
const sema_builtin = @import("sema_builtin.zig");
const sema_model = @import("sema_model.zig");
const sema_type = @import("sema_type.zig");
const type_layout = @import("layout.zig");

const EnumInfo = sema_model.EnumInfo;
const LayoutFieldInfo = sema_model.LayoutFieldInfo;
const StructInfo = sema_model.StructInfo;
const UnionInfo = sema_model.UnionInfo;
const alignForward = numeric.alignForward;
const enumLiteralName = sema_builtin.enumLiteralName;
const isArithmeticLayoutGeneric = ast_query.isArithmeticLayoutGeneric;
const isPointerLikeGeneric = ast_query.isPointerLikeGeneric;
const parseArrayLen = array_len.parseArrayLen;
const reflectionKind = sema_builtin.reflectionKind;
const reflectionTypeExprFromArg = sema_builtin.reflectionTypeExprFromArg;
const scalarLayout = type_layout.scalarLayout;
const simpleNameType = ast_query.simpleNameType;
const typeName = ast_query.typeName;

pub const ReflectEnv = struct {
    structs: *const std.StringHashMap(StructInfo),
    packed_bits: *const std.StringHashMap(LayoutFieldInfo),
    overlay_unions: *const std.StringHashMap(LayoutFieldInfo),
    tagged_unions: *const std.StringHashMap(UnionInfo),
    enums: *const std.StringHashMap(EnumInfo),
    aliases: *const std.StringHashMap(ast.TypeExpr),
    const_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    const_globals: ?*const std.StringHashMap(eval.ComptimeValue) = null,
};

const c_tagged_union_tag_size: i128 = 4;
const c_tagged_union_tag_align: i128 = 4;

pub fn comptimeReflectThunk(ctx: ?*anyopaque, call: ast.Expr) ?i128 {
    const env: *const ReflectEnv = @ptrCast(@alignCast(ctx orelse return null));
    return comptimeReflect(env, call);
}

pub fn comptimeReflect(env: *const ReflectEnv, call: ast.Expr) ?i128 {
    const node = switch (call.kind) {
        .call => |n| n,
        else => return null,
    };
    const kind = reflectionKind(node.callee.*) orelse return null;
    const ty = reflectionTypeFromCall(node) orelse return null;
    return switch (kind) {
        .size => comptimeSizeOf(env, ty, 0),
        .alignment => comptimeAlignOf(env, ty, 0),
        .field_offset => comptimeFieldOffset(env, ty, reflectionFieldFromCall(node) orelse return null, 0),
        .bit_offset => comptimeBitOffset(env, ty, reflectionFieldFromCall(node) orelse return null, 0),
        .repr => comptimeReprOf(env, ty, 0),
        else => null,
    };
}

pub fn comptimeSizeOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.aliases.get(name.text)) |aliased| return comptimeSizeOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| return comptimeStructSize(env, info, depth);
            if (env.tagged_unions.get(name.text)) |info| return comptimeTaggedUnionSize(env, info, depth);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeSizeOf(env, repr, depth + 1);
            }
            return null;
        },
        .pointer, .raw_many_pointer => return 8,
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
            const len = parseArrayLen(node.len, env.const_fns, env.const_globals) orelse return null;
            const elem = comptimeSizeOf(env, node.child.*, depth + 1) orelse return null;
            return @as(i128, @intCast(len)) * elem;
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
            if (env.aliases.get(name.text)) |aliased| return comptimeAlignOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| return comptimeStructAlign(env, info, depth);
            if (env.tagged_unions.get(name.text)) |info| return comptimeTaggedUnionAlign(env, info, depth);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeAlignOf(env, repr, depth + 1);
            }
            return null;
        },
        .pointer, .raw_many_pointer, .slice => return 8,
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

pub fn comptimeFieldOffset(env: *const ReflectEnv, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = typeName(ty) orelse return null;
    if (env.aliases.get(name)) |aliased| return comptimeFieldOffset(env, aliased, field, depth + 1);
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
    if (env.aliases.get(name)) |aliased| return comptimeBitOffset(env, aliased, field, depth + 1);
    if (env.packed_bits.get(name)) |info| {
        for (info.ordered, 0..) |packed_field, bit| {
            if (std.mem.eql(u8, packed_field.name.text, field)) return @intCast(bit);
        }
        return null;
    }
    const byte_offset = comptimeFieldOffset(env, ty, field, depth + 1) orelse return null;
    return byte_offset * 8;
}

pub fn comptimeReprOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.aliases.get(name.text)) |aliased| return comptimeReprOf(env, aliased, depth + 1);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeSizeOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| {
                const repr = info.repr orelse return null;
                return comptimeSizeOf(env, repr, depth + 1);
            }
            if (env.tagged_unions.contains(name.text)) return c_tagged_union_tag_size;
            return comptimeSizeOf(env, ty, depth + 1);
        },
        .pointer, .raw_many_pointer, .slice, .array, .generic => return comptimeSizeOf(env, ty, depth + 1),
        .qualified => |node| return comptimeReprOf(env, node.child.*, depth + 1),
        else => return null,
    }
}

const TaggedUnionPayloadLayout = struct {
    has_payload: bool,
    size: i128,
    alignment: i128,
};

const ComptimeStructLayout = struct {
    size: i128,
    field_offset: ?i128 = null,
};

fn comptimeStructSize(env: *const ReflectEnv, info: StructInfo, depth: usize) ?i128 {
    const layout = comptimeStructLayout(env, info, null, depth) orelse return null;
    return layout.size;
}

fn comptimeStructAlign(env: *const ReflectEnv, info: StructInfo, depth: usize) ?i128 {
    var max_align: i128 = 1;
    var it = info.fields.valueIterator();
    while (it.next()) |field_ty| {
        const alignment = comptimeAlignOf(env, field_ty.*, depth + 1) orelse return null;
        if (alignment > max_align) max_align = alignment;
    }
    return max_align;
}

fn comptimeTaggedUnionSize(env: *const ReflectEnv, info: UnionInfo, depth: usize) ?i128 {
    if (depth > 32) return null;
    const payload = comptimeTaggedUnionPayloadLayout(env, info, depth + 1) orelse return null;
    var offset: i128 = c_tagged_union_tag_size;
    var max_align: i128 = c_tagged_union_tag_align;
    if (payload.has_payload) {
        if (payload.alignment > max_align) max_align = payload.alignment;
        offset = alignForward(offset, payload.alignment) orelse return null;
        offset += payload.size;
    }
    return alignForward(offset, max_align);
}

fn comptimeTaggedUnionAlign(env: *const ReflectEnv, info: UnionInfo, depth: usize) ?i128 {
    if (depth > 32) return null;
    const payload = comptimeTaggedUnionPayloadLayout(env, info, depth + 1) orelse return null;
    return if (payload.has_payload and payload.alignment > c_tagged_union_tag_align)
        payload.alignment
    else
        c_tagged_union_tag_align;
}

fn comptimeTaggedUnionPayloadLayout(env: *const ReflectEnv, info: UnionInfo, depth: usize) ?TaggedUnionPayloadLayout {
    var has_payload = false;
    var max_size: i128 = 0;
    var max_align: i128 = 1;
    var it = info.cases.valueIterator();
    while (it.next()) |maybe_payload| {
        const payload_ty = maybe_payload.* orelse continue;
        has_payload = true;
        const size = comptimeSizeOf(env, payload_ty, depth + 1) orelse return null;
        const alignment = comptimeAlignOf(env, payload_ty, depth + 1) orelse return null;
        if (alignment <= 0) return null;
        if (size > max_size) max_size = size;
        if (alignment > max_align) max_align = alignment;
    }
    return .{
        .has_payload = has_payload,
        .size = alignForward(max_size, max_align) orelse return null,
        .alignment = max_align,
    };
}

fn comptimeStructLayout(env: *const ReflectEnv, info: StructInfo, want_field: ?[]const u8, depth: usize) ?ComptimeStructLayout {
    // `#[c_union]`: real C union layout — every field at offset 0, size = largest field
    // rounded up to the max alignment (mirrors layout.zig).
    if (info.is_c_union) {
        var max_size: i128 = 0;
        var union_align: i128 = 1;
        var union_found: ?i128 = null;
        for (info.ordered) |field| {
            const size = comptimeSizeOf(env, field.ty, depth + 1) orelse return null;
            const alignment = comptimeAlignOf(env, field.ty, depth + 1) orelse return null;
            if (alignment <= 0) return null;
            if (alignment > union_align) union_align = alignment;
            if (size > max_size) max_size = size;
            if (want_field) |wanted| {
                if (std.mem.eql(u8, field.name.text, wanted)) union_found = 0;
            }
        }
        return .{
            .size = alignForward(max_size, union_align) orelse return null,
            .field_offset = union_found,
        };
    }
    var offset: i128 = 0;
    var max_align: i128 = 1;
    var found: ?i128 = null;
    for (info.ordered) |field| {
        const size = comptimeSizeOf(env, field.ty, depth + 1) orelse return null;
        const alignment = comptimeAlignOf(env, field.ty, depth + 1) orelse return null;
        if (alignment <= 0) return null;
        if (alignment > max_align) max_align = alignment;
        if (field.offset) |explicit| {
            const explicit_offset: i128 = @intCast(explicit);
            if (explicit_offset < offset) return null;
            offset = explicit_offset;
        } else {
            offset = alignForward(offset, alignment) orelse return null;
        }
        if (want_field) |wanted| {
            if (std.mem.eql(u8, field.name.text, wanted)) found = offset;
        }
        offset += size;
    }
    return .{
        .size = alignForward(offset, max_align) orelse return null,
        .field_offset = found,
    };
}

pub fn reflectionTypeFromCall(node: anytype) ?ast.TypeExpr {
    if (node.type_args.len == 1) return node.type_args[0];
    if (node.args.len >= 1) return reflectionTypeExprFromArg(node.args[0]);
    return null;
}

pub fn reflectionFieldFromCall(node: anytype) ?[]const u8 {
    const field_expr = if (node.type_args.len == 1) blk: {
        if (node.args.len != 1) return null;
        break :blk node.args[0];
    } else blk: {
        if (node.args.len != 2) return null;
        break :blk node.args[1];
    };
    const field = enumLiteralName(field_expr) orelse return null;
    return field.text;
}
