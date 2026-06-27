const std = @import("std");

const ast = @import("ast.zig");
const monomorphize = @import("monomorphize.zig");

const testing = std.testing;
const zero_span = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

test "monomorphize.cloneType substitutes a comptime parameter in an array length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var subst = monomorphize.Subst.init(testing.allocator);
    defer subst.deinit();
    try subst.put("N", .{ .int = 4 });

    const elem = try ast.makePtr(a, ast.TypeExpr{ .span = zero_span, .kind = .{ .name = .{ .text = "u8", .span = zero_span } } });
    const n_ident = ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = "N", .span = zero_span } } };
    const ty = ast.TypeExpr{ .span = zero_span, .kind = .{ .array = .{ .len = n_ident, .child = elem } } };

    var ctx = monomorphize.CloneCtx{ .arena = a, .subst = &subst };
    const cloned = try monomorphize.cloneType(&ctx, ty);
    try testing.expectEqualStrings("4", cloned.kind.array.len.kind.int_literal);
    try testing.expectEqualStrings("u8", cloned.kind.array.child.kind.name.text);
}

test "monomorphize.cloneExpr substitutes comptime params and preserves other idents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var subst = monomorphize.Subst.init(testing.allocator);
    defer subst.deinit();
    try subst.put("N", .{ .int = 8 });

    const left = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = "N", .span = zero_span } } });
    const right = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = "i", .span = zero_span } } });
    const expr = ast.Expr{ .span = zero_span, .kind = .{ .binary = .{ .op = .add, .left = left, .right = right } } };

    const cloned = try monomorphize.cloneExpr(a, expr, &subst);
    try testing.expectEqualStrings("8", cloned.kind.binary.left.kind.int_literal);
    try testing.expectEqualStrings("i", cloned.kind.binary.right.kind.ident.text);
}

test "monomorphize.transform is a no-op when there are no type-generic functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try a.alloc(ast.Decl, 0);
    const module = ast.Module{ .decls = decls };
    const out = try monomorphize.transform(a, module);
    try testing.expectEqual(@as(usize, 0), out.decls.len);
}
