const std = @import("std");

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const layout = @import("layout.zig");

const ComptimeScope = eval.ComptimeScope;
const ComptimeValue = eval.ComptimeValue;
const foldComptimeAssign = eval.foldComptimeAssign;
const foldComptimeExpr = eval.foldComptimeExpr;

const zero_span = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

fn testInt(a: std.mem.Allocator, text: []const u8) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .int_literal = text } });
}

fn testBool(a: std.mem.Allocator, value: bool) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .bool_literal = value } });
}

fn testIdent(a: std.mem.Allocator, name: []const u8) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = name, .span = zero_span } } });
}

fn testBinary(a: std.mem.Allocator, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .binary = .{ .op = op, .left = left, .right = right } } });
}

fn testType(name: []const u8) ast.TypeExpr {
    return .{ .span = zero_span, .kind = .{ .name = .{ .text = name, .span = zero_span } } };
}

fn testBitcastCall(a: std.mem.Allocator, target_name: []const u8, arg: ast.Expr) !ast.Expr {
    return .{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "bitcast"),
        .type_args = try a.dupe(ast.TypeExpr, &.{testType(target_name)}),
        .args = try a.dupe(ast.Expr, &.{arg}),
    } } };
}

test "foldComptimeExpr folds the comptime scalar subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    try scope.bind("n", .{ .int = 4 });

    // n == 4  -> true
    const eq = try testBinary(a, .eq, try testIdent(a, "n"), try testInt(a, "4"));
    try std.testing.expect(foldComptimeExpr(&scope, eq.*).value.boolean);

    // (2 + 3) * 2 == 10  -> true
    const sum = try testBinary(a, .add, try testInt(a, "2"), try testInt(a, "3"));
    const product = try testBinary(a, .mul, sum, try testInt(a, "2"));
    const cmp = try testBinary(a, .eq, product, try testInt(a, "10"));
    try std.testing.expect(foldComptimeExpr(&scope, cmp.*).value.boolean);

    // 2 < 1  -> false
    const lt = try testBinary(a, .lt, try testInt(a, "2"), try testInt(a, "1"));
    try std.testing.expect(!foldComptimeExpr(&scope, lt.*).value.boolean);

    // 1 / 0  -> trap
    const div = try testBinary(a, .div, try testInt(a, "1"), try testInt(a, "0"));
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, div.*)) == .trap);

    // unknown identifier -> unknown (no diagnostic)
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, (try testIdent(a, "runtime")).*)) == .unknown);

    // short-circuit: false && <unknown> -> false
    const sc_and = try testBinary(a, .logical_and, try testBool(a, false), try testIdent(a, "runtime"));
    try std.testing.expect(!foldComptimeExpr(&scope, sc_and.*).value.boolean);

    // short-circuit: true || <unknown> -> true
    const sc_or = try testBinary(a, .logical_or, try testBool(a, true), try testIdent(a, "runtime"));
    try std.testing.expect(foldComptimeExpr(&scope, sc_or.*).value.boolean);
}

test "foldComptimeExpr guards full-width integer bitcasts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scope = ComptimeScope.init(a);
    defer scope.deinit();

    const minus_one = ast.Expr{ .span = zero_span, .kind = .{ .unary = .{
        .op = .neg,
        .expr = try testInt(a, "1"),
    } } };

    const signed_128 = try testBitcastCall(a, "i128", minus_one);
    try std.testing.expectEqual(@as(i128, -1), foldComptimeExpr(&scope, signed_128).value.int);

    const unsigned_128 = try testBitcastCall(a, "u128", minus_one);
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, unsigned_128)) == .unknown);
}

test "ComptimeScope records width metadata allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var scope = ComptimeScope.init(failing.allocator());
    defer scope.deinit();

    scope.bindWidth("x", 32) catch {};
    try std.testing.expect(scope.hasOom());
}

test "ComptimeScope records domain metadata allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var scope = ComptimeScope.init(failing.allocator());
    defer scope.deinit();

    var args = [_]ast.TypeExpr{testType("u32")};
    scope.bindTypeInfo("x", .{ .span = zero_span, .kind = .{ .generic = .{
        .base = .{ .text = "wrap", .span = zero_span },
        .args = &args,
    } } }) catch {};
    try std.testing.expect(scope.hasOom());
}

