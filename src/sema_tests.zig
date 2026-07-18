const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const monomorphize = @import("monomorphize.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const sema_model = @import("sema_model.zig");

fn checkSource(source: []const u8, reporter: *diagnostics.Reporter) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = sema.Checker.init(reporter);
    checker.checkModule(module);
}

fn hasDiagnosticCode(reporter: *const diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, code) != null) return true;
    }
    return false;
}

fn countDiagnosticCode(reporter: *const diagnostics.Reporter, code: []const u8) usize {
    var count: usize = 0;
    for (reporter.diagnostics.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, code) != null) count += 1;
    }
    return count;
}

fn parseWithAllocator(source: []const u8, allocator: std.mem.Allocator, reporter: *diagnostics.Reporter) !ast.Module {
    var p = parser.Parser.init(source, reporter);
    return p.parseModule(allocator);
}

fn checkVisibilityMode(source: []const u8, imported_offset: usize, mode: ast.VisibilityMode) !bool {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "visibility_root.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var module = try parseWithAllocator(source, arena.allocator(), &reporter);
    defer module.deinit(arena.allocator());
    module.visibility_mode = mode;
    const boundaries = [_]diagnostics.FileBoundary{
        .{ .start = 0, .path = "visibility_root.mc" },
        .{ .start = imported_offset, .path = "visibility_lib.mc" },
    };
    var checker = sema.Checker.init(&reporter);
    checker.file_boundaries = &boundaries;
    checker.checkModule(module);
    return hasDiagnosticCode(&reporter, "E_PRIVATE_IMPORT");
}

test "explicit visibility is independent of unrelated pub declarations" {
    const importer = "fn use_hidden() -> u32 { return hidden(); }\n";
    const private_library = "fn hidden() -> u32 { return 1; }\n";
    const private_library_with_unrelated_pub = private_library ++ "pub fn unrelated() -> u32 { return 2; }\n";
    const public_library = "pub fn hidden() -> u32 { return 1; }\n";

    try std.testing.expect(!try checkVisibilityMode(importer ++ private_library, importer.len, .legacy_pub_opt_in));
    try std.testing.expect(try checkVisibilityMode(importer ++ private_library_with_unrelated_pub, importer.len, .legacy_pub_opt_in));

    try std.testing.expect(try checkVisibilityMode(importer ++ private_library, importer.len, .explicit_public));
    try std.testing.expect(try checkVisibilityMode(importer ++ private_library_with_unrelated_pub, importer.len, .explicit_public));
    try std.testing.expect(!try checkVisibilityMode(importer ++ public_library, importer.len, .explicit_public));
}

test "move CFG skeleton joins branch states through worklist" {
    var cfg = sema_model.MoveCfg.init(std.testing.allocator);
    defer cfg.deinit();

    const entry = try cfg.addBlock(.entry);
    const then_block = try cfg.addBlock(.statement);
    const else_block = try cfg.addBlock(.statement);
    const join = try cfg.addBlock(.branch_join);
    try cfg.addEdge(entry, then_block, .branch);
    try cfg.addEdge(entry, else_block, .branch);
    try cfg.addEdge(then_block, join, .normal);
    try cfg.addEdge(else_block, join, .normal);

    var worklist = try sema_model.MoveCfgWorklist.init(std.testing.allocator, &cfg, entry, .{});
    defer worklist.deinit();

    try std.testing.expectEqual(entry, worklist.pop().?);
    _ = try worklist.propagateSuccessors(entry, worklist.state(entry).?);
    try std.testing.expectEqual(then_block, worklist.pop().?);
    try std.testing.expectEqual(else_block, worklist.pop().?);

    _ = try worklist.propagateSuccessors(then_block, worklist.state(then_block).?.withMoved(0));
    _ = try worklist.propagateSuccessors(else_block, worklist.state(else_block).?.withMoved(1));

    const joined = worklist.state(join) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0b11), joined.moved_mask);
    try std.testing.expectEqual(join, worklist.pop().?);
}

