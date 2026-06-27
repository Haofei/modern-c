//! LLVM backend registry/type lookup helpers.

const std = @import("std");

const ast = @import("ast.zig");
const lower_llvm_alias = @import("lower_llvm_alias.zig");
const lower_llvm_model = @import("lower_llvm_model.zig");

const PackedBitsInfo = lower_llvm_model.PackedBitsInfo;
const OverlayUnionInfo = lower_llvm_model.OverlayUnionInfo;

pub fn structDeclForType(
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    struct_types: *const std.StringHashMap(ast.StructDecl),
    ty: ast.TypeExpr,
) ?ast.StructDecl {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| struct_types.get(name.text),
        else => null,
    };
}

pub fn packedBitsInfoForType(
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    packed_bits: *const std.StringHashMap(PackedBitsInfo),
    ty: ast.TypeExpr,
) ?PackedBitsInfo {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| packed_bits.get(name.text),
        else => null,
    };
}

pub fn overlayInfoForType(
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    overlay_unions: *const std.StringHashMap(OverlayUnionInfo),
    ty: ast.TypeExpr,
) ?OverlayUnionInfo {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| overlay_unions.get(name.text),
        else => null,
    };
}

pub fn taggedUnionForType(
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    tagged_unions: *const std.StringHashMap(ast.UnionDecl),
    ty: ast.TypeExpr,
) ?ast.UnionDecl {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| tagged_unions.get(name.text),
        else => null,
    };
}

pub fn enumDeclForType(
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    enum_types: *const std.StringHashMap(ast.EnumDecl),
    ty: ast.TypeExpr,
) ?ast.EnumDecl {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .name => |name| enum_types.get(name.text),
        else => null,
    };
}

pub fn memberBaseStructType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ?ast.TypeExpr {
    const resolved_ty = lower_llvm_alias.resolveAliasType(type_aliases, ty);
    return switch (resolved_ty.kind) {
        .pointer => |node| node.child.*,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1) node.args[0] else ty,
        else => ty,
    };
}

pub fn memberBaseStructDecl(
    type_aliases: *const std.StringHashMap(ast.TypeExpr),
    struct_types: *const std.StringHashMap(ast.StructDecl),
    ty: ast.TypeExpr,
) ?ast.StructDecl {
    const struct_ty = memberBaseStructType(type_aliases, ty) orelse return null;
    return structDeclForType(type_aliases, struct_types, struct_ty);
}

pub fn taggedUnionCaseIndex(union_decl: ast.UnionDecl, case_name: []const u8) ?usize {
    for (union_decl.cases, 0..) |case, i| {
        if (std.mem.eql(u8, case.name.text, case_name)) return i;
    }
    return null;
}

pub fn packedBitsFieldIndex(info: PackedBitsInfo, field_name: []const u8) ?usize {
    for (info.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name.text, field_name)) return i;
    }
    return null;
}
