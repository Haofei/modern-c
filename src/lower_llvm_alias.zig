//! LLVM backend type-alias resolution helpers.

const std = @import("std");

const ast = @import("ast.zig");

pub fn resolveAliasType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ast.TypeExpr {
    return switch (ty.kind) {
        .name => |name| if (type_aliases.get(name.text)) |aliased| resolveAliasType(type_aliases, aliased) else ty,
        else => ty,
    };
}
