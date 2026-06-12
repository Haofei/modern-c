// SPEC: section=22
// SPEC: milestone=comptime-reflection
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_UNKNOWN_STRUCT_FIELD,E_REFLECTION_FIELD_LITERAL,E_REFLECTION_TYPE_ARG,E_REFLECTION_GENERIC_ARG_COUNT,E_CALL_ARG_COUNT,E_REFLECTION_UNKNOWN_TYPE,E_REFLECTION_TYPE_VALUE,E_C_VOID_NO_LAYOUT,E_DMA_BUF_MODE

extern struct Packet {
    len: u16,
    tag: u8,
}

enum Mode: u8 {
    normal = 0,
    fast = 1,
}

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    lsr: Reg<u8, .read>,
}

fn accept_sizeof_struct() -> usize {
    return sizeof<Packet>();
}

fn accept_spec_sizeof_struct() -> usize {
    return sizeof(Packet);
}

fn accept_alignof_primitive() -> usize {
    return alignof<u32>();
}

fn accept_spec_alignof_primitive() -> usize {
    return alignof(u32);
}

fn accept_spec_sizeof_generic() -> usize {
    return sizeof(MmioPtr<Uart16550>);
}

fn accept_spec_sizeof_dma_buf() -> usize {
    return sizeof(DmaBuf<Packet, .noncoherent>);
}

fn accept_spec_sizeof_coherent_dma_buf() -> usize {
    return sizeof(DmaBuf<Packet, .coherent>);
}

fn accept_spec_sizeof_pointer() -> usize {
    return sizeof(*const u8);
}

fn accept_spec_sizeof_vaddr() -> usize {
    return sizeof(VAddr);
}

fn accept_spec_sizeof_slice() -> usize {
    return sizeof([]u8);
}

fn accept_spec_repr_of_enum() -> usize {
    return repr_of(Mode);
}

fn accept_field_offset() -> usize {
    return field_offset<Packet>(.len);
}

fn accept_spec_field_offset() -> usize {
    return field_offset(Packet, .len);
}

fn accept_mmio_field_offset() -> usize {
    return field_offset<Uart16550>(.lsr);
}

fn accept_spec_mmio_field_offset() -> usize {
    return field_offset(Uart16550, .lsr);
}

fn accept_bit_offset() -> usize {
    return bit_offset<Packet>(.tag);
}

fn accept_reflected_field_type_arg(comptime T: type, value: T) -> void {
}

fn accept_field_type_type_arg(packet: Packet) -> void {
    accept_reflected_field_type_arg(field_type(Packet, .len), packet.len);
}

fn reject_field_type_value() -> usize {
    // EXPECT_ERROR: E_REFLECTION_TYPE_VALUE
    return field_type(Packet, .len);
}

fn accept_comptime_reflection_offsets() -> void {
    comptime {
        assert(sizeof(Packet) == 4);
        assert(alignof(Packet) == 2);
        assert(repr_of(Mode) == 1);
        assert(field_offset(Packet, .len) == 0);
        assert(field_offset(Packet, .tag) == 2);
        assert(field_offset(Uart16550, .lsr) == 1);
        assert(bit_offset(Packet, .tag) == 16);
    }
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

fn reject_spec_reflection_field_not_literal(name: usize) -> usize {
    // EXPECT_ERROR: E_REFLECTION_FIELD_LITERAL
    return field_offset(Packet, name);
}

fn reject_sizeof_runtime_arg() -> usize {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return sizeof<Packet>(1);
}

fn reject_spec_sizeof_extra_arg() -> usize {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return sizeof(Packet, 1);
}

fn reject_reflection_type_not_type_name() -> usize {
    // EXPECT_ERROR: E_REFLECTION_TYPE_ARG
    return sizeof(1);
}

fn reject_unknown_reflection_type() -> usize {
    // EXPECT_ERROR: E_REFLECTION_UNKNOWN_TYPE
    return sizeof<MissingType>();
}

fn reject_spec_unknown_reflection_type() -> usize {
    // EXPECT_ERROR: E_REFLECTION_UNKNOWN_TYPE
    return sizeof(MissingType);
}

fn reject_spec_unknown_generic_reflection_type() -> usize {
    // EXPECT_ERROR: E_REFLECTION_UNKNOWN_TYPE
    return sizeof(MissingGeneric<u8>);
}

fn reject_dma_buf_missing_mode() -> usize {
    // EXPECT_ERROR: E_REFLECTION_GENERIC_ARG_COUNT
    return sizeof(DmaBuf<Packet>);
}

fn reject_dma_buf_extra_typestate_for_section22() -> usize {
    // EXPECT_ERROR: E_REFLECTION_GENERIC_ARG_COUNT
    return sizeof(DmaBuf<Packet, .noncoherent, .cpu_owned>);
}

fn reject_dma_buf_non_literal_mode() -> usize {
    // EXPECT_ERROR: E_DMA_BUF_MODE
    return sizeof(DmaBuf<Packet, bool>);
}

fn reject_dma_buf_unknown_mode() -> usize {
    // EXPECT_ERROR: E_DMA_BUF_MODE
    return sizeof(DmaBuf<Packet, .bogus>);
}

fn reject_user_ptr_extra_arg() -> usize {
    // EXPECT_ERROR: E_REFLECTION_GENERIC_ARG_COUNT
    return sizeof(UserPtr<Packet, .extra>);
}

fn reject_mmio_ptr_missing_arg() -> usize {
    // EXPECT_ERROR: E_REFLECTION_GENERIC_ARG_COUNT
    return sizeof(MmioPtr<>);
}

fn reject_c_void_sizeof() -> usize {
    // EXPECT_ERROR: E_C_VOID_NO_LAYOUT
    return sizeof<c_void>();
}

fn reject_spec_c_void_sizeof() -> usize {
    // EXPECT_ERROR: E_C_VOID_NO_LAYOUT
    return sizeof(c_void);
}
