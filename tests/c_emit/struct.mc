extern struct Packet {
    value: u32,
}

struct Pair {
    left: u32,
    right: u32,
}

fn packet_value(packet: Packet) -> u32 {
    return packet.value;
}

fn pair_left(pair: Pair) -> u32 {
    return pair.left;
}
