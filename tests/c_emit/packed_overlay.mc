packed bits UartLsr: u8 {
    data_ready: bool,
    tx_empty: bool,
}

global line_status: UartLsr = 0;
global default_status: UartLsr = .{ .data_ready = true, .tx_empty = false };

overlay union Word {
    u: u32,
    bytes: [4]u8,
}

fn has_data(status: UartLsr) -> bool {
    return status.data_ready;
}

fn set_tx_empty(status: UartLsr, flag: bool) -> UartLsr {
    var next: UartLsr = status;
    next.tx_empty = flag;
    return next;
}

fn update_global_tx_empty(flag: bool) -> void {
    line_status.tx_empty = flag;
}

fn read_global_data_ready() -> bool {
    return line_status.data_ready;
}

fn make_status(flag: bool) -> UartLsr {
    return .{ .data_ready = flag, .tx_empty = true };
}

fn assign_status_literal(flag: bool) -> UartLsr {
    var status: UartLsr = .{ .data_ready = false, .tx_empty = false };
    status = .{ .data_ready = flag, .tx_empty = false };
    return status;
}

extern fn consume_status(status: UartLsr) -> void;

fn call_status_literal(flag: bool) -> void {
    consume_status(.{ .data_ready = flag, .tx_empty = true });
}

fn set_word(value: u32) -> Word {
    var word: Word = uninit;
    word.u = value;
    return word;
}

fn first_byte(word: Word) -> u8 {
    return word.bytes[0];
}
