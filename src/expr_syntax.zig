//! Narrow expression-shape helpers.
//!
//! These helpers are syntax-only adapters used while backend lowering is still
//! migrating from AST-shaped input to MIR/verified facts.  Keeping this surface
//! smaller than `ast_query.zig` makes remaining syntax dependencies explicit
//! and easier to ratchet down.

const std = @import("std");

const ast = @import("ast.zig");

pub fn boolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped, .move_expr => |inner| boolLiteralValue(inner.*),
        else => null,
    };
}

pub fn isUninitLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped, .move_expr => |inner| isUninitLiteral(inner.*),
        else => false,
    };
}

pub fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped, .move_expr => |inner| isIdentNamed(inner.*, name),
        else => false,
    };
}

pub fn byteViewAddressTarget(expr: ast.Expr) ?ast.Expr {
    return switch (expr.kind) {
        .address_of => |target| target.*,
        .grouped, .move_expr => |inner| byteViewAddressTarget(inner.*),
        else => null,
    };
}

pub fn calleeIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped, .move_expr => |inner| calleeIdentName(inner.*),
        else => null,
    };
}

pub const CallExpr = struct {
    callee: *ast.Expr,
    type_args: []ast.TypeExpr,
    args: []ast.Expr,
};

pub fn callExpr(expr: ast.Expr) ?CallExpr {
    return switch (expr.kind) {
        .call => |node| .{ .callee = node.callee, .type_args = node.type_args, .args = node.args },
        .grouped, .move_expr => |inner| callExpr(inner.*),
        else => null,
    };
}

pub const MemberExpr = struct { base: *ast.Expr, name: ast.Ident };

pub fn memberExpr(expr: ast.Expr) ?MemberExpr {
    return switch (expr.kind) {
        .member => |node| .{ .base = node.base, .name = node.name },
        .grouped, .move_expr => |inner| memberExpr(inner.*),
        else => null,
    };
}

pub const IndexExpr = struct { base: *ast.Expr, index: *ast.Expr };

pub fn indexExpr(expr: ast.Expr) ?IndexExpr {
    return switch (expr.kind) {
        .index => |node| .{ .base = node.base, .index = node.index },
        .grouped, .move_expr => |inner| indexExpr(inner.*),
        else => null,
    };
}

pub const MemberCallee = struct { base: *ast.Expr, name: ast.Ident };

pub fn memberCallee(expr: ast.Expr) ?MemberCallee {
    return switch (expr.kind) {
        .member => |node| .{ .base = node.base, .name = node.name },
        .grouped, .move_expr => |inner| memberCallee(inner.*),
        else => null,
    };
}

pub const QualifiedCallee = struct { owner: []const u8, member: ast.Ident };

pub fn qualifiedMemberCallee(expr: ast.Expr) ?QualifiedCallee {
    return switch (expr.kind) {
        .member => |node| switch (node.base.*.kind) {
            .ident => |base_ident| .{ .owner = base_ident.text, .member = node.name },
            else => null,
        },
        .grouped, .move_expr => |inner| qualifiedMemberCallee(inner.*),
        else => null,
    };
}

pub fn reflectionFieldName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped, .move_expr => |inner| reflectionFieldName(inner.*),
        else => null,
    };
}

pub fn taggedUnionCase(union_decl: ast.UnionDecl, name: []const u8) ?ast.UnionCase {
    for (union_decl.cases) |case| {
        if (std.mem.eql(u8, case.name.text, name)) return case;
    }
    return null;
}

pub fn dynCalleeMethodName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |m| m.name.text,
        .grouped, .move_expr => |inner| dynCalleeMethodName(inner.*),
        else => null,
    };
}
