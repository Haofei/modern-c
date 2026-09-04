const std = @import("std");

const ast_bridge = @import("ast_bridge.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const lower_llvm_type = @import("lower_llvm_type.zig");

const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const integerBits = lower_llvm_type.integerBits;

pub const MemberCallee = struct {
    base: *ast_bridge.Expr,
    name: ast_bridge.Ident,
};

pub fn memberCallee(call: anytype) ?MemberCallee {
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return null,
        },
        else => return null,
    };
    return .{ .base = member.base, .name = member.name };
}

pub fn assignmentIdent(target: ast_bridge.Expr) ?ast_bridge.Ident {
    return switch (target.kind) {
        .ident => |ident| ident,
        .grouped => |inner| assignmentIdent(inner.*),
        else => null,
    };
}

pub fn derefTarget(target: ast_bridge.Expr) ?ast_bridge.Expr {
    return switch (target.kind) {
        .deref => |inner| inner.*,
        .grouped => |inner| derefTarget(inner.*),
        else => null,
    };
}

pub fn structFieldIndex(struct_decl: ast_bridge.StructDecl, field_name: []const u8) ?usize {
    for (struct_decl.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name.text, field_name)) return i;
    }
    return null;
}

pub fn structLiteralField(fields: []const ast_bridge.StructLiteralField, field_name: []const u8) ?ast_bridge.Expr {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return field.value;
    }
    return null;
}

pub fn packedBitsMask(bit_index: usize) u64 {
    return @as(u64, 1) << @intCast(bit_index);
}

pub fn packedBitsClearMask(info: PackedBitsInfo, bit_index: usize) ?u64 {
    const bits = integerBits(info.repr) orelse return null;
    if (bits >= 64) return ~packedBitsMask(bit_index);
    return ((@as(u64, 1) << @intCast(bits)) - 1) & ~packedBitsMask(bit_index);
}

pub fn isUninitExpr(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped => |inner| isUninitExpr(inner.*),
        else => false,
    };
}

pub fn taggedUnionConstructorName(callee: ast_bridge.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| taggedUnionConstructorName(inner.*),
        else => null,
    };
}
