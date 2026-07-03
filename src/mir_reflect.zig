const std = @import("std");
const ast = @import("ast.zig");
const numeric = @import("numeric.zig");
const type_layout = @import("layout.zig");
const mir_summary = @import("mir_summary.zig");

const ReflectEnv = mir_summary.ReflectEnv;
const StructSummary = mir_summary.StructSummary;

const comptimeArraySize = type_layout.comptimeArraySize;
const scalarLayout = type_layout.scalarLayout;
const parseUsizeLiteral = numeric.parseUsizeLiteral;

pub fn comptimeReflectThunk(ctx: ?*anyopaque, call: ast.Expr) ?i128 {
    const env: *ReflectEnv = @ptrCast(@alignCast(ctx orelse return null));
    return comptimeReflect(env, call);
}

fn comptimeReflect(env: *const ReflectEnv, call: ast.Expr) ?i128 {
    const node = switch (call.kind) {
        .call => |n| n,
        else => return null,
    };
    const kind = reflectionKind(node.callee.*) orelse return null;
    if (node.type_args.len != 1) return null;
    const ty = node.type_args[0];
    return switch (kind) {
        .size => if (node.args.len == 0) comptimeSizeOf(env, ty, 0) else null,
        .alignment => if (node.args.len == 0) comptimeAlignOf(env, ty, 0) else null,
        .repr => if (node.args.len == 0) comptimeReprOf(env, ty, 0) else null,
        .field_offset => if (node.args.len == 1) comptimeFieldOffset(env, ty, reflectionFieldName(node.args[0]) orelse return null, 0) else null,
        .bit_offset => if (node.args.len == 1) comptimeBitOffset(env, ty, reflectionFieldName(node.args[0]) orelse return null, 0) else null,
    };
}

const ReflectionKind = enum { size, alignment, field_offset, bit_offset, repr };

fn reflectionKind(callee: ast.Expr) ?ReflectionKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            return null;
        },
        .grouped => |inner| reflectionKind(inner.*),
        else => null,
    };
}

fn reflectionFieldName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| reflectionFieldName(inner.*),
        else => null,
    };
}

fn comptimeSizeOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.aliases.get(name.text)) |aliased| return comptimeSizeOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| {
                const layout = comptimeStructLayout(env, info, depth + 1, null) orelse return null;
                return layout.size;
            }
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeSizeOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| return comptimeSizeOf(env, info.repr, depth + 1);
            return null;
        },
        .pointer, .raw_many_pointer => 8,
        .slice => 16,
        .generic => |g| {
            if (pointerLikeGeneric(g.base.text)) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            if (arithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return comptimeSizeOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| {
            const len = staticArrayLen(node.len) orelse return null;
            const elem = comptimeSizeOf(env, node.child.*, depth + 1) orelse return null;
            return comptimeArraySize(len, elem);
        },
        .qualified => |node| comptimeSizeOf(env, node.child.*, depth + 1),
        else => null,
    };
}

fn comptimeAlignOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.alignment);
            if (env.aliases.get(name.text)) |aliased| return comptimeAlignOf(env, aliased, depth + 1);
            if (env.structs.get(name.text)) |info| {
                const layout = comptimeStructLayout(env, info, depth + 1, null) orelse return null;
                return layout.alignment;
            }
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeAlignOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| return comptimeAlignOf(env, info.repr, depth + 1);
            return null;
        },
        .pointer, .raw_many_pointer, .slice => 8,
        .generic => |g| {
            if (pointerLikeGeneric(g.base.text)) return 8;
            if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
            if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            if (arithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return comptimeAlignOf(env, g.args[0], depth + 1);
            return null;
        },
        .array => |node| comptimeAlignOf(env, node.child.*, depth + 1),
        .qualified => |node| comptimeAlignOf(env, node.child.*, depth + 1),
        else => null,
    };
}

