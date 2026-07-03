const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const monomorphize = @import("monomorphize.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");

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

test "rejects by-value struct signatures at extern and export ABI boundaries" {
    const source =
        \\extern "C" struct Packet {
        \\    value: u32,
        \\}
        \\
        \\type PacketAlias = Packet;
        \\
        \\extern "C" fn take_packet(packet: Packet) -> void;
        \\extern "C" fn make_packet() -> PacketAlias;
        \\extern fn take_packet_ptr(packet: *Packet) -> void;
        \\
        \\export fn exported_take(packet: Packet) -> u32 {
        \\    return packet.value;
        \\}
        \\
        \\export fn exported_make() -> Packet {
        \\    return .{ .value = 1 };
        \\}
        \\
        \\fn internal_roundtrip(packet: Packet) -> Packet {
        \\    return packet;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "extern_export_struct_abi.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_EXTERN_STRUCT_BY_VALUE"));
}
