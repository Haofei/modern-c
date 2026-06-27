const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const hir = @import("hir.zig");
const parser = @import("parser.zig");

const appendVerificationFacts = hir.appendVerificationFacts;
const build = hir.build;
const verify = hir.verify;

test "builds HIR CFG for branches and loops" {
    const source =
        \\fn branch(result: Result<u32, Error>, flag: bool) -> u32 {
        \\    if let ok(value) = result {
        \\        return value;
        \\    } else {
        \\        while flag {
        \\            return 0;
        \\        }
        \\    }
        \\    return 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "hir_cfg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_hir = try build(std.testing.allocator, module);
    defer module_hir.deinit();

    try std.testing.expectEqual(@as(usize, 1), module_hir.functions.len);
    try std.testing.expect(module_hir.functions[0].blocks.len >= 5);
}

test "HIR verifier reports fallthrough and no_lang_trap trap edges" {
    const source =
        \\fn missing_return(flag: bool) -> u32 {
        \\    if let value = null {
        \\        return 1;
        \\    }
        \\}
        \\
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn saturating_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_neg(a: wrap<u32>) -> wrap<u32> {
        \\    return -a;
        \\}
        \\
        \\fn trapping_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn calls_trapping(a: u32, b: u32) -> u32 {
        \\    return trapping_add(a, b);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "hir_verify.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendVerificationFacts(std.testing.allocator, module, &facts);

    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=missing_return finding=fallthrough") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=checked_add finding=trap_edge detail=IntegerOverflow no_lang_trap=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=calls_trapping finding=trap_edge detail=CallMayTrap no_lang_trap=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=wrapping_add finding=trap_edge") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=saturating_add finding=trap_edge") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "hir verify fn=wrapping_neg finding=trap_edge") == null);
}

test "HIR verifier reports structured diagnostics" {
    const source =
        \\fn missing_return(flag: bool) -> u32 {
        \\    if let value = null {
        \\        return 1;
        \\    }
        \\}
        \\
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "hir_verify_diagnostics.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    try verify(std.testing.allocator, module, &reporter);

    try std.testing.expect(reporter.has_errors);
    var found_missing_return = false;
    var found_no_lang_trap = false;
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "E_RETURN_MISSING") != null) found_missing_return = true;
        if (std.mem.indexOf(u8, diag.message, "E_NO_LANG_TRAP_EDGE") != null) found_no_lang_trap = true;
    }
    try std.testing.expect(found_missing_return);
    try std.testing.expect(found_no_lang_trap);
}
