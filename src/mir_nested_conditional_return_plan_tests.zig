const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const plan = @import("mir_nested_conditional_return_plan.zig");
const parser = @import("parser.zig");

test "nested conditional return plan records classify without syntax" {
    const source =
        \\fn classify(x: u32, flag: bool) -> u32 {
        \\    if !flag { return 5; } else if x > 10 { return 6; } else { return 7; }
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bool_switch.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const actual = plan.build(module.functions[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("flag", actual.flag.name);
    try std.testing.expectEqualStrings("x", actual.x.name);
    try std.testing.expectEqual(@as(usize, 10), actual.comparison_limit.value);
    try std.testing.expectEqual(@as(usize, 5), actual.first_return.value);
    try std.testing.expectEqual(@as(usize, 6), actual.second_return.value);
    try std.testing.expectEqual(@as(usize, 7), actual.final_return.value);
}

test "nested conditional return plan fails closed for a stale comparison identity" {
    var module = try buildClassify();
    defer module.deinit();
    for (module.functions[0].blocks[3].instructions) |*instruction| {
        if (instruction.kind == .binary and std.mem.eql(u8, instruction.detail, "gt")) {
            instruction.typed_right_operand_span_id = .invalid;
            break;
        }
    }
    try std.testing.expect(plan.build(module.functions[0]) == null);
}

fn buildClassify() !mir.Module {
    const source =
        \\fn classify(x: u32, flag: bool) -> u32 {
        \\    if !flag { return 5; } else if x > 10 { return 6; } else { return 7; }
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bool_switch.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}
