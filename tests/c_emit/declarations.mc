type Count = u32;

extern struct Packet {
    len: u16,
    tag: u8,
}

packed bits Flags: u8 {
    ready: bool,
    busy: bool,
}

enum Mode: u8 {
    idle = 0,
    active = 1,
}

global total: u32 = 0;

fn packet_len(packet: Packet) -> u32 {
    var value: u32 = packet.len as u32;
    return value;
}

fn flags_ready(flags: Flags) -> bool {
    return flags.ready;
}

fn keep_mode(mode: Mode) -> Mode {
    return mode;
}
