const std = @import("std");

const diagnostics = @import("diagnostics.zig");
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