test "foldComptimeExpr records aggregate allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var scope = ComptimeScope.init(failing.allocator());
    defer scope.deinit();

    const expr = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{
        .array_literal = try a.dupe(ast.Expr, &.{(try testInt(a, "1")).*}),
    } });

    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, expr.*)) == .unknown);
    try std.testing.expect(scope.hasOom());
}

test "foldComptimeExpr records Result construction allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var scope = ComptimeScope.init(failing.allocator());
    defer scope.deinit();

    const expr = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "ok"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "1")).*}),
    } } });

    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, expr.*)) == .unknown);
    try std.testing.expect(scope.hasOom());
}

test "foldComptimeExpr records string literal decode allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var scope = ComptimeScope.init(failing.allocator());
    defer scope.deinit();

    const string_lit = try ast.makePtr(std.testing.allocator, ast.Expr{
        .span = zero_span,
        .kind = .{ .string_literal = "\"abc\"" },
    });
    defer std.testing.allocator.destroy(string_lit);
    const expr = ast.Expr{ .span = zero_span, .kind = .{ .member = .{
        .base = string_lit,
        .name = .{ .text = "len", .span = zero_span },
    } } };

    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, expr)) == .unknown);
    try std.testing.expect(scope.hasOom());
}

test "const fn parameter metadata OOM does not silently use untyped arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lhs = ast.Param{ .name = .{ .text = "lhs", .span = zero_span }, .ty = testType("u8") };
    const rhs = ast.Param{ .name = .{ .text = "rhs", .span = zero_span }, .ty = testType("u8") };
    const sum = try testBinary(a, .add, try testIdent(a, "lhs"), try testIdent(a, "rhs"));
    const ret_stmt = ast.Stmt{ .span = zero_span, .kind = .{ .@"return" = sum.* } };
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "checked_add", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{ lhs, rhs }),
        .return_type = testType("u8"),
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{ret_stmt}) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("checked_add", fn_decl);

    const call = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "checked_add"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{ (try testInt(a, "200")).*, (try testInt(a, "100")).* }),
    } } });

    var ok_scope = ComptimeScope.init(std.testing.allocator);
    defer ok_scope.deinit();
    ok_scope.funcs = &funcs;
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&ok_scope, call.*)) == .trap);

    var saw_oom = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var fail_scope = ComptimeScope.init(failing.allocator());
        defer fail_scope.deinit();
        fail_scope.funcs = &funcs;
        const folded = foldComptimeExpr(&fail_scope, call.*);
        if (!fail_scope.hasOom()) continue;
        saw_oom = true;
        switch (folded) {
            .value => |value| switch (value) {
                .int => |n| try std.testing.expect(n != 300),
                else => {},
            },
            else => {},
        }
        break;
    }
    try std.testing.expect(saw_oom);
}

test "comptime array size helper returns unknown on i128 overflow" {
    try std.testing.expectEqual(@as(?i128, 32), layout.comptimeArraySize(@as(usize, 4), 8));
    try std.testing.expect(layout.comptimeArraySize(@as(usize, 2), std.math.maxInt(i128)) == null);
}

test "foldComptimeExpr evaluates const fn calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn is_power_of_two(x: u32) -> bool { return x != 0 && (x & (x - 1)) == 0; }
    const x_param = ast.Param{ .name = .{ .text = "x", .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } } };
    const x_ne_0 = try testBinary(a, .ne, try testIdent(a, "x"), try testInt(a, "0"));
    const x_minus_1 = try testBinary(a, .sub, try testIdent(a, "x"), try testInt(a, "1"));
    const x_and = try testBinary(a, .bit_and, try testIdent(a, "x"), x_minus_1);
    const and_eq_0 = try testBinary(a, .eq, x_and, try testInt(a, "0"));
    const body_expr = try testBinary(a, .logical_and, x_ne_0, and_eq_0);
    const ret_stmt = ast.Stmt{ .span = zero_span, .kind = .{ .@"return" = body_expr.* } };
    const items = try a.dupe(ast.Stmt, &.{ret_stmt});
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "is_power_of_two", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{x_param}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = items },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("is_power_of_two", fn_decl);

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.funcs = &funcs;

    // is_power_of_two(16) -> true
    const call16 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "is_power_of_two"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "16")).*}),
    } } });
    try std.testing.expect(foldComptimeExpr(&scope, call16.*).value.boolean);

    // is_power_of_two(17) -> false
    const call17 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "is_power_of_two"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "17")).*}),
    } } });
    try std.testing.expect(!foldComptimeExpr(&scope, call17.*).value.boolean);

    // unknown function -> unknown (no diagnostic)
    const call_unknown = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "mystery"),
        .type_args = &.{},
        .args = &.{},
    } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, call_unknown.*)) == .unknown);
}

