const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

const Parser = parser.Parser;

test "parser covers MC declaration and statement examples" {
    const source =
        \\extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
        \\global shared_counter: u32 = 0;
        \\extern struct Timespec { sec: i64, nsec: i64, }
        \\type LoadResult = Result<Module, LoadError>;
        \\type RawUart = [*]mut Uart16550;
        \\#[no_lang_trap]
        \\fn boot_entry() -> never { return trap(.Unreachable); }
        \\fn exercise(pa: PAddr, maybe: ?*mut Node, status: Status) -> u32 {
        \\    var sum: u32 = 0;
        \\    unsafe { let uart = mmio.map<Uart16550>(phys(0x1000_0000))?; raw.store<u64>(pa.residue(), uart.raw_lsr.read(.acquire)); }
        \\    if let p = maybe { sum = p.value + 1; }
        \\    switch status { .ready => 1, ok(v) => v + sum, _ => 0, }
        \\    #[unsafe_contract(no_overflow)] { sum = unchecked.add(sum, 1); }
        \\    return (sum & 0xff_u32) << 1;
        \\}
    ;
    var reporter = diagnostics.Reporter{
        .allocator = std.testing.allocator,
        .path = "parser_cases.mc",
        .source = source,
        .diagnostics = .empty,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(allocator);
    defer module.deinit(allocator);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 7), module.decls.len);
    try std.testing.expectEqual(std.meta.Tag(ast.Decl.Kind).global_decl, std.meta.activeTag(module.decls[1].kind));
    try std.testing.expect(module.decls[1].kind.global_decl.ty != null);
    try std.testing.expect(module.decls[1].kind.global_decl.init != null);
}

test "parser accepts qualified generic type arguments" {
    const source = "fn read_user(buf: UserPtr<const u8>) -> void {}\n";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "qualified_type.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(allocator);
    defer module.deinit(allocator);

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const fn_decl = module.decls[0].kind.fn_decl;
    try std.testing.expectEqual(@as(usize, 1), fn_decl.params.len);

    const param_ty = fn_decl.params[0].ty.kind.generic;
    try std.testing.expectEqualStrings("UserPtr", param_ty.base.text);
    try std.testing.expectEqual(@as(usize, 1), param_ty.args.len);

    const qualifier = param_ty.args[0].kind.qualified;
    try std.testing.expectEqual(ast.Mutability.@"const", qualifier.mutability);
    try std.testing.expectEqualStrings("u8", qualifier.child.kind.name.text);
}

test "parser distinguishes relational operators from generic calls" {
    const source =
        \\fn compare(a: u32, b: u32) -> bool { return a < b; }
        \\fn compare_equal(a: u32, b: u32) -> bool { return a >= b; }
        \\fn generic_then_compare(a: u32, b: u32, limit: u32) -> bool { return min<u32>(a, b) < limit; }
        \\fn compare_then_generic(a: u32, b: u32, limit: u32) -> bool { return limit > max<u32>(a, b); }
        \\fn call_generic(pa: PAddr, value: u64) -> void { raw.store<u64>(pa, value); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "relational_vs_generic.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(allocator);
    defer module.deinit(allocator);

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 5), module.decls.len);

    const lt = module.decls[0].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.lt, lt.op);

    const ge = module.decls[1].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.ge, ge.op);

    const generic_lt = module.decls[2].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.lt, generic_lt.op);
    try std.testing.expectEqual(@as(usize, 1), generic_lt.left.kind.call.type_args.len);

    const gt_generic = module.decls[3].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.gt, gt_generic.op);
    try std.testing.expectEqual(@as(usize, 1), gt_generic.right.kind.call.type_args.len);

    const call = module.decls[4].kind.fn_decl.body.?.items[0].kind.expr.kind.call;
    try std.testing.expectEqual(@as(usize, 1), call.type_args.len);
}

