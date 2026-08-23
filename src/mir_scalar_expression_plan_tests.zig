const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const plan = @import("mir_scalar_expression_plan.zig");

test "scalar expression plan records high-word local cast and checked increment" {
    var module = try parseMir(fixture_source);
    defer module.deinit();
    const actual = plan.build(functionByName(&module, "high_word").?) orelse return error.TestUnexpectedResult;
    switch (actual) {
        .high_word => |high| {
            try std.testing.expectEqualStrings("v", high.parameter.name);
            try std.testing.expectEqualStrings("hi", high.local.name);
            try std.testing.expectEqual(@as(usize, 32), high.shift_amount.value);
            try std.testing.expectEqual(@as(usize, 1), high.increment.value);
            try std.testing.expectEqualStrings("u64", high.cast_source.value_ty.name());
            try std.testing.expectEqualStrings("u32", high.cast_target.value_ty.name());
            try std.testing.expect(high.local.id.isValid());
            try std.testing.expect(high.cast_location.span_id.isValid());
            try std.testing.expect(high.increment_location.span_id.isValid());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "scalar expression plan records call then and then compare in flag-set" {
    var module = try parseMir(fixture_source);
    defer module.deinit();
    const actual = plan.build(functionByName(&module, "flag_set").?) orelse return error.TestUnexpectedResult;
    switch (actual) {
        .flag_set => |flag| {
            try std.testing.expectEqualStrings("addr", flag.address.name);
            try std.testing.expectEqualStrings("mask", flag.mask.name);
            try std.testing.expectEqualStrings("read_word", flag.callee_name);
            try std.testing.expectEqualStrings("u64", flag.call_result.value_ty.name());
            try std.testing.expectEqualStrings("bool", flag.compare_result.value_ty.name());
            try std.testing.expectEqual(@as(usize, 0), flag.zero.value);
            try std.testing.expect(flag.call_location.span_id.isValid());
            try std.testing.expect(flag.and_location.span_id.isValid());
            try std.testing.expect(flag.compare_location.span_id.isValid());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "scalar expression plan fails closed when high-word loses its typed local" {
    const source =
        \\fn high_word(v: u64) -> u32 {
        \\    return ((v >> 32) as u32) + 1;
        \\}
    ;
    var module = try parseMir(source);
    defer module.deinit();
    try std.testing.expect(plan.build(functionByName(&module, "high_word").?) == null);
}

fn parseMir(source: []const u8) !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "scalar_expression_plan.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}

fn functionByName(module: *mir.Module, name: []const u8) ?mir.Function {
    for (module.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

const fixture_source =
    \\fn high_word(v: u64) -> u32 {
    \\    let hi: u32 = (v >> 32) as u32;
    \\    return hi + 1;
    \\}
    \\
    \\fn read_word(addr: usize) -> u64 {
    \\    return (addr as u64) & 0xFF;
    \\}
    \\
    \\fn flag_set(addr: usize, mask: u64) -> bool {
    \\    return (read_word(addr) & mask) != 0;
    \\}
;
