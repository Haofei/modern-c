const std = @import("std");

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const numeric = @import("numeric.zig");

const parseCharLiteral = numeric.parseCharLiteral;
const parseUsizeLiteral = numeric.parseUsizeLiteral;

pub const FixedArrayInfo = struct {
    len: usize,
    child: ast.TypeExpr,
};

// A non-negative integer-literal array index value, or null if the index is not a literal.
pub fn constIndexLiteral(index: ast.Expr) ?usize {
    return switch (index.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .grouped => |inner| constIndexLiteral(inner.*),
        else => null,
    };
}

pub fn parseArrayLen(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?usize {
    return parseArrayLenWithReflect(expr, funcs, globals, null, null);
}

pub fn parseArrayLenWithReflect(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue), reflect: ?eval.ReflectFn, reflect_ctx: ?*anyopaque) ?usize {
    return switch (expr.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .char_literal => |literal| if (parseCharLiteral(literal)) |value|
            if (value <= std.math.maxInt(usize)) @intCast(value) else null
        else
            null,
        .grouped => |inner| parseArrayLenWithReflect(inner.*, funcs, globals, reflect, reflect_ctx),
        .binary => |node| {
            const left = parseArrayLenWithReflect(node.left.*, funcs, globals, reflect, reflect_ctx) orelse return null;
            const right = parseArrayLenWithReflect(node.right.*, funcs, globals, reflect, reflect_ctx) orelse return null;
            return switch (node.op) {
                .add => std.math.add(usize, left, right) catch null,
                .sub => std.math.sub(usize, left, right) catch null,
                .mul => std.math.mul(usize, left, right) catch null,
                .div => if (right == 0) null else @divTrunc(left, right),
                .mod => if (right == 0) null else @mod(left, right),
                .shl => if (right >= @bitSizeOf(usize)) null else std.math.shl(usize, left, right),
                .shr => if (right >= @bitSizeOf(usize)) null else left >> @intCast(right),
                else => null,
            };
        },
        .call, .ident => comptimeUsizeValueWithReflect(expr, funcs, globals, reflect, reflect_ctx),
        else => null,
    };
}

// Fold a comptime expression to a usize using the const-fn evaluator. A
// stack buffer backs the evaluator's scopes so this stays callable from
// type-level array-length helpers without a checker or function builder.
pub fn comptimeUsizeValue(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?usize {
    return comptimeUsizeValueWithReflect(expr, funcs, globals, null, null);
}

pub fn comptimeUsizeValueWithReflect(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue), reflect: ?eval.ReflectFn, reflect_ctx: ?*anyopaque) ?usize {
    if (funcs == null and globals == null) return null;
    var fb_arena: ?std.heap.ArenaAllocator = null;
    defer if (fb_arena) |*a| a.deinit();
    const fold_alloc = eval.tryFoldScratch() orelse blk: {
        fb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        break :blk fb_arena.?.allocator();
    };
    defer if (fb_arena == null) eval.releaseFoldScratch();
    var scope = eval.ComptimeScope.init(fold_alloc);
    scope.funcs = funcs;
    scope.globals = globals;
    scope.reflect = reflect;
    scope.reflect_ctx = reflect_ctx;
    return switch (eval.foldComptimeExpr(&scope, expr)) {
        .value => |v| switch (v) {
            .int => |n| if (n >= 0 and n <= std.math.maxInt(usize)) @intCast(n) else null,
            .void, .boolean, .float, .tag, .bytes, .array, .@"struct" => null,
        },
        else => null,
    };
}

pub fn fixedArrayType(ty: ast.TypeExpr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?FixedArrayInfo {
    return switch (ty.kind) {
        .array => |node| .{ .len = parseArrayLen(node.len, funcs, globals) orelse return null, .child = node.child.* },
        .qualified => |node| fixedArrayType(node.child.*, funcs, globals),
        else => null,
    };
}

pub fn constGetIndexArg(ty: ast.TypeExpr) ?usize {
    return switch (ty.kind) {
        .name => |name| parseUsizeLiteral(name.text),
        else => null,
    };
}
