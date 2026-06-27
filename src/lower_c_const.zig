//! C backend literal/static-initializer and constant-fold helpers.

const std = @import("std");

const array_len = @import("array_len.zig");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const eval = @import("eval.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const numeric = @import("numeric.zig");

const isIdentNamed = ast_query.isIdentNamed;
const LocalInfo = lower_c_model.LocalInfo;
const intTypeRange = lower_c_type.intTypeRange;
pub const parseI128Literal = numeric.parseI128Literal;

pub fn isStaticCInitializer(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .float_literal, .bool_literal, .null_literal, .void_literal, .enum_literal, .string_literal, .char_literal => true,
        .address_of => true,
        .cast => |node| isStaticCInitializer(node.value.*),
        .unary => |node| node.op == .neg and isNegativeStaticCOperand(node.expr.*),
        .grouped => |inner| isStaticCInitializer(inner.*),
        else => false,
    };
}

pub fn isArrayLiteralExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .array_literal => true,
        .grouped => |inner| isArrayLiteralExpr(inner.*),
        else => false,
    };
}

pub fn isStructLiteralExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .struct_literal => true,
        .grouped => |inner| isStructLiteralExpr(inner.*),
        else => false,
    };
}

pub fn isDirectStaticCInitializer(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unary => |node| node.op == .neg and isNegativeStaticCOperand(node.expr.*),
        .grouped => |inner| isDirectStaticCInitializer(inner.*),
        else => false,
    };
}

pub fn isNegativeStaticCOperand(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .float_literal => true,
        .grouped => |inner| isNegativeStaticCOperand(inner.*),
        else => false,
    };
}

pub fn emitStaticCInitializer(allocator: std.mem.Allocator, out: *std.ArrayList(u8), expr: ast.Expr) !bool {
    switch (expr.kind) {
        .grouped => |inner| {
            if (!isDirectStaticCInitializer(inner.*)) return false;
            try out.appendSlice(allocator, "(");
            if (!try emitStaticCInitializer(allocator, out, inner.*)) return false;
            try out.appendSlice(allocator, ")");
            return true;
        },
        .unary => |node| {
            if (node.op != .neg) return false;
            if (!isNegativeStaticCOperand(node.expr.*)) return false;
            try out.appendSlice(allocator, "-");
            return try emitStaticNegativeOperand(allocator, out, node.expr.*);
        },
        else => return false,
    }
}

fn emitStaticNegativeOperand(allocator: std.mem.Allocator, out: *std.ArrayList(u8), expr: ast.Expr) !bool {
    switch (expr.kind) {
        .int_literal => |literal| {
            try appendCIntLiteral(allocator, out, literal);
            return true;
        },
        .float_literal => |literal| {
            try appendCFloatLiteral(allocator, out, literal, false);
            return true;
        },
        .grouped => |inner| {
            try out.appendSlice(allocator, "(");
            if (!try emitStaticNegativeOperand(allocator, out, inner.*)) return false;
            try out.appendSlice(allocator, ")");
            return true;
        },
        else => return false,
    }
}

pub fn staticCInitializer(expr: ast.Expr, static_initializers: anytype, functions: anytype, allocator: std.mem.Allocator) ?ast.Expr {
    return switch (expr.kind) {
        .ident => |ident| static_initializers.get(ident.text) orelse if (functions.contains(ident.text)) expr else null,
        .grouped => |inner| if (staticCInitializer(inner.*, static_initializers, functions, allocator)) |resolved| resolved else if (isStaticCInitializer(expr)) expr else null,
        .cast => |node| if (staticCInitializer(node.value.*, static_initializers, functions, allocator)) |resolved| blk: {
            const value = allocator.create(ast.Expr) catch break :blk null;
            value.* = resolved;
            break :blk .{ .span = expr.span, .kind = .{ .cast = .{ .value = value, .ty = node.ty } } };
        } else if (isStaticCInitializer(expr)) expr else null,
        .call => |node| if (isAtomicInitCallee(node.callee.*) and node.args.len == 1) staticCInitializer(node.args[0], static_initializers, functions, allocator) else null,
        else => if (isStaticCInitializer(expr)) expr else null,
    };
}

