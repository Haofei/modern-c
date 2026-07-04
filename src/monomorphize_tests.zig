const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const monomorphize = @import("monomorphize.zig");
const parser = @import("parser.zig");

const testing = std.testing;
const zero_span = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

fn hasDiagnosticMessage(reporter: *const diagnostics.Reporter, needle: []const u8) bool {
    for (reporter.diagnostics.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return true;
    }
    return false;
}

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

test "monomorphize detects comptime parameter in block array length" {
    const source =
        \\fn block_len_size(comptime N: usize) -> usize {
        \\    return sizeof([{ return N; }]u8);
        \\}
        \\
        \\fn accept_block_len_reflection() -> usize {
        \\    return block_len_size(4);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(testing.allocator, "block_len_size.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    try testing.expect(!reporter.has_errors);

    const specialized = try monomorphize.transformReport(arena.allocator(), module, &reporter);
    try testing.expect(!reporter.has_errors);

    var saw_specialized = false;
    var saw_template = false;
    for (specialized.decls) |decl| {
        if (decl.kind != .fn_decl) continue;
        const fn_decl = decl.kind.fn_decl;
        if (std.mem.eql(u8, fn_decl.name.text, "block_len_size")) saw_template = true;
        if (std.mem.eql(u8, fn_decl.name.text, "block_len_size__4")) {
            saw_specialized = true;
            try testing.expectEqual(@as(usize, 0), fn_decl.params.len);
        }
    }
    try testing.expect(!saw_template);
    try testing.expect(saw_specialized);
}

test "monomorphize total specialization cap reports a focused diagnostic" {
    try testing.expectEqual(@as(usize, 128), monomorphize.default_max_monomorphization_depth);
    try testing.expectEqual(@as(usize, 4096), monomorphize.default_max_monomorphization_instances);

    const source =
        \\fn make(comptime N: usize) -> [N]u8 {
        \\    var scratch: [N]u8 = uninit;
        \\    scratch[0] = 0;
        \\    return scratch;
        \\}
        \\
        \\fn trigger() -> u8 {
        \\    let a: [1]u8 = make(1);
        \\    let b: [2]u8 = make(2);
        \\    let c: [3]u8 = make(3);
        \\    let d: [4]u8 = make(4);
        \\    return a[0] + b[0] + c[0] + d[0];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(testing.allocator, "mono_total_limit.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    try testing.expect(!reporter.has_errors);

    _ = try monomorphize.transformReportOptions(arena.allocator(), module, &reporter, .{
        .limits = .{ .max_instances = 3 },
    });

    try testing.expect(reporter.has_errors);
    try testing.expect(hasDiagnosticMessage(&reporter, "E_MONOMORPHIZATION_LIMIT"));
    try testing.expect(hasDiagnosticMessage(&reporter, "total specialization count"));
    try testing.expect(hasDiagnosticMessage(&reporter, "4 > 3"));
    try testing.expect(!hasDiagnosticMessage(&reporter, "instantiation depth"));
}

test "monomorphize OOM fail-closes instead of returning a clean transform" {
    const source =
        \\fn make(comptime N: usize) -> [N]u8 {
        \\    var scratch: [N]u8 = uninit;
        \\    scratch[0] = 0;
        \\    return scratch;
        \\}
        \\
        \\fn trigger() -> u8 {
        \\    let a: [1]u8 = make(1);
        \\    return a[0];
        \\}
    ;

    var parse_reporter = diagnostics.Reporter.init(testing.allocator, "mono_oom.mc", source);
    defer parse_reporter.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer parse_arena.deinit();

    var p = parser.Parser.init(source, &parse_reporter);
    const module = try p.parseModule(parse_arena.allocator());
    try testing.expect(!parse_reporter.has_errors);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var fail_arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer fail_arena.deinit();

    var reporter = diagnostics.Reporter.init(testing.allocator, "mono_oom.mc", source);
    defer reporter.deinit();

    const result = monomorphize.transformReport(fail_arena.allocator(), module, &reporter);
    if (result) |_| {
        try testing.expect(reporter.has_errors);
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
    }
}

test "monomorphize OOM while synthesizing limit body does not emit empty body" {
    const source =
        \\fn make(comptime N: usize) -> [N]u8 {
        \\    var scratch: [N]u8 = uninit;
        \\    scratch[0] = 0;
        \\    return scratch;
        \\}
        \\
        \\fn trigger() -> u8 {
        \\    let a: [1]u8 = make(1);
        \\    return a[0];
        \\}
    ;

    var parse_reporter = diagnostics.Reporter.init(testing.allocator, "mono_limit_body_oom.mc", source);
    defer parse_reporter.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer parse_arena.deinit();

    var p = parser.Parser.init(source, &parse_reporter);
    const module = try p.parseModule(parse_arena.allocator());
    try testing.expect(!parse_reporter.has_errors);

    var saw_oom = false;
    for (0..256) |fail_index| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var fail_arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer fail_arena.deinit();

        const result = monomorphize.transformReportOptions(fail_arena.allocator(), module, null, .{
            .limits = .{ .max_instances = 0 },
        });
        if (result) |specialized| {
            defer specialized.deinit(fail_arena.allocator());
            for (specialized.decls) |decl| {
                if (decl.kind != .fn_decl) continue;
                const fn_decl = decl.kind.fn_decl;
                if (!std.mem.startsWith(u8, fn_decl.name.text, "make__")) continue;
                try testing.expect(fn_decl.body.?.items.len > 0);
            }
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;
        }
    }
    try testing.expect(saw_oom);
}
