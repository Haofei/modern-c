const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const plan = @import("mir_alloca_hoist_plan.zig");

test "alloca hoist plan admits bounded loop storage" {
    var module = try buildFixture();
    defer module.deinit();
    const result = plan.build(functionByName(&module, "alloca_hoist_run").?) orelse return error.TestUnexpectedResult;
    try std.testing.expect(result.scratch.static_function_storage);
    try std.testing.expectEqual(@as(usize, 256), result.scratch.array_len);
}

test "alloca hoist plan is invariant under function and local renaming" {
    var module = try buildFixture();
    defer module.deinit();
    const function = functionByName(&module, "alloca_hoist_run").?;
    function.name = "renamed_loop";
    for (function.value_identities) |*identity| identity.spelling = "renamed_value";
    try std.testing.expect(plan.build(function) != null);
}

test "alloca hoist plan fails closed for stale bound and trap identities" {
    var module = try buildFixture();
    defer module.deinit();
    const function = functionByName(&module, "alloca_hoist_run").?;
    var changed_bound = false;
    for (function.blocks[1].instructions) |*instruction| {
        if (instruction.kind == .index and instruction.static_index_bound != null) {
            instruction.static_index_bound = 255;
            changed_bound = true;
            break;
        }
    }
    try std.testing.expect(changed_bound);
    try std.testing.expect(plan.build(function) == null);

    var trap_module = try buildFixture();
    defer trap_module.deinit();
    const trapped = functionByName(&trap_module, "alloca_hoist_run").?;
    trapped.trap_edges[0].typed_span_id = .invalid;
    try std.testing.expect(plan.build(trapped) == null);

    var trap_source_module = try buildFixture();
    defer trap_source_module.deinit();
    const wrong_source = functionByName(&trap_source_module, "alloca_hoist_run").?;
    wrong_source.trap_edges[0].source = .bounds_check;
    try std.testing.expect(plan.build(wrong_source) == null);

    var value_module = try buildFixture();
    defer value_module.deinit();
    const stale_value = functionByName(&value_module, "alloca_hoist_run").?;
    stale_value.blocks[0].instructions[0].typed_value_id = .invalid;
    try std.testing.expect(plan.build(stale_value) == null);

    var type_module = try buildFixture();
    defer type_module.deinit();
    const stale_type = functionByName(&type_module, "alloca_hoist_run").?;
    stale_type.type_identities[0].id = .invalid;
    try std.testing.expect(plan.build(stale_type) == null);

    var cfg_module = try buildFixture();
    defer cfg_module.deinit();
    const stale_block = functionByName(&cfg_module, "alloca_hoist_run").?;
    stale_block.blocks[1].typed_successors[5] = .invalid;
    try std.testing.expect(plan.build(stale_block) == null);
}

fn functionByName(module: *mir.Module, name: []const u8) ?*mir.Function {
    for (module.functions) |*function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

fn buildFixture() !mir.Module {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "alloca_hoist.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    return mir.buildFromDecls(std.testing.allocator, parsed.decls);
}

const source =
    \\const ITERS: u32 = 1000000;
    \\const BUF: usize = 256;
    \\export fn alloca_hoist_run() -> u32 {
    \\    var sum: u32 = 0;
    \\    var i: u32 = 0;
    \\    while i < ITERS {
    \\        var scratch: [BUF]u8 = uninit;
    \\        let slot: usize = (i as usize) % BUF;
    \\        scratch[slot] = (i & 0xFF) as u8;
    \\        sum = sum + (scratch[slot] as u32);
    \\        i = i + 1;
    \\    }
    \\    return sum;
    \\}
;
