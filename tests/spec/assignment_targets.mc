// SPEC: section=25
// SPEC: milestone=assignment-targets
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_INVALID_ASSIGNMENT_TARGET,E_NO_IMPLICIT_CONVERSION,E_NO_IMPLICIT_POINTER_CONVERSION,E_RETURN_TYPE_MISMATCH,E_UNKNOWN_STRUCT_FIELD

fn source_value() -> u32;
fn make_packet() -> Packet;
fn make_mut_u8_slice() -> []mut u8;
fn make_mut_u32_pointer() -> *mut u32;

fn accept_identifier_assignment() -> u32 {
    var x: u32 = 1;
    x = 2;
    return x;
}

fn accept_grouped_identifier_assignment() -> u32 {
    var x: u32 = 1;
    (x) = 2;
    return x;
}

extern struct Packet {
    value: u32,
    ptr: *mut u8,
}

struct PlainPacket {
    value: u32,
}

fn accept_storage_assignment_targets(p: *mut u32, xs: []mut u32, i: usize, packet: Packet, value: u32) -> void {
    p.* = value;
    xs[i] = value;
    var local: Packet = packet;
    local.value = value;
}

fn accept_plain_struct_member_read(packet: PlainPacket) -> u32 {
    return packet.value;
}

fn accept_member_read(packet: Packet) -> u32 {
    return packet.value;
}

fn accept_direct_call_member_read() -> u32 {
    return make_packet().value;
}

fn accept_direct_call_member_pointer_read() -> *mut u8 {
    return make_packet().ptr;
}

fn reject_member_read_return_type(packet: Packet) -> *mut u8 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return packet.value;
}

fn reject_direct_call_member_read_return_type() -> *mut u8 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return make_packet().value;
}

// The `*mut u8` member const-narrows to the `*const u8` return type (language gap G30).
fn accept_direct_call_member_pointer_return_conversion() -> *const u8 {
    return make_packet().ptr;
}

fn reject_missing_member_read(packet: Packet) -> u32 {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return packet.missing;
}

fn reject_direct_call_missing_member_read() -> u32 {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    return make_packet().missing;
}

fn reject_missing_member_call(packet: Packet) -> void {
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    packet.missing();
}

fn reject_member_assignment_bool(packet: Packet, flag: bool) -> void {
    var local: Packet = packet;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    local.value = flag;
}

fn reject_missing_member_assignment(packet: Packet, value: u32) -> void {
    var local: Packet = packet;
    // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
    local.missing = value;
}

fn reject_member_assignment_wide_integer(packet: Packet, value: u64) -> void {
    var local: Packet = packet;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    local.value = value;
}

fn reject_member_assignment_pointer_conversion(packet: Packet, p: *const u8) -> void {
    var local: Packet = packet;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    local.ptr = p;
}

fn reject_literal_assignment(value: u32) -> u32 {
    // EXPECT_ERROR: E_INVALID_ASSIGNMENT_TARGET
    1 = value;
    return value;
}

fn reject_call_assignment(value: u32) -> u32 {
    // EXPECT_ERROR: E_INVALID_ASSIGNMENT_TARGET
    source_value() = value;
    return value;
}

fn reject_direct_call_member_assignment(value: u32) -> u32 {
    // EXPECT_ERROR: E_INVALID_ASSIGNMENT_TARGET
    make_packet().value = value;
    return value;
}

fn reject_direct_call_index_assignment(value: u8) -> u8 {
    // EXPECT_ERROR: E_INVALID_ASSIGNMENT_TARGET
    make_mut_u8_slice()[0] = value;
    return value;
}

fn reject_direct_call_deref_assignment(value: u32) -> u32 {
    // EXPECT_ERROR: E_INVALID_ASSIGNMENT_TARGET
    make_mut_u32_pointer().* = value;
    return value;
}

fn reject_arithmetic_assignment(value: u32) -> u32 {
    // EXPECT_ERROR: E_INVALID_ASSIGNMENT_TARGET
    (value + 1) = value;
    return value;
}

fn reject_address_assignment(value: u32) -> u32 {
    var x: u32 = 1;
    // EXPECT_ERROR: E_INVALID_ASSIGNMENT_TARGET
    &x = null;
    return value;
}
