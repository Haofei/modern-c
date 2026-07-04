// SPEC: section=6.3,14,22,I.11,I.12
// SPEC: milestone=packed-bits-overlay-declarations
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_PACKED_BITS_REPR_NOT_INTEGER,E_PACKED_BITS_FIELD_NOT_BOOL,E_DUPLICATE_PACKED_BITS_FIELD,E_DUPLICATE_OVERLAY_FIELD,E_UNKNOWN_STRUCT_FIELD,E_DUPLICATE_STRUCT_LITERAL_FIELD,E_STRUCT_LITERAL_MISSING_FIELD,E_RETURN_TYPE_MISMATCH,packed-bits-no-c-bitfields,overlay-union-byte-storage

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

fn accept_overlay_align_reflection() -> usize {
    return alignof(Word);
}

fn accept_comptime_packed_bits_overlay_reflection() -> void {
    comptime {
        assert(bit_offset(UartLsr, .data_ready) == 0);
        assert(bit_offset(UartLsr, .tx_empty) == 1);
        assert(repr_of(UartLsr) == 1);
        assert(sizeof(UartLsr) == 1);
        assert(alignof(UartLsr) == 1);
        assert(field_offset(Word, .u) == 0);
        assert(field_offset(Word, .bytes) == 0);
        assert(alignof(Word) == 4);
    }
}

// EXPECT_ERROR: E_PACKED_BITS_REPR_NOT_INTEGER
packed bits RejectPackedBitsRepr: bool {
    flag: bool,
}

packed bits RejectPackedBitsField: u8 {
    // EXPECT_ERROR: E_PACKED_BITS_FIELD_NOT_BOOL
    flag: u8,
}

packed bits RejectDuplicatePackedBit: u8 {
    flag: bool,
    // EXPECT_ERROR: E_DUPLICATE_PACKED_BITS_FIELD
    flag: bool,
}

overlay union RejectDuplicateOverlay {
    u: u32,
    // EXPECT_ERROR: E_DUPLICATE_OVERLAY_FIELD
    u: [4]u8,
}

fn reject_unknown_packed_bit() -> usize {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return bit_offset<UartLsr>(.missing);
}

fn reject_unknown_packed_bits_literal_field() -> UartLsr {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return .{ .data_ready = true, .missing = false };
}

fn reject_duplicate_packed_bits_literal_field() -> UartLsr {
    // EXPECT_ERROR: E_DUPLICATE_STRUCT_LITERAL_FIELD
    return .{ .data_ready = true, .data_ready = false, .tx_empty = false };
}

fn reject_missing_packed_bits_literal_field() -> UartLsr {
    // EXPECT_ERROR: E_STRUCT_LITERAL_MISSING_FIELD
    return .{ .data_ready = true };
}

fn reject_packed_bits_literal_field_type() -> UartLsr {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return .{ .data_ready = 1, .tx_empty = false };
}

fn reject_unknown_overlay_field() -> usize {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return field_offset(Word, .missing);
}
