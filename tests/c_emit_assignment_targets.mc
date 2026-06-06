extern struct Packet {
    value: u32,
    ptr: *mut u8,
}

fn identifier_assignment() -> u32 {
    var x: u32 = 1;
    x = 2;
    return x;
}

fn grouped_identifier_assignment() -> u32 {
    var x: u32 = 1;
    (x) = 2;
    return x;
}

fn storage_assignment_targets(p: *mut u32, xs: []mut u32, i: usize, packet: Packet, value: u32) -> u32 {
    p.* = value;
    xs[i] = value;
    var local: Packet = packet;
    local.value = value;
    return local.value;
}

fn member_read(packet: Packet) -> u32 {
    return packet.value;
}

fn member_pointer_read(packet: Packet) -> *mut u8 {
    return packet.ptr;
}
