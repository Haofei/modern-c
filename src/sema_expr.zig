const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const numeric = @import("numeric.zig");
const sema_model = @import("sema_model.zig");

const Context = sema_model.Context;
const integerLiteralValue = numeric.integerLiteralValue;
const isIdentNamed = ast_query.isIdentNamed;

pub fn isArrayLiteral(expr: ast.Expr) bool {
    return arrayLiteralItems(expr) != null;
}

pub fn arrayLiteralItems(expr: ast.Expr) ?[]const ast.Expr {
    return switch (expr.kind) {
        .array_literal => |items| items,
        .grouped => |inner| arrayLiteralItems(inner.*),
        else => null,
    };
}

pub fn isStructLiteral(expr: ast.Expr) bool {
    return structLiteralFields(expr) != null;
}

pub fn structLiteralFields(expr: ast.Expr) ?[]const ast.StructLiteralField {
    return switch (expr.kind) {
        .struct_literal => |fields| fields,
        .grouped => |inner| structLiteralFields(inner.*),
        else => null,
    };
}

pub fn isNullLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .null_literal => true,
        .grouped => |inner| isNullLiteral(inner.*),
        else => false,
    };
}

pub fn isStaticGlobalInitializer(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .int_literal, .float_literal, .bool_literal, .null_literal, .void_literal, .enum_literal, .string_literal, .char_literal => true,
        .ident => |ident| (if (ctx.globals) |globals| globals.contains(ident.text) else false) or
            (if (ctx.functions) |functions| functions.contains(ident.text) else false),
        .unary => |node| node.op == .neg and (integerLiteralValue(node.expr.*) != null or negativeFloatLiteralOperand(node.expr.*)),
        // An explicit conversion of a static operand (`0 as u32`) is itself static;
        // the comptime folder applies the cast, and the C backend emits it inline.
        .cast => |node| isStaticGlobalInitializer(node.value.*, ctx),
        .grouped => |inner| isStaticGlobalInitializer(inner.*, ctx),
        .address_of => |inner| isStaticGlobalAddressTarget(inner.*, ctx),
        .array_literal => |items| allStaticGlobalInitializerItems(items, ctx),
        .struct_literal => |fields| allStaticGlobalInitializerFields(fields, ctx),
        // `atomic.init(<static>)` lowers to a plain `= value` initializer, so a
        // global atomic with a static seed (e.g. an interrupt-shared counter) is a
        // valid static global.
        .call => |node| isAtomicInitCallee(node.callee.*) and node.args.len == 1 and isStaticGlobalInitializer(node.args[0], ctx),
        else => false,
    };
}

pub fn addressOfOperand(expr: ast.Expr) ?*ast.Expr {
    return switch (expr.kind) {
        .address_of => |inner| inner,
        .grouped => |inner| addressOfOperand(inner.*),
        else => null,
    };
}

fn negativeFloatLiteralOperand(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .float_literal => true,
        .grouped => |inner| negativeFloatLiteralOperand(inner.*),
        else => false,
    };
}

fn isAtomicInitCallee(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |m| isIdentNamed(m.base.*, "atomic") and std.mem.eql(u8, m.name.text, "init"),
        .grouped => |inner| isAtomicInitCallee(inner.*),
        else => false,
    };
}

fn allStaticGlobalInitializerItems(items: []const ast.Expr, ctx: Context) bool {
    for (items) |item| {
        if (!isStaticGlobalInitializer(item, ctx)) return false;
    }
    return true;
}

fn allStaticGlobalInitializerFields(fields: []const ast.StructLiteralField, ctx: Context) bool {
    for (fields) |field| {
        if (!isStaticGlobalInitializer(field.value, ctx)) return false;
    }
    return true;
}

fn isStaticGlobalAddressTarget(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| if (ctx.globals) |globals| globals.contains(ident.text) else false,
        .member => |node| isStaticGlobalAddressTarget(node.base.*, ctx),
        .index => |node| isStaticGlobalAddressTarget(node.base.*, ctx) and isStaticGlobalInitializer(node.index.*, ctx),
        .grouped => |inner| isStaticGlobalAddressTarget(inner.*, ctx),
        else => false,
    };
}