test "foldComptimeExpr evaluates assert statements in const fn calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn require_four(x: u32) -> u32 { assert(x == 4); return x; }
    const x_param = ast.Param{ .name = .{ .text = "x", .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } } };
    const assert_expr = try testBinary(a, .eq, try testIdent(a, "x"), try testInt(a, "4"));
    const assert_stmt = ast.Stmt{ .span = zero_span, .kind = .{ .assert = assert_expr.* } };
    const ret_stmt = ast.Stmt{ .span = zero_span, .kind = .{ .@"return" = (try testIdent(a, "x")).* } };
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "require_four", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{x_param}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{ assert_stmt, ret_stmt }) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("require_four", fn_decl);

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.funcs = &funcs;

    const call_ok = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "require_four"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "4")).*}),
    } } });
    try std.testing.expectEqual(@as(i128, 4), foldComptimeExpr(&scope, call_ok.*).value.int);

    const call_trap = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "require_four"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "5")).*}),
    } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, call_trap.*)) == .trap);
}

fn testU32(name: []const u8) ast.Param {
    return ast.Param{ .name = .{ .text = name, .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } } };
}

fn testStmt(kind: ast.Stmt.Kind) ast.Stmt {
    return ast.Stmt{ .span = zero_span, .kind = kind };
}

test "foldComptimeExpr evaluates a const fn with a while loop and fuel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn count_down(n: u32) -> u32 {
    //     var i: u32 = n;
    //     while i != 0 { i = i - 1; }
    //     return i;
    // }
    const var_i = testStmt(.{ .var_decl = .{
        .names = try a.dupe(ast.Ident, &.{.{ .text = "i", .span = zero_span }}),
        .ty = null,
        .init = (try testIdent(a, "n")).*,
    } });
    const dec = testStmt(.{ .assignment = .{
        .target = (try testIdent(a, "i")).*,
        .value = (try testBinary(a, .sub, try testIdent(a, "i"), try testInt(a, "1"))).*,
    } });
    const while_loop = testStmt(.{ .loop = .{
        .kind = .@"while",
        .label = null,
        .iterable = (try testBinary(a, .ne, try testIdent(a, "i"), try testInt(a, "0"))).*,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{dec}) },
    } });
    const ret = testStmt(.{ .@"return" = (try testIdent(a, "i")).* });
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "count_down", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{testU32("n")}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{ var_i, while_loop, ret }) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("count_down", fn_decl);

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.funcs = &funcs;

    // count_down(5) -> 0
    const call = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "count_down"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "5")).*}),
    } } });
    try std.testing.expectEqual(@as(i128, 0), foldComptimeExpr(&scope, call.*).value.int);
}

fn testArrayLit(a: std.mem.Allocator, vals: []const i128) !*ast.Expr {
    var items = try a.alloc(ast.Expr, vals.len);
    for (vals, 0..) |v, i| {
        const text = try std.fmt.allocPrint(a, "{d}", .{v});
        items[i] = (try testInt(a, text)).*;
    }
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .array_literal = items } });
}

test "foldComptimeExpr folds comptime array literals and indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Arena-backed scope so folded array temporaries are freed with the arena.
    var scope = ComptimeScope.init(a);
    defer scope.deinit();

    const arr = try testArrayLit(a, &.{ 10, 20, 30, 40 });
    // array literal -> array value of length 4
    try std.testing.expectEqual(@as(usize, 4), foldComptimeExpr(&scope, arr.*).value.array.len);

    // arr[2] -> 30
    const idx2 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = arr, .index = try testInt(a, "2") } } });
    try std.testing.expectEqual(@as(i128, 30), foldComptimeExpr(&scope, idx2.*).value.int);

    // arr[4] -> out-of-bounds trap
    const idx4 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = arr, .index = try testInt(a, "4") } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, idx4.*)) == .trap);
}

