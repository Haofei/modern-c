//! C backend literal/static-initializer and constant-fold helpers.

const std = @import("std");

const array_len = @import("array_len.zig");
const ast_bridge = @import("ast_bridge.zig");
const eval = @import("eval.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_type = @import("lower_c_type.zig");
const numeric = @import("numeric.zig");

const LocalInfo = lower_c_model.LocalInfo;
const intTypeRange = lower_c_type.intTypeRange;
pub const parseI128Literal = numeric.parseI128Literal;

pub fn isArrayLiteralExpr(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .array_literal => true,
        .grouped => |inner| isArrayLiteralExpr(inner.*),
        else => false,
    };
}

pub fn isStructLiteralExpr(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .struct_literal => true,
        .grouped => |inner| isStructLiteralExpr(inner.*),
        else => false,
    };
}

pub fn isDirectStaticCInitializer(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .unary => |node| node.op == .neg and isNegativeStaticCOperand(node.expr.*),
        .grouped => |inner| isDirectStaticCInitializer(inner.*),
        else => false,
    };
}

pub fn isNegativeStaticCOperand(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .float_literal => true,
        .grouped => |inner| isNegativeStaticCOperand(inner.*),
        else => false,
    };
}

pub fn emitStaticCInitializer(allocator: std.mem.Allocator, out: *std.ArrayList(u8), expr: ast_bridge.Expr) !bool {
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
            return try emitStaticNegativeOperand(allocator, out, node.expr.*, true);
        },
        else => return false,
    }
}

fn emitStaticNegativeOperand(allocator: std.mem.Allocator, out: *std.ArrayList(u8), expr: ast_bridge.Expr, negated: bool) !bool {
    switch (expr.kind) {
        .int_literal => |literal| {
            if (negated)
                try appendCNegatedIntLiteral(allocator, out, literal)
            else
                try appendCIntLiteral(allocator, out, literal);
            return true;
        },
        .float_literal => |literal| {
            if (negated) try out.append(allocator, '-');
            try appendCFloatLiteral(allocator, out, literal, false);
            return true;
        },
        .grouped => |inner| {
            if (negated) try out.append(allocator, '-');
            try out.appendSlice(allocator, "(");
            if (!try emitStaticNegativeOperand(allocator, out, inner.*, false)) return false;
            try out.appendSlice(allocator, ")");
            return true;
        },
        else => return false,
    }
}

pub fn appendCIntLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8) !void {
    const value = numeric.parseIntegerLiteral(literal) orelse return error.UnsupportedCEmission;
    if (value <= std.math.maxInt(i64)) {
        try out.print(allocator, "{d}", .{value});
        return;
    }
    if (value <= std.math.maxInt(u64)) {
        try out.print(allocator, "((uint64_t)0x{X:0>16}ULL)", .{@as(u64, @intCast(value))});
        return;
    }
    const high: u64 = @truncate(value >> 64);
    const low: u64 = @truncate(value);
    const c_type = if (value <= std.math.maxInt(i128)) "__int128" else "unsigned __int128";
    try out.print(
        allocator,
        "(({s})((((unsigned __int128)0x{X:0>16}ULL) << 64) | ((unsigned __int128)0x{X:0>16}ULL)))",
        .{ c_type, high, low },
    );
}

pub fn appendCIntValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u128) !void {
    var text: [39]u8 = undefined;
    const literal = try std.fmt.bufPrint(&text, "{d}", .{value});
    try appendCIntLiteral(allocator, out, literal);
}

pub fn appendCNegatedIntLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8) !void {
    const magnitude = numeric.parseIntegerLiteral(literal) orelse return error.UnsupportedCEmission;
    if (magnitude == (@as(u128, 1) << 127)) {
        try out.appendSlice(allocator, "(-");
        try appendCIntValue(allocator, out, magnitude - 1);
        try out.appendSlice(allocator, " - 1)");
        return;
    }
    try out.appendSlice(allocator, "-");
    try appendCIntValue(allocator, out, magnitude);
}

