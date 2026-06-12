extern struct Packet {
    len: u16,
    tag: u8,
}

enum Mode: u8 {
    normal = 0,
    fast = 1,
}

union ReflectToken {
    number: u32,
    eof,
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

fn accept_spec_repr_of_tagged_union() -> usize {
    return repr_of(ReflectToken);
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

fn reflect_identity(comptime T: type, value: T) -> T {
    return value;
}

fn accept_field_type_type_arg(packet: Packet) -> u16 {
    return reflect_identity(field_type(Packet, .len), packet.len);
}

fn accept_tagged_union_payload_field_type(token: ReflectToken) -> u32 {
    switch token {
        number(n) => { return reflect_identity(field_type(ReflectToken, .number), n); },
        .eof => { return 0; },
    }
}
