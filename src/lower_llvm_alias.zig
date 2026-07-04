//! LLVM backend type-alias resolution helpers.

const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

const typeName = ast_query.typeName;

pub fn resolveAliasType(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr) ast.TypeExpr {
    return resolveAliasTypeDepth(type_aliases, ty, 0);
}

fn resolveAliasTypeDepth(type_aliases: *const std.StringHashMap(ast.TypeExpr), ty: ast.TypeExpr, depth: usize) ast.TypeExpr {
    if (depth > 64) return ty;
    return switch (ty.kind) {
        .name => |name| {
            const target = type_aliases.get(name.text) orelse return ty;
            if (typeName(target)) |target_name| {
                if (std.mem.eql(u8, target_name, name.text)) return ty;
            }
            return resolveAliasTypeDepth(type_aliases, target, depth + 1);
        },
        .qualified => |node| resolveAliasTypeDepth(type_aliases, node.child.*, depth),
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Secret") and node.args.len == 1)
            resolveAliasTypeDepth(type_aliases, node.args[0], depth + 1)
        else
            ty,
        else => ty,
    };
}
