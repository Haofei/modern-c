const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const plan = @import("mir_scalar_control_plan.zig");

test "scalar control plan admits checked join and count-down CFGs" {
    const source =
        \\fn adjust(n: u32, flag: bool) -> u32 { var x: u32 = n; if flag { x = x + 1; } else { x = x - 1; } return x; }
        \\fn maybe_inc(n: u32, flag: bool) -> u32 { var x: u32 = n; if flag { x = x + 1; } return x; }
        \\fn count_down(n: u32) -> u32 { var x: u32 = n; while x != 0 { x = x - 1; } return x; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "scalar_cfg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    try std.testing.expect(plan.build(functionByName(&module, "adjust").?) != null);
    try std.testing.expect(plan.build(functionByName(&module, "maybe_inc").?) != null);
    const count_down = plan.build(functionByName(&module, "count_down").?) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.activeTag(count_down) == .count_down);
}

fn functionByName(module: *mir.Module, name: []const u8) ?*mir.Function {
    for (module.functions) |*function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}
