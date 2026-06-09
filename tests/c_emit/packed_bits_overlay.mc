packed bits UartLsr: u8 {
    data_ready: bool,
    tx_empty: bool,
}

overlay union Word {
    u: u32,
    bytes: [4]u8,
}

fn accept_packed_bits_reflection() -> usize {
    return bit_offset<UartLsr>(.tx_empty);
}

fn accept_spec_packed_bits_reflection() -> usize {
    return bit_offset(UartLsr, .data_ready);
}

global default_status: UartLsr = .{ .data_ready = true, .tx_empty = false };

fn accept_packed_bits_literal_return() -> UartLsr {
    return .{ .data_ready = true, .tx_empty = false };
}

fn accept_packed_bits_literal_local(flag: bool) -> bool {
    let status: UartLsr = .{ .data_ready = flag, .tx_empty = false };
    return status.data_ready;
}

fn accept_packed_bits_literal_assignment(flag: bool) -> UartLsr {
    var status: UartLsr = .{ .data_ready = false, .tx_empty = false };
    status = .{ .data_ready = false, .tx_empty = flag };
    return status;
}

extern fn consume_status(status: UartLsr) -> void;

fn accept_packed_bits_literal_call() -> void {
    consume_status(.{ .data_ready = true, .tx_empty = true });
}

fn accept_overlay_reflection() -> usize {
    return field_offset<Word>(.bytes);
}

fn accept_spec_overlay_reflection() -> usize {
    return field_offset(Word, .u);
}
