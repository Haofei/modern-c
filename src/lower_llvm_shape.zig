//! LLVM backend type-shape helpers.

const std = @import("std");

const ast = @import("ast.zig");
const lower_llvm_alias = @import("lower_llvm_alias.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");
const lower_llvm_type = @import("lower_llvm_type.zig");

const ResultTypeInfo = lower_llvm_model.ResultTypeInfo;
const isPayloadDomainGenericName = lower_llvm_type.isPayloadDomainGenericName;

pub fn nullableInnerType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .nullable => |child| child.*,
        else => null,
    };
}

pub fn atomicPayloadType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "atomic") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| atomicPayloadType(type_aliases, node.child.*),
        else => null,
    };
}

pub fn maybeUninitPayloadType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "MaybeUninit") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| maybeUninitPayloadType(type_aliases, node.child.*),
        else => null,
    };
}

pub fn resultInfo(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ResultTypeInfo {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return null;
            return .{ .ok_ty = node.args[0], .err_ty = node.args[1] };
        },
        .qualified => |node| resultInfo(type_aliases, node.child.*),
        else => null,
    };
}

pub fn domainPayloadType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| {
            if (!isPayloadDomainGenericName(node.base.text) or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| domainPayloadType(type_aliases, node.child.*),
        else => null,
    };
}

pub fn isWrapDomainType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap") and node.args.len == 1,
        .qualified => |node| isWrapDomainType(type_aliases, node.child.*),
        else => false,
    };
}

pub fn isSatDomainType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) bool {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat") and node.args.len == 1,
        .qualified => |node| isSatDomainType(type_aliases, node.child.*),
        else => false,
    };
}