test "move CFG skeleton requeues loop head on backedge state change" {
    var cfg = sema_model.MoveCfg.init(std.testing.allocator);
    defer cfg.deinit();

    const entry = try cfg.addBlock(.entry);
    const loop_head = try cfg.addBlock(.loop_head);
    const body = try cfg.addBlock(.statement);
    try cfg.addEdge(entry, loop_head, .normal);
    try cfg.addEdge(loop_head, body, .normal);
    try cfg.addEdge(body, loop_head, .backedge);

    var worklist = try sema_model.MoveCfgWorklist.init(std.testing.allocator, &cfg, entry, .{});
    defer worklist.deinit();

    try std.testing.expectEqual(entry, worklist.pop().?);
    _ = try worklist.propagateSuccessors(entry, worklist.state(entry).?);
    try std.testing.expectEqual(loop_head, worklist.pop().?);
    _ = try worklist.propagateSuccessors(loop_head, worklist.state(loop_head).?);
    try std.testing.expectEqual(body, worklist.pop().?);

    _ = try worklist.propagateSuccessors(body, worklist.state(body).?.withMoved(2));
    const loop_state = worklist.state(loop_head) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0b100), loop_state.moved_mask);
    try std.testing.expectEqual(loop_head, worklist.pop().?);
}

test "move CFG skeleton carries early-exit state to exit block" {
    var cfg = sema_model.MoveCfg.init(std.testing.allocator);
    defer cfg.deinit();

    const entry = try cfg.addBlock(.entry);
    const body = try cfg.addBlock(.statement);
    const exit = try cfg.addBlock(.exit);
    try cfg.addEdge(entry, body, .normal);
    try cfg.addEdge(body, exit, .early_exit);

    var worklist = try sema_model.MoveCfgWorklist.init(std.testing.allocator, &cfg, entry, .{});
    defer worklist.deinit();

    try std.testing.expectEqual(entry, worklist.pop().?);
    _ = try worklist.propagateSuccessors(entry, worklist.state(entry).?);
    try std.testing.expectEqual(body, worklist.pop().?);
    _ = try worklist.propagateSuccessors(body, worklist.state(body).?.withMoved(3));

    const exit_state = worklist.state(exit) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0b1000), exit_state.moved_mask);
    try std.testing.expectEqual(exit, worklist.pop().?);
}

test "move dynamic-place policy separates symbolic identity from overlap" {
    const root: sema_model.MovePlace = .{ .root = "arr" };
    const symbolic_i = root.project(.{ .symbolic_index = "i" }).?;
    const same_symbolic_i = root.project(.{ .symbolic_index = "i" }).?;
    const symbolic_j = root.project(.{ .symbolic_index = "j" }).?;
    const constant_zero = root.project(.{ .constant_index = 0 }).?;
    const constant_one = root.project(.{ .constant_index = 1 }).?;
    const wildcard = root.project(.wildcard_index).?;

    try std.testing.expect(symbolic_i.eql(same_symbolic_i));
    try std.testing.expect(symbolic_i.conflicts(same_symbolic_i));
    try std.testing.expect(!symbolic_i.eql(symbolic_j));
    try std.testing.expect(symbolic_i.conflicts(symbolic_j));
    try std.testing.expect(!symbolic_i.eql(constant_zero));
    try std.testing.expect(symbolic_i.conflicts(constant_zero));
    try std.testing.expect(!constant_zero.conflicts(constant_one));
    try std.testing.expect(wildcard.conflicts(symbolic_i));
    try std.testing.expect(wildcard.conflicts(constant_zero));
}

test "move dynamic-place policy keeps wildcard indexes behind field boundaries" {
    const root: sema_model.MovePlace = .{ .root = "arr" };
    const field = root.project(.{ .field = "items" }).?;
    const wildcard = root.project(.wildcard_index).?;
    const symbolic = root.project(.{ .symbolic_index = "i" }).?;

    try std.testing.expectEqual(
        sema_model.MovePlaceProjectionRelation.disjoint,
        sema_model.movePlaceProjectionRelation(.wildcard_index, .{ .field = "items" }),
    );
    try std.testing.expectEqual(
        sema_model.MovePlaceProjectionRelation.may_overlap,
        sema_model.movePlaceProjectionRelation(.wildcard_index, .{ .symbolic_index = "i" }),
    );
    try std.testing.expectEqual(
        sema_model.MovePlaceProjectionRelation.may_overlap,
        sema_model.movePlaceProjectionRelation(.{ .symbolic_index = "i" }, .{ .constant_index = 0 }),
    );
    try std.testing.expect(!field.conflicts(wildcard));
    try std.testing.expect(!field.conflicts(symbolic));
}

