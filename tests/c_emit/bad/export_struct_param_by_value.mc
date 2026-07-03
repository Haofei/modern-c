// EXPECT: E_EXTERN_STRUCT_BY_VALUE
// Exported functions cross the external ABI boundary. Struct parameters must stay
// behind pointers until MC implements target C ABI classification for by-value aggregates.

extern "C" struct Packet {
    value: u32,
}

export fn bad(packet: Packet) -> u32 {
    return packet.value;
}