fn comptimeReprOf(env: *const ReflectEnv, ty: ast.TypeExpr, depth: usize) ?i128 {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| {
            if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
            if (env.aliases.get(name.text)) |aliased| return comptimeReprOf(env, aliased, depth + 1);
            if (env.enums.get(name.text)) |info| {
                const repr = info.repr orelse simpleNameType("isize", ty.span);
                return comptimeSizeOf(env, repr, depth + 1);
            }
            if (env.packed_bits.get(name.text)) |info| return comptimeSizeOf(env, info.repr, depth + 1);
            if (env.unions.contains(name.text)) return taggedUnionTagSize();
            return comptimeSizeOf(env, ty, depth + 1);
        },
        .pointer, .raw_many_pointer, .slice, .array, .generic => comptimeSizeOf(env, ty, depth + 1),
        .qualified => |node| comptimeReprOf(env, node.child.*, depth + 1),
        else => null,
    };
}

fn comptimeFieldOffset(env: *const ReflectEnv, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = typeName(ty) orelse return null;
    if (env.aliases.get(name)) |aliased| return comptimeFieldOffset(env, aliased, field, depth + 1);
    if (env.structs.get(name)) |info| {
        const layout = comptimeStructLayout(env, info, depth + 1, field) orelse return null;
        return layout.field_offset;
    }
    return null;
}

fn comptimeBitOffset(env: *const ReflectEnv, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
    if (depth > 32) return null;
    const name = typeName(ty) orelse return null;
    if (env.aliases.get(name)) |aliased| return comptimeBitOffset(env, aliased, field, depth + 1);
    if (env.packed_bits.get(name)) |info| {
        for (info.fields, 0..) |packed_field, bit| {
            if (std.mem.eql(u8, packed_field.name.text, field)) return @intCast(bit);
        }
        return null;
    }
    const byte_offset = comptimeFieldOffset(env, ty, field, depth + 1) orelse return null;
    return byte_offset * 8;
}

const StructLayout = struct {
    size: i128,
    alignment: i128,
    field_offset: ?i128,
};

fn comptimeStructLayout(env: *const ReflectEnv, info: StructSummary, depth: usize, want_field: ?[]const u8) ?StructLayout {
    if (depth > 32) return null;
    var offset: i128 = 0;
    var max_align: i128 = 1;
    var found: ?i128 = null;
    for (info.fields) |field| {
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
        .alignment = max_align,
        .field_offset = found,
    };
}

fn taggedUnionTagSize() i128 {
    return 4;
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

fn simpleNameType(name: []const u8, span: ast.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = name, .span = span } } };
}

fn pointerLikeGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "MmioPtr") or std.mem.eql(u8, name, "UserPtr");
}

fn arithmeticLayoutGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter") or
        std.mem.eql(u8, name, "Duration");
}

fn alignForward(value: i128, alignment: i128) ?i128 {
    if (alignment <= 0) return null;
    const rem = @rem(value, alignment);
    if (rem == 0) return value;
    return std.math.add(i128, value, alignment - rem) catch null;
}

fn staticArrayLen(expr: ast.Expr) ?usize {
    return switch (expr.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .grouped => |inner| staticArrayLen(inner.*),
        .binary => |node| {
            const left = staticArrayLen(node.left.*) orelse return null;
            const right = staticArrayLen(node.right.*) orelse return null;
            return switch (node.op) {
                .add => std.math.add(usize, left, right) catch null,
                .sub => std.math.sub(usize, left, right) catch null,
                .mul => std.math.mul(usize, left, right) catch null,
                .div => if (right == 0) null else @divTrunc(left, right),
                .mod => if (right == 0) null else @mod(left, right),
                .shl => if (right >= @bitSizeOf(usize)) null else std.math.shl(usize, left, right),
                .shr => if (right >= @bitSizeOf(usize)) null else left >> @intCast(right),
                else => null,
            };
        },
        else => null,
    };
}