test "allocation failure across parse monomorphize and sema never reports clean success" {
    {
        const source = "fn main() -> void {}\n";
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();

        var reporter = diagnostics.Reporter.init(std.testing.allocator, "parse_oom.mc", source);
        defer reporter.deinit();

        const parsed = parseWithAllocator(source, arena.allocator(), &reporter);
        if (parsed) |module| {
            module.deinit(arena.allocator());
            try std.testing.expect(reporter.has_errors);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }

    {
        const source =
            \\fn make(comptime N: usize) -> [N]u8 {
            \\    var scratch: [N]u8 = uninit;
            \\    scratch[0] = 0;
            \\    return scratch;
            \\}
            \\
            \\fn trigger() -> u8 {
            \\    let a: [1]u8 = make(1);
            \\    return a[0];
            \\}
        ;

        var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "mono_oom_pipeline.mc", source);
        defer parse_reporter.deinit();
        var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse_arena.deinit();

        const module = try parseWithAllocator(source, parse_arena.allocator(), &parse_reporter);
        try std.testing.expect(!parse_reporter.has_errors);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var mono_arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer mono_arena.deinit();

        var reporter = diagnostics.Reporter.init(std.testing.allocator, "mono_oom_pipeline.mc", source);
        defer reporter.deinit();

        const specialized = monomorphize.transformReport(mono_arena.allocator(), module, &reporter);
        if (specialized) |_| {
            try std.testing.expect(reporter.has_errors);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }

    {
        const source =
            \\fn id(x: u32) -> u32 {
            \\    return x;
            \\}
            \\
            \\fn main() -> u32 {
            \\    return id(1);
            \\}
        ;

        var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "sema_oom.mc", source);
        defer parse_reporter.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
        try std.testing.expect(!parse_reporter.has_errors);
        const specialized = try monomorphize.transformReport(arena.allocator(), module, &parse_reporter);
        try std.testing.expect(!parse_reporter.has_errors);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "sema_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(specialized);

        try std.testing.expect(reporter.has_errors);
        try std.testing.expect(checker.oom);
    }
}

test "allocation failure while checking type alias cycles fails closed" {
    const source =
        \\type A = B;
        \\type B = A;
        \\
        \\fn main() -> void {}
    ;

    var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "alias_cycle_oom.mc", source);
    defer parse_reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
    try std.testing.expect(!parse_reporter.has_errors);

    var saw_oom = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "alias_cycle_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);

        try std.testing.expect(reporter.has_errors or checker.oom);
        if (checker.oom) saw_oom = true;
    }
    try std.testing.expect(saw_oom);
}

test "allocation failure while tracking asm register conflicts fails closed" {
    const source =
        \\fn reject_asm_register_conflict(x: u64) -> u64 {
        \\    var out_val: u64 = 0;
        \\    #[unsafe_contract(precise_asm)] {
        \\        unsafe {
        \\            asm precise volatile {
        \\                "nop"
        \\                out("rax") out_val: u64,
        \\                in("rax") x: u64
        \\            }
        \\        }
        \\    }
        \\    return out_val;
        \\}
    ;

    var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "asm_conflict_oom.mc", source);
    defer parse_reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
    try std.testing.expect(!parse_reporter.has_errors);

    var saw_oom = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "asm_conflict_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);

        try std.testing.expect(reporter.has_errors or checker.oom);
        if (checker.oom) saw_oom = true;
    }
    try std.testing.expect(saw_oom);
}

test "allocation failure while tracking backend name collisions fails closed" {
    const source =
        \\#[backend_name("mc_fixture_collision")]
        \\fn first_backend_name() -> u32 {
        \\    return 1;
        \\}
        \\
        \\#[backend_name("mc_fixture_collision")]
        \\fn second_backend_name() -> u32 {
        \\    return 2;
        \\}
    ;

    var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "backend_name_oom.mc", source);
    defer parse_reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
    try std.testing.expect(!parse_reporter.has_errors);

    var saw_oom = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "backend_name_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);

        try std.testing.expect(reporter.has_errors or checker.oom);
        if (checker.oom) saw_oom = true;
    }
    try std.testing.expect(saw_oom);
}

