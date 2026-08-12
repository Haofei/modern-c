const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const ir = @import("ir_inspection.zig");
const module_graph = @import("module_graph.zig");
const module_parser = @import("module_parser.zig");
const parser = @import("parser.zig");

test "writes early inspection facts for parser AST" {
    const source =
        \\#[no_lang_trap]
        \\fn trap_edges(buf: []const u8, i: usize, flag: bool) -> u8 {
        \\    assert(flag);
        \\    return buf[i + 1];
        \\}
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\}
        \\
        \\fn contracts(uart: MmioPtr<Uart16550>, ch: u8) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let x = unchecked.add(ch, 1);
        \\    }
        \\    uart.thr.write(ch, .release);
        \\    uart.thr = ch;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try resolvedSourceDatabase(arena.allocator(), "ir_facts.mc", source);
    defer fixture.deinit(arena.allocator());

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try ir.appendFactsFromResolvedSources(std.testing.allocator, fixture.resolved, &facts);

    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact no_lang_trap_assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact checked_arithmetic_trap") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "op=add") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact no_lang_trap_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact unsafe_contract_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact unchecked_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact mmio_write_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact direct_mmio_assignment") != null);
}

test "builds lower-ir trap edge artifact" {
    const source =
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
        \\    return wrapping.add(a, b);
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_neg(a: wrap<u32>) -> wrap<u32> {
        \\    return -a;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn saturating_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
        \\    return a + b;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try resolvedSourceDatabase(arena.allocator(), "lower_ir.mc", source);
    defer fixture.deinit(arena.allocator());

    const decls = try fixture.resolved.collectDecls(std.testing.allocator);
    defer std.testing.allocator.free(decls);
    var module_ir = try ir.buildModuleIrFromDecls(std.testing.allocator, decls);
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 4), module_ir.functions.len);
    try std.testing.expectEqualStrings("checked_add", module_ir.functions[0].name);
    try std.testing.expect(module_ir.functions[0].no_lang_trap);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[0].trap_edges.len);
    try std.testing.expectEqual(ir.TrapKind.IntegerOverflow, module_ir.functions[0].trap_edges[0].kind);
    try std.testing.expectEqual(ir.TrapSource.checked_arithmetic, module_ir.functions[0].trap_edges[0].source);
    try std.testing.expect(module_ir.functions[0].trap_edges[0].no_lang_trap);

    try std.testing.expectEqualStrings("wrapping_add", module_ir.functions[1].name);
    try std.testing.expectEqual(@as(usize, 0), module_ir.functions[1].trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[1].safe_no_trap_ops.len);
    try std.testing.expectEqualStrings("wrapping.add", module_ir.functions[1].safe_no_trap_ops[0].kind);

    try std.testing.expectEqualStrings("wrapping_neg", module_ir.functions[2].name);
    try std.testing.expectEqual(@as(usize, 0), module_ir.functions[2].trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[2].safe_no_trap_ops.len);
    try std.testing.expectEqualStrings("wrapping.neg", module_ir.functions[2].safe_no_trap_ops[0].kind);

    try std.testing.expectEqualStrings("saturating_add", module_ir.functions[3].name);
    try std.testing.expectEqual(@as(usize, 0), module_ir.functions[3].trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[3].safe_no_trap_ops.len);
    try std.testing.expectEqualStrings("saturating.add", module_ir.functions[3].safe_no_trap_ops[0].kind);
}

const ResolvedFixture = struct {
    parsed: module_parser.ParsedSourceDatabase,
    resolved: module_parser.ResolvedSourceDatabase,

    fn deinit(self: *ResolvedFixture, allocator: std.mem.Allocator) void {
        self.resolved.deinit(allocator);
        self.parsed.deinit(allocator);
    }
};

fn resolvedSourceDatabase(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !ResolvedFixture {
    var graph = module_graph.ModuleGraph{
        .files = try allocator.alloc(module_graph.ModuleFile, 1),
        .imports = try allocator.alloc(module_graph.ImportEdge, 0),
    };
    graph.files[0] = .{
        .id = @enumFromInt(0),
        .canonical_path = try allocator.dupe(u8, path),
        .display_path = try allocator.dupe(u8, path),
        .depth = 0,
        .source_start = 0,
        .source_len = source.len,
    };

    var sources = module_graph.SourceDatabase{
        .files = try allocator.alloc(module_graph.SourceFile, 1),
    };
    sources.files[0] = .{
        .id = @enumFromInt(0),
        .source = try allocator.dupe(u8, source),
        .parser_source = try allocator.dupe(u8, source),
    };

    var reporter = diagnostics.Reporter.init(std.testing.allocator, path, source);
    defer reporter.deinit();
    var parsed = try module_parser.parseSourceDatabase(allocator, graph, sources, &reporter);
    errdefer parsed.deinit(allocator);
    try std.testing.expect(!reporter.has_errors);
    var resolved = try module_parser.resolveParsedSourceDatabase(allocator, parsed);
    errdefer resolved.deinit(allocator);
    return .{
        .parsed = parsed,
        .resolved = resolved,
    };
}

fn expectLowerIrOutOfMemory(source: []const u8, fail_index: usize) !void {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "lower_ir_oom.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    var module_ir = ir.buildModuleIr(failing.allocator(), module) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        return;
    };
    defer module_ir.deinit();

    try std.testing.expect(false);
}

test "lower-ir parameter wrap and sat bookkeeping fails closed on OOM" {
    const source =
        \\fn parameter_bookkeeping(a: wrap<u32>, b: sat<u32>) -> u32 {
        \\    return 0;
        \\}
    ;

    try expectLowerIrOutOfMemory(source, 1);
}

test "lower-ir local wrap and sat bookkeeping fails closed on OOM" {
    const source =
        \\fn local_bookkeeping() -> u32 {
        \\    let x: wrap<u32> = 0;
        \\    let y: sat<u32> = 0;
        \\    return 0;
        \\}
    ;

    try expectLowerIrOutOfMemory(source, 1);
}