fn isAtomicInitCallee(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |m| isIdentNamed(m.base.*, "atomic") and std.mem.eql(u8, m.name.text, "init"),
        .grouped => |inner| isAtomicInitCallee(inner.*),
        else => false,
    };
}

pub fn appendCIntLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8) !void {
    for (literal) |ch| {
        if (ch != '_') try out.append(allocator, ch);
    }
}

pub fn cFloatSpecialText(literal: []const u8, as_f32: bool) ?[]const u8 {
    if (std.mem.eql(u8, literal, "inf")) return if (as_f32) "__builtin_inff()" else "__builtin_inf()";
    if (std.mem.eql(u8, literal, "nan")) return if (as_f32) "__builtin_nanf(\"\")" else "__builtin_nan(\"\")";
    return null;
}

pub fn appendCFloatLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8, as_f32: bool) !void {
    if (cFloatSpecialText(literal, as_f32)) |text| {
        try out.appendSlice(allocator, text);
        return;
    }
    try out.appendSlice(allocator, literal);
    if (as_f32) try out.appendSlice(allocator, "f");
}

pub fn negatedLiteralIsI64Min(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal => |literal| literalMagnitudeIsI64Min(literal),
        .grouped => |inner| negatedLiteralIsI64Min(inner.*),
        else => false,
    };
}

fn literalMagnitudeIsI64Min(literal: []const u8) bool {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (literal) |ch| {
        if (ch == '_') continue;
        if (n >= buf.len) return false;
        buf[n] = ch;
        n += 1;
    }
    const value = std.fmt.parseInt(u128, buf[0..n], 0) catch return false;
    return value == (@as(u128, 1) << 63);
}

pub fn switchCaseValueSupported(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .char_literal => true,
        .grouped => |inner| switchCaseValueSupported(inner.*),
        .unary => |node| node.op == .neg and switchCaseUnsignedValue(node.expr.*),
        else => false,
    };
}

pub fn switchCaseUnsignedValue(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .char_literal => true,
        .grouped => |inner| switchCaseUnsignedValue(inner.*),
        else => false,
    };
}

pub fn constIntValue(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?i128 {
    return switch (expr.kind) {
        .int_literal => |literal| parseI128Literal(literal),
        .grouped => |inner| constIntValue(inner.*, locals),
        .unary => |node| if (node.op == .neg) blk: {
            const v = constIntValue(node.expr.*, locals) orelse break :blk null;
            break :blk std.math.negate(v) catch null;
        } else null,
        .ident => |ident| if (locals) |ls| (if (ls.get(ident.text)) |info| info.const_int else null) else null,
        .binary => |node| blk: {
            const l = constIntValue(node.left.*, locals) orelse break :blk null;
            const r = constIntValue(node.right.*, locals) orelse break :blk null;
            break :blk switch (node.op) {
                .add => std.math.add(i128, l, r) catch null,
                .sub => std.math.sub(i128, l, r) catch null,
                .mul => std.math.mul(i128, l, r) catch null,
                else => null,
            };
        },
        else => null,
    };
}

pub fn constBinaryProvenNoOverflow(node: anytype, target_name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) bool {
    switch (node.op) {
        .add, .sub, .mul => {},
        else => return false,
    }
    const l = constIntValue(node.left.*, locals) orelse return false;
    const r = constIntValue(node.right.*, locals) orelse return false;
    const range = intTypeRange(target_name) orelse return false;
    const ll: i256 = l;
    const rr: i256 = r;
    const result: i256 = switch (node.op) {
        .add => ll + rr,
        .sub => ll - rr,
        .mul => ll * rr,
        else => unreachable,
    };
    return result >= @as(i256, range.min) and result <= @as(i256, range.max);
}

pub fn constArrayLenValue(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue), reflect: ?eval.ReflectFn, reflect_ctx: ?*anyopaque) ?usize {
    return array_len.parseArrayLenWithReflect(expr, funcs, globals, reflect, reflect_ctx);
}