test "rejects nested MMIO register field assignment" {
    const source =
        \\packed bits UartLsr: u8 {
        \\    data_ready: bool,
        \\    tx_empty: bool,
        \\}
        \\
        \\extern mmio struct Uart16550 {
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn set_lsr(uart: MmioPtr<Uart16550>, flag: bool) -> void {
        \\    uart.lsr.tx_empty = flag;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nested_mmio_register_field_assignment.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_MMIO_DIRECT_ASSIGN"));
}

test "type checks packed bits fields as bool" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\fn read_ready(status: Status) -> bool {
        \\    return status.ready;
        \\}
        \\
        \\fn write_ready(status: Status, flag: bool) -> Status {
        \\    var next: Status = status;
        \\    next.ready = flag;
        \\    return next;
        \\}
        \\
        \\fn reject_read_ready_as_u32(status: Status) -> u32 {
        \\    return status.ready;
        \\}
        \\
        \\fn reject_unknown(status: Status) -> bool {
        \\    return status.missing;
        \\}
        \\
        \\fn reject_write_u32(status: Status, value: u32) -> Status {
        \\    var next: Status = status;
        \\    next.ready = value;
        \\    return next;
        \\}
        \\
        \\fn reject_write_literal(status: Status) -> Status {
        \\    var next: Status = status;
        \\    next.ready = 1;
        \\    return next;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "packed_bits_field_typing.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_RETURN_TYPE_MISMATCH"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_UNKNOWN_STRUCT_FIELD"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_NO_IMPLICIT_CONVERSION"));
}

test "const_get requires in-bounds fixed array index" {
    const source =
        \\fn accept(xs: [2]u32) -> u32 {
        \\    return xs.const_get<1>();
        \\}
        \\
        \\fn reject_oob(xs: [2]u32) -> u32 {
        \\    return xs.const_get<2>();
        \\}
        \\
        \\fn reject_base(xs: []const u32) -> u32 {
        \\    return xs.const_get<0>();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "const_get.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_CONST_GET_BOUNDS"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_CONST_GET_BASE"));
    try std.testing.expect(!hasDiagnosticCode(&reporter, "E_UNKNOWN_FUNCTION"));
}

test "varargs calls require exact shape and mutable va_list cursor" {
    const source =
        \\fn accepted_local(last: i32, ...) -> i64 {
        \\    var local: va_list = va.start();
        \\    var value: i64 = 0;
        \\    unsafe { value = va.arg<i64>(&local); }
        \\    va.end(&local);
        \\    return value + (last as i64);
        \\}
        \\
        \\fn accepted_parameter(ap: *mut va_list) -> i64 {
        \\    var value: i64 = 0;
        \\    unsafe { value = va.arg<i64>(ap); }
        \\    va.end(ap);
        \\    return value;
        \\}
        \\
        \\fn rejected(value: u32, ap: *const va_list, ...) -> void {
        \\    var local: va_list = va.start<u32>();
        \\    var result: i64 = 0;
        \\    unsafe { result = va.arg<i64>(); }
        \\    unsafe { result = va.arg<i64>(&value); }
        \\    unsafe { result = va.arg<i64>(ap); }
        \\    va.end();
        \\}
        \\
        \\fn rejected_start_context() -> void {
        \\    var local: va_list = va.start();
        \\    va.end(&local);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "varargs_call_contract.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_CALL_ARG_COUNT"));
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_NO_IMPLICIT_CONVERSION"));
    // DIAGNOSTIC_UNIT: E_VA_START_CONTEXT
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_VA_START_CONTEXT"));
}

test "explicit trap rejects type arguments before MIR construction" {
    const source =
        \\fn rejected() -> never {
        \\    return trap<u32>(.Assert);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "trap_type_arguments.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_INVALID_TRAP_KIND"));
}

test "rejects by-value struct signatures at extern and export ABI boundaries" {
    const source =
        \\extern "C" struct Packet {
        \\    value: u32,
        \\}
        \\
        \\struct Plain {
        \\    value: u32,
        \\}
        \\
        \\type PacketAlias = Packet;
        \\type PlainAlias = Plain;
        \\
        \\extern "C" fn take_packet(packet: Packet) -> void;
        \\extern "C" fn make_packet() -> PacketAlias;
        \\extern fn take_packet_ptr(packet: *Packet) -> void;
        \\
        \\export fn exported_take(plain: Plain) -> u32 {
        \\    return plain.value;
        \\}
        \\
        \\export fn exported_make() -> PlainAlias {
        \\    return .{ .value = 1 };
        \\}
        \\
        \\fn internal_roundtrip(plain: Plain) -> Plain {
        \\    return plain;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "extern_export_struct_abi.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_EXTERN_STRUCT_BY_VALUE"));
}
