const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

pub const zspan = diagnostics.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

pub fn id(text: []const u8) ast.Ident {
    return .{ .text = text, .span = zspan };
}

pub fn ptr(arena: std.mem.Allocator, comptime T: type, value: T) std.mem.Allocator.Error!*T {
    const p = try arena.create(T);
    p.* = value;
    return p;
}

pub fn nameType(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!ast.TypeExpr {
    _ = arena;
    return .{ .span = zspan, .kind = .{ .name = id(text) } };
}

pub fn mutPtrType(arena: std.mem.Allocator, child: ast.TypeExpr) std.mem.Allocator.Error!ast.TypeExpr {
    return .{ .span = zspan, .kind = .{ .pointer = .{ .mutability = .mut, .child = try ptr(arena, ast.TypeExpr, child) } } };
}

pub fn identExpr(text: []const u8) ast.Expr {
    return .{ .span = zspan, .kind = .{ .ident = id(text) } };
}

pub fn intExpr(text: []const u8) ast.Expr {
    return .{ .span = zspan, .kind = .{ .int_literal = text } };
}

pub fn memberExpr(arena: std.mem.Allocator, base: ast.Expr, field: []const u8) std.mem.Allocator.Error!ast.Expr {
    return .{ .span = zspan, .kind = .{ .member = .{ .base = try ptr(arena, ast.Expr, base), .name = id(field) } } };
}

pub fn addrOf(arena: std.mem.Allocator, inner: ast.Expr) std.mem.Allocator.Error!ast.Expr {
    return .{ .span = zspan, .kind = .{ .address_of = try ptr(arena, ast.Expr, inner) } };
}

pub fn selfMember(arena: std.mem.Allocator, field: []const u8) std.mem.Allocator.Error!ast.Expr {
    return memberExpr(arena, identExpr("self"), field);
}

pub fn callExpr(arena: std.mem.Allocator, callee: []const u8, args: []ast.Expr) std.mem.Allocator.Error!ast.Expr {
    return .{ .span = zspan, .kind = .{ .call = .{
        .callee = try ptr(arena, ast.Expr, identExpr(callee)),
        .type_args = &.{},
        .args = args,
    } } };
}

pub fn assignStmt(target: ast.Expr, value: ast.Expr) ast.Stmt {
    return .{ .span = zspan, .kind = .{ .assignment = .{ .target = target, .value = value } } };
}

pub fn boolPattern(value: bool) ast.Pattern {
    return .{ .span = zspan, .kind = .{ .literal = .{ .span = zspan, .kind = .{ .bool_literal = value } } } };
}

pub fn ifCondBlock(arena: std.mem.Allocator, cond: ast.Expr, body: []ast.Stmt) std.mem.Allocator.Error!ast.Stmt {
    var arms = try arena.alloc(ast.SwitchArm, 2);
    var true_pats = try arena.alloc(ast.Pattern, 1);
    true_pats[0] = boolPattern(true);
    var false_pats = try arena.alloc(ast.Pattern, 1);
    false_pats[0] = boolPattern(false);
    arms[0] = .{ .patterns = true_pats, .body = .{ .block = .{ .span = zspan, .items = body } } };
    arms[1] = .{ .patterns = false_pats, .body = .{ .block = .{ .span = zspan, .items = &.{} } } };
    return .{ .span = zspan, .kind = .{ .@"switch" = .{ .subject = cond, .arms = arms } } };
}

pub fn whileTrueBlock(body: []ast.Stmt) std.mem.Allocator.Error!ast.Stmt {
    return .{ .span = zspan, .kind = .{ .loop = .{
        .kind = .@"while",
        .label = null,
        .iterable = .{ .span = zspan, .kind = .{ .bool_literal = true } },
        .body = .{ .span = zspan, .items = body },
    } } };
}

pub fn ifElseBlock(arena: std.mem.Allocator, cond: ast.Expr, then_body: []ast.Stmt, else_body: []ast.Stmt) std.mem.Allocator.Error!ast.Stmt {
    var arms = try arena.alloc(ast.SwitchArm, 2);
    var true_pats = try arena.alloc(ast.Pattern, 1);
    true_pats[0] = boolPattern(true);
    var false_pats = try arena.alloc(ast.Pattern, 1);
    false_pats[0] = boolPattern(false);
    arms[0] = .{ .patterns = true_pats, .body = .{ .block = .{ .span = zspan, .items = then_body } } };
    arms[1] = .{ .patterns = false_pats, .body = .{ .block = .{ .span = zspan, .items = else_body } } };
    return .{ .span = zspan, .kind = .{ .@"switch" = .{ .subject = cond, .arms = arms } } };
}

pub fn ifNotReturnFalse(arena: std.mem.Allocator) std.mem.Allocator.Error!ast.Stmt {
    const not_r: ast.Expr = .{ .span = zspan, .kind = .{ .unary = .{ .op = .logical_not, .expr = try ptr(arena, ast.Expr, identExpr("r")) } } };
    var body = try arena.alloc(ast.Stmt, 1);
    body[0] = .{ .span = zspan, .kind = .{ .@"return" = .{ .span = zspan, .kind = .{ .bool_literal = false } } } };
    return ifCondBlock(arena, not_r, body);
}

pub fn ifStateEq(arena: std.mem.Allocator, n: usize, body: []ast.Stmt) std.mem.Allocator.Error!ast.Stmt {
    const n_str = try std.fmt.allocPrint(arena, "{d}", .{n});
    const cond: ast.Expr = .{ .span = zspan, .kind = .{ .binary = .{
        .op = .eq,
        .left = try ptr(arena, ast.Expr, try selfMember(arena, "state")),
        .right = try ptr(arena, ast.Expr, intExpr(n_str)),
    } } };
    return ifCondBlock(arena, cond, body);
}

pub fn dupIdents(arena: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error![]ast.Ident {
    var out = try arena.alloc(ast.Ident, names.len);
    for (names, 0..) |n, i| out[i] = id(n);
    return out;
}

pub fn typeName(t: ast.TypeExpr) ?[]const u8 {
    return switch (t.kind) {
        .name => |n| n.text,
        else => null,
    };
}

pub fn arrayElemTypeName(t: ast.TypeExpr) ?[]const u8 {
    return switch (t.kind) {
        .array => |a| typeName(a.child.*),
        else => null,
    };
}

pub fn paramCarrierTypeName(t: ast.TypeExpr) ?[]const u8 {
    return switch (t.kind) {
        .name => |n| n.text,
        .array => |a| typeName(a.child.*),
        .qualified => |q| paramCarrierTypeName(q.child.*),
        .pointer => |p| paramCarrierTypeName(p.child.*),
        .raw_many_pointer => |p| paramCarrierTypeName(p.child.*),
        .slice => |s| paramCarrierTypeName(s.child.*),
        else => null,
    };
}

pub fn isScalarIntName(tn: []const u8) bool {
    const names = [_][]const u8{ "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "usize", "isize", "char" };
    for (names) |n| if (std.mem.eql(u8, tn, n)) return true;
    return false;
}
