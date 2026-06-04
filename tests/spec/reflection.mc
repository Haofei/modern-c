// SPEC: section=22
// SPEC: milestone=comptime-reflection
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_UNKNOWN_STRUCT_FIELD,E_REFLECTION_FIELD_LITERAL,E_CALL_ARG_COUNT,E_REFLECTION_UNKNOWN_TYPE,E_C_VOID_NO_LAYOUT

extern struct Packet {
    len: u16,
    tag: u8,
}

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    lsr: Reg<u8, .read>,
}

fn accept_sizeof_struct() -> usize {
    return sizeof<Packet>();
}

fn accept_alignof_primitive() -> usize {
    return alignof<u32>();
}

fn accept_field_offset() -> usize {
    return field_offset<Packet>(.len);
}

fn accept_mmio_field_offset() -> usize {
    return field_offset<Uart16550>(.lsr);
}

fn accept_bit_offset() -> usize {
    return bit_offset<Packet>(.tag);
}

fn reject_unknown_reflection_field() -> usize {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return field_offset<Packet>(.missing);
}

fn reject_field_type_unknown_field() -> usize {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return field_type<Packet>(.missing);
}

fn reject_bit_offset_unknown_field() -> usize {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return bit_offset<Packet>(.missing);
}

fn reject_reflection_field_not_literal(name: usize) -> usize {
    // EXPECT_ERROR: E_REFLECTION_FIELD_LITERAL
    return field_offset<Packet>(name);
}

fn reject_sizeof_runtime_arg() -> usize {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return sizeof<Packet>(1);
}

fn reject_unknown_reflection_type() -> usize {
    // EXPECT_ERROR: E_REFLECTION_UNKNOWN_TYPE
    return sizeof<MissingType>();
}

fn reject_c_void_sizeof() -> usize {
    // EXPECT_ERROR: E_C_VOID_NO_LAYOUT
    return sizeof<c_void>();
}
