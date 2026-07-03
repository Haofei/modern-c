// EXPECT: E_EXTERN_STRUCT_BY_VALUE
// Imported extern functions cross the external ABI boundary. Struct parameters must
// stay behind pointers until MC implements target C ABI classification for by-value aggregates.

extern "C" struct Packet {
    value: u32,
}

extern "C" fn bad(packet: Packet) -> void;
