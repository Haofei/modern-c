extern struct LocalPacket {
    value: u32,
}

fn assign_to_var() -> u32 {
    var x: u32 = 1;
    x = 2;
    return x;
}

fn assign_to_var_field(packet: LocalPacket) -> u32 {
    var local: LocalPacket = packet;
    local.value = 2;
    return local.value;
}

fn mutate_twice(value: u32) -> u32 {
    var x: u32 = value;
    x = x + 1;
    x = x + 2;
    return x;
}