test "foldComptimeExpr folds comptime aggregate equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scope = ComptimeScope.init(a);
    defer scope.deinit();

    const arr_eq = try testBinary(a, .eq, try testArrayLit(a, &.{ 1, 2, 3 }), try testArrayLit(a, &.{ 1, 2, 3 }));
    try std.testing.expect(foldComptimeExpr(&scope, arr_eq.*).value.boolean);

    const arr_ne = try testBinary(a, .ne, try testArrayLit(a, &.{ 1, 2, 3 }), try testArrayLit(a, &.{ 1, 2, 4 }));
    try std.testing.expect(foldComptimeExpr(&scope, arr_ne.*).value.boolean);

    const left_fields = try a.dupe(ast.StructLiteralField, &.{
        .{ .name = .{ .text = "w", .span = zero_span }, .value = (try testInt(a, "3")).* },
        .{ .name = .{ .text = "h", .span = zero_span }, .value = (try testInt(a, "4")).* },
    });
    const right_fields = try a.dupe(ast.StructLiteralField, &.{
        .{ .name = .{ .text = "h", .span = zero_span }, .value = (try testInt(a, "4")).* },
        .{ .name = .{ .text = "w", .span = zero_span }, .value = (try testInt(a, "3")).* },
    });
    const left = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .struct_literal = left_fields } });
    const right = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .struct_literal = right_fields } });
    const struct_eq = try testBinary(a, .eq, left, right);
    try std.testing.expect(foldComptimeExpr(&scope, struct_eq.*).value.boolean);
}

test "foldComptimeExpr folds a const fn with a for loop over an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn sum(xs: [4]u32) -> u32 {
    //     var total: u32 = 0;
    //     for x in xs { total = total + x; }
    //     return total;
    // }
    const xs_param = ast.Param{ .name = .{ .text = "xs", .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .array = .{ .len = (try testInt(a, "4")).*, .child = try ast.makePtr(a, ast.TypeExpr{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } }) } } } };
    const init_total = testStmt(.{ .var_decl = .{ .names = try a.dupe(ast.Ident, &.{.{ .text = "total", .span = zero_span }}), .ty = null, .init = (try testInt(a, "0")).* } });
    const add = testStmt(.{ .assignment = .{ .target = (try testIdent(a, "total")).*, .value = (try testBinary(a, .add, try testIdent(a, "total"), try testIdent(a, "x"))).* } });
    const for_loop = testStmt(.{ .loop = .{ .kind = .@"for", .label = .{ .text = "x", .span = zero_span }, .iterable = (try testIdent(a, "xs")).*, .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{add}) } } });
    const ret = testStmt(.{ .@"return" = (try testIdent(a, "total")).* });
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "sum", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{xs_param}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{ init_total, for_loop, ret }) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("sum", fn_decl);

    // Arena-backed scope so folded array temporaries are freed with the arena.
    var scope = ComptimeScope.init(a);
    defer scope.deinit();
    scope.funcs = &funcs;

    // sum(.{1, 2, 3, 4}) -> 10
    const call = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "sum"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testArrayLit(a, &.{ 1, 2, 3, 4 })).*}),
    } } });
    try std.testing.expectEqual(@as(i128, 10), foldComptimeExpr(&scope, call.*).value.int);
}

