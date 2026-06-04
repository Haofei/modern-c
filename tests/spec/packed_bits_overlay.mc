// SPEC: section=6.3,14,22,I.11,I.12
// SPEC: milestone=packed-bits-overlay-declarations
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_PACKED_BITS_REPR_NOT_INTEGER,E_PACKED_BITS_FIELD_NOT_BOOL,E_DUPLICATE_PACKED_BITS_FIELD,E_DUPLICATE_OVERLAY_FIELD,E_UNKNOWN_STRUCT_FIELD

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

fn accept_overlay_reflection() -> usize {
    return field_offset<Word>(.bytes);
}

fn accept_spec_overlay_reflection() -> usize {
    return field_offset(Word, .u);
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

fn reject_unknown_overlay_field() -> usize {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return field_offset(Word, .missing);
}
