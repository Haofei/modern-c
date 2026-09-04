const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const body_plan = @import("mir_body_plan.zig");

test "body plan builds accepted cleanup and control-flow corpus" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_body_plan_corpus.mc", corpus_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(corpus_source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    try mir.verifyBuiltMir(module, &reporter);
    try std.testing.expect(!reporter.has_errors);

    for (module.functions) |*function| {
        if (function.blocks.len == 0) continue;
        var plan = try body_plan.build(std.testing.allocator, function);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(function.blocks.len, plan.blocks.len);
        try std.testing.expectEqual(function.cleanup_cfg.edges.len, plan.cleanup_edges.len);
    }
}

test "body plan keeps rejecting typed identity drift in accepted MIR" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_body_plan_drift.mc", corpus_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(corpus_source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();

    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "branch_cleanup")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.typed_value_id != null) {
            instruction.typed_value_id = mir.ValueId.fromIndex(function.value_identities.len);
            try std.testing.expectError(error.InvalidValueReference, body_plan.verify(function));
            return;
        }
    };
    return error.TestUnexpectedResult;
}

test "body plan derives successors from verified CFG" {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mir_body_plan_cfg.mc", corpus_source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(corpus_source, &reporter);
    const parsed = try p.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module = try mir.buildFromDecls(std.testing.allocator, parsed.decls);
    defer module.deinit();
    const function = for (module.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "branch_cleanup")) break candidate;
    } else return error.TestUnexpectedResult;
    var plan = try body_plan.build(std.testing.allocator, function);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(function.blocks[0].successors.len, plan.blocks[0].successors.len);
}

const corpus_source =
    \\move struct Guard { id: u32 }
    \\fn make_guard() -> Guard {
    \\    return .{ .id = 1 };
    \\}
    \\#[drop]
    \\fn close_guard(g: *mut Guard) -> void {
    \\    g.id = 0;
    \\}
    \\fn cleanup() -> void {
    \\}
    \\
    \\fn ordinary_defer() -> void {
    \\    defer cleanup();
    \\}
    \\fn ownership_cleanup() -> u32 {
    \\    var g = make_guard();
    \\    return g.id;
    \\}
    \\fn branch_cleanup(flag: bool) -> u32 {
    \\    defer cleanup();
    \\    if flag { return 1; }
    \\    return 0;
    \\}
    \\fn nested_cleanup(flag: bool) -> u32 {
    \\    { defer cleanup(); if flag { return 1; } }
    \\    return 0;
    \\}
;