test "return statement span covers the whole statement" {
    const source = "fn f() -> u32 { return 1; }\n";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "ret.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());

    const ret = module.decls[0].kind.fn_decl.body.?.items[0];
    try std.testing.expect(std.meta.activeTag(ret.kind) == .@"return");
    // The span runs from the `return` keyword through the terminating `;`,
    // not just the `;`.
    try std.testing.expectEqualStrings("return", source[ret.span.offset .. ret.span.offset + 6]);
    try std.testing.expectEqual(@as(u8, ';'), source[ret.span.offset + ret.span.len - 1]);
}

test "parser requires in after for binding" {
    const good_source = "fn good(xs: []const u32) -> void { for x in xs { } }\n";
    var good_reporter = diagnostics.Reporter.init(std.testing.allocator, "for_good.mc", good_source);
    defer good_reporter.deinit();

    var good_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer good_arena.deinit();

    var good_parser = Parser.init(good_source, &good_reporter);
    const good_module = try good_parser.parseModule(good_arena.allocator());
    defer good_module.deinit(good_arena.allocator());
    try std.testing.expect(!good_reporter.has_errors);

    const bad_source = "fn bad(xs: []const u32) -> void { for x over xs { } }\n";
    var bad_reporter = diagnostics.Reporter.init(std.testing.allocator, "for_bad.mc", bad_source);
    defer bad_reporter.deinit();

    var bad_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer bad_arena.deinit();

    var bad_parser = Parser.init(bad_source, &bad_reporter);
    try std.testing.expectError(error.ParseFailed, bad_parser.parseModule(bad_arena.allocator()));
    try std.testing.expect(bad_reporter.has_errors);
    try std.testing.expectEqualStrings("expected 'in' after for binding", bad_reporter.diagnostics.items[0].message);
}

test "parser recovers across top-level declarations" {
    const source =
        \\const A: u32 = ;
        \\const B: u32 = ;
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "top_recovery.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser.init(source, &reporter);
    try std.testing.expectError(error.ParseFailed, p.parseModule(arena.allocator()));
    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items[0].span.line);
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items[1].span.line);
}

test "parser recovers across block statements" {
    const source =
        \\fn broken() -> void {
        \\    let a: u32 = ;
        \\    return;
        \\    let b: u32 = ;
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "stmt_recovery.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser.init(source, &reporter);
    try std.testing.expectError(error.ParseFailed, p.parseModule(arena.allocator()));
    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items[0].span.line);
    try std.testing.expectEqual(@as(usize, 4), reporter.diagnostics.items[1].span.line);
}

test "parser recovers after malformed impl body" {
    const source =
        \\impl Foo {
        \\    fn bad() -> void { let x: u32 = ; }
        \\}
        \\fn next() -> void { let y: u32 = ; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "impl_recovery.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser.init(source, &reporter);
    try std.testing.expectError(error.ParseFailed, p.parseModule(arena.allocator()));
    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 2), reporter.diagnostics.items[0].span.line);
    try std.testing.expectEqual(@as(usize, 4), reporter.diagnostics.items[1].span.line);
}

test "parser rejects 10k-depth balanced nesting with diagnostic" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);

    try source.appendSlice(std.testing.allocator, "fn too_deep() -> u32 { return ");
    for (0..10_000) |_| try source.append(std.testing.allocator, '(');
    try source.append(std.testing.allocator, '1');
    for (0..10_000) |_| try source.append(std.testing.allocator, ')');
    try source.appendSlice(std.testing.allocator, "; }\n");

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "too_deep.mc", source.items);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser.init(source.items, &reporter);
    try std.testing.expectError(error.ParseFailed, p.parseModule(arena.allocator()));
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_NESTING_TOO_DEEP") != null);
}

test "parser rejects excessive else-if nesting with diagnostic" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);

    try source.appendSlice(std.testing.allocator, "fn too_deep_if() -> void { if true { }");
    for (0..300) |_| try source.appendSlice(std.testing.allocator, " else if true { }");
    try source.appendSlice(std.testing.allocator, " else { } }\n");

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "too_deep_if.mc", source.items);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser.init(source.items, &reporter);
    try std.testing.expectError(error.ParseFailed, p.parseModule(arena.allocator()));
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_NESTING_TOO_DEEP") != null);
}