pub fn appendCSignedIntValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i128) !void {
    if (value >= 0) return appendCIntValue(allocator, out, @intCast(value));
    const magnitude: u128 = @as(u128, @intCast(-(value + 1))) + 1;
    if (magnitude == (@as(u128, 1) << 127)) {
        try out.appendSlice(allocator, "(-");
        try appendCIntValue(allocator, out, magnitude - 1);
        try out.appendSlice(allocator, " - 1)");
        return;
    }
    try out.append(allocator, '-');
    try appendCIntValue(allocator, out, magnitude);
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
    for (literal) |ch| {
        if (ch != '_') try out.append(allocator, ch);
    }
    if (as_f32) try out.appendSlice(allocator, "f");
}

pub fn appendCFloatValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f64, as_f32: bool) !void {
    const narrowed: f64 = if (as_f32) @floatCast(@as(f32, @floatCast(value))) else value;
    if (std.math.isNan(narrowed)) {
        try out.appendSlice(allocator, if (as_f32) "__builtin_nanf(\"\")" else "__builtin_nan(\"\")");
        return;
    }
    if (std.math.isInf(narrowed)) {
        if (narrowed < 0) try out.append(allocator, '-');
        try out.appendSlice(allocator, if (as_f32) "__builtin_inff()" else "__builtin_inf()");
        return;
    }
    if (narrowed == 0 and std.math.signbit(narrowed)) {
        try out.appendSlice(allocator, if (as_f32) "-0.0f" else "-0.0");
        return;
    }
    try out.print(allocator, "{d}", .{narrowed});
    if (as_f32) try out.append(allocator, 'f');
}

pub fn appendCComptimeFloat(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: eval.ComptimeFloat,
    as_f32: bool,
) !void {
    try appendCFloatBits(allocator, out, value.bits, value.width, as_f32);
}

/// Render a frontend-owned floating constant without requiring callers to
/// retain the evaluator's value representation.
pub fn appendCFloatBits(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bits: u64,
    width: u8,
    as_f32: bool,
) !void {
    if (width != 32 and width != 64) return error.UnsupportedCEmission;
    if (as_f32 or width == 32) {
        const raw_bits: u32 = @truncate(bits);
        try out.print(allocator, "__builtin_bit_cast(float, ((uint32_t)0x{X:0>8}U))", .{raw_bits});
        return;
    }
    try out.print(allocator, "__builtin_bit_cast(double, ((uint64_t)0x{X:0>16}ULL))", .{bits});
}

pub fn negatedLiteralIsI64Min(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .int_literal => |literal| literalMagnitudeIsI64Min(literal),
        .grouped => |inner| negatedLiteralIsI64Min(inner.*),
        else => false,
    };
}

pub fn negatedI128MinLiteral(expr: ast_bridge.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .int_literal => |literal| if ((numeric.parseIntegerLiteral(literal) orelse return null) == (@as(u128, 1) << 127)) literal else null,
        .grouped => |inner| negatedI128MinLiteral(inner.*),
        else => null,
    };
}

pub fn isIntegerLiteralExpr(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .int_literal => true,
        .grouped => |inner| isIntegerLiteralExpr(inner.*),
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

pub fn switchCaseValueSupported(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .char_literal => true,
        .grouped => |inner| switchCaseValueSupported(inner.*),
        .unary => |node| node.op == .neg and switchCaseUnsignedValue(node.expr.*),
        else => false,
    };
}

pub fn switchCaseUnsignedValue(expr: ast_bridge.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .char_literal => true,
        .grouped => |inner| switchCaseUnsignedValue(inner.*),
        else => false,
    };
}

pub fn constIntValue(expr: ast_bridge.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?i128 {
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

pub fn constArrayLenValue(expr: ast_bridge.Expr, funcs: ?*const std.StringHashMap(eval.ComptimeFunction), globals: ?*const std.StringHashMap(eval.ComptimeValue), reflect: ?eval.ReflectFn, reflect_ctx: ?*anyopaque) ?usize {
    return array_len.parseArrayLenWithReflect(expr, funcs, globals, reflect, reflect_ctx);
}
