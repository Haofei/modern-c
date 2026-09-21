extern struct Packet {
    value: u32,
}

extern fn local_array() -> [4]u32;

fn accept_assign_to_var() -> u32 {
    var x: u32 = 1;
    x = 2;
    return x;
}

fn reject_assign_to_let() -> u32 {
    let x: u32 = 1;
    x = 2;
    return x;
}

fn reject_assign_to_param(x: u32) -> u32 {
    x = 2;
    return x;
}

fn reject_assign_to_param_field(packet: Packet) -> u32 {
    packet.value = 2;
    return packet.value;
}

fn reject_assign_to_let_array_element(i: usize, value: u32) -> u32 {
    let xs = local_array();
    xs[i] = value;
    return xs[i];
}

fn reject_assign_through_const_pointer(p: *const u32, value: u32) -> void {
    p.* = value;
}

fn reject_assign_through_const_slice(xs: []const u32, i: usize, value: u32) -> void {
    xs[i] = value;
}

fn reject_assign_field_through_const_pointer(packet: *const Packet, value: u32) -> void {
    packet.*.value = value;
}

fn reject_assign_through_cast_const_pointer(p: *mut u32, value: u32) -> void {
    (p as *const u32).* = value;
}

fn reject_assign_through_cast_const_raw_many(p: [*]mut u32, value: u32) -> void {
    (p as [*]const u32).* = value;
}

fn reject_assign_through_cast_const_slice(xs: []mut u32, i: usize, value: u32) -> void {
    (xs as []const u32)[i] = value;
}

fn reject_assign_field_through_cast_const_pointer(packet: *mut Packet, value: u32) -> void {
    (packet as *const Packet).*.value = value;
}
