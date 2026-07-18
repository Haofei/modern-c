const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const loader = @import("loader.zig");
const mangle_private = @import("mangle_private.zig");
const parser = @import("parser.zig");

fn expectPrivateMangle(mode: ast.VisibilityMode, expected_a: []const u8, expected_b: []const u8) !void {
    const file_a =
        \\fn helper() -> u32 { return 1; }
        \\fn call_a() -> u32 { return helper(); }
    ;
    const file_b =
        \\fn helper() -> u32 { return 2; }
        \\fn call_b() -> u32 { return helper(); }
    ;
    const source = file_a ++ file_b;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "private_a.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    var module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    module.visibility_mode = mode;
    const boundaries = [_]loader.FileBoundary{
        .{ .start = 0, .path = "private_a.mc" },
        .{ .start = file_a.len, .path = "private_b.mc" },
    };
    const transformed = try mangle_private.transform(arena.allocator(), module, &boundaries);

    var helper_a: ?[]const u8 = null;
    var helper_b: ?[]const u8 = null;
    for (transformed.decls) |decl| {
        if (decl.kind != .fn_decl) continue;
        const fn_decl = decl.kind.fn_decl;
        if (std.mem.eql(u8, fn_decl.name.text, "call_a")) {
            helper_a = fn_decl.body.?.items[0].kind.@"return".?.kind.call.callee.kind.ident.text;
        }
        if (std.mem.eql(u8, fn_decl.name.text, "call_b")) {
            helper_b = fn_decl.body.?.items[0].kind.@"return".?.kind.call.callee.kind.ident.text;
        }
    }
    try std.testing.expectEqualStrings(expected_a, helper_a orelse return error.TestExpectedEqual);
    try std.testing.expectEqualStrings(expected_b, helper_b orelse return error.TestExpectedEqual);
}

test "explicit visibility mangles private collisions without pub opt-in" {
    try expectPrivateMangle(.legacy_pub_opt_in, "helper", "helper");
    try expectPrivateMangle(.explicit_public, "helper__mcp0", "helper__mcp1");
}