test "foldComptimeExpr folds a const fn with a comptime switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn classify(x: u32) -> u32 {
    //     switch x { 0 => { return 100; }, _ => { return 999; }, }
    // }
    const arm0_body = ast.Block{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{testStmt(.{ .@"return" = (try testInt(a, "100")).* })}) };
    const armw_body = ast.Block{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{testStmt(.{ .@"return" = (try testInt(a, "999")).* })}) };
    const arms = try a.dupe(ast.SwitchArm, &.{
        .{ .patterns = try a.dupe(ast.Pattern, &.{.{ .span = zero_span, .kind = .{ .literal = (try testInt(a, "0")).* } }}), .body = .{ .block = arm0_body } },
        .{ .patterns = try a.dupe(ast.Pattern, &.{.{ .span = zero_span, .kind = .wildcard }}), .body = .{ .block = armw_body } },
    });
    const sw = testStmt(.{ .@"switch" = .{ .subject = (try testIdent(a, "x")).*, .arms = arms } });
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "classify", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{testU32("x")}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{sw}) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("classify", fn_decl);

    var scope = ComptimeScope.init(a);
    defer scope.deinit();
    scope.funcs = &funcs;

    const call0 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{ .callee = try testIdent(a, "classify"), .type_args = &.{}, .args = try a.dupe(ast.Expr, &.{(try testInt(a, "0")).*}) } } });
    const call7 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{ .callee = try testIdent(a, "classify"), .type_args = &.{}, .args = try a.dupe(ast.Expr, &.{(try testInt(a, "7")).*}) } } });
    try std.testing.expectEqual(@as(i128, 100), foldComptimeExpr(&scope, call0.*).value.int);
    try std.testing.expectEqual(@as(i128, 999), foldComptimeExpr(&scope, call7.*).value.int);
}

test "foldComptimeExpr folds comptime aggregate element assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scope = ComptimeScope.init(a);
    defer scope.deinit();
    try scope.bind("xs", .{ .array = try a.dupe(ComptimeValue, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 } }) });

    // xs[1] = 42
    const target = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = try testIdent(a, "xs"), .index = try testInt(a, "1") } } });
    try std.testing.expect(foldComptimeAssign(&scope, target.*, (try testInt(a, "42")).*) == .ok);
    try std.testing.expectEqual(@as(i128, 42), scope.bindings.get("xs").?.array[1].int);

    // xs[5] = 1 -> out-of-bounds trap
    const oob = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = try testIdent(a, "xs"), .index = try testInt(a, "5") } } });
    try std.testing.expect(foldComptimeAssign(&scope, oob.*, (try testInt(a, "1")).*) == .trap);
}

test "foldComptimeExpr folds comptime struct literals and field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Arena-backed scope so folded struct temporaries are freed with the arena.
    var scope = ComptimeScope.init(a);
    defer scope.deinit();

    // .{ .w = 3, .h = 4 }
    const fields = try a.dupe(ast.StructLiteralField, &.{
        .{ .name = .{ .text = "w", .span = zero_span }, .value = (try testInt(a, "3")).* },
        .{ .name = .{ .text = "h", .span = zero_span }, .value = (try testInt(a, "4")).* },
    });
    const lit = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .struct_literal = fields } });

    // r.w -> 3, r.h -> 4
    const w = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .member = .{ .base = lit, .name = .{ .text = "w", .span = zero_span } } } });
    const h = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .member = .{ .base = lit, .name = .{ .text = "h", .span = zero_span } } } });
    try std.testing.expectEqual(@as(i128, 3), foldComptimeExpr(&scope, w.*).value.int);
    try std.testing.expectEqual(@as(i128, 4), foldComptimeExpr(&scope, h.*).value.int);

    // w * h -> 12
    const product = try testBinary(a, .mul, w, h);
    try std.testing.expectEqual(@as(i128, 12), foldComptimeExpr(&scope, product.*).value.int);

    // unknown field -> unknown
    const z = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .member = .{ .base = lit, .name = .{ .text = "z", .span = zero_span } } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, z.*)) == .unknown);
}

test "foldComptimeExpr resolves named const globals via scope.globals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var globals = std.StringHashMap(ComptimeValue).init(std.testing.allocator);
    defer globals.deinit();
    try globals.put("MAX", .{ .int = 4 });

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.globals = &globals;

    // MAX * 2 -> 8
    const expr = try testBinary(a, .mul, try testIdent(a, "MAX"), try testInt(a, "2"));
    try std.testing.expectEqual(@as(i128, 8), foldComptimeExpr(&scope, expr.*).value.int);

    // a local binding shadows the global
    try scope.bind("MAX", .{ .int = 10 });
    try std.testing.expectEqual(@as(i128, 20), foldComptimeExpr(&scope, expr.*).value.int);
}
