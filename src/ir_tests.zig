const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const ir = @import("ir.zig");
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

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "ir_facts.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try ir.appendFacts(std.testing.allocator, module, &facts);

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

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "lower_ir.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_ir = try ir.buildModuleIr(std.testing.allocator, module);
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
