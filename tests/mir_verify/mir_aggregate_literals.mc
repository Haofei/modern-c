struct Packet {
    tag: u8,
    ptr: *mut u8,
    bytes: [2]u8,
}

struct PtrPacket {
    ptr: *mut u8,
}

packed bits Flags: u8 {
    ready: bool,
    busy: bool,
}

type Byte = u8;
type Bytes = [2]Byte;
type PacketAlias = Packet;
type BytePtr = *mut Byte;
type FlagsAlias = Flags;

extern fn make_ptr() -> *mut u8;
extern fn make_alias_ptr() -> BytePtr;
extern fn take_bytes(value: [2]u8) -> void;
extern fn take_alias_bytes(value: Bytes) -> void;
extern fn take_flags(value: FlagsAlias) -> void;

fn accept_aggregate_literals() -> Packet {
    let xs: [2]u8 = .{1, 2};
    return .{ .tag = 255, .ptr = make_ptr(), .bytes = xs };
}

fn accept_pointer_aggregate_field(cell: u8) -> PtrPacket {
    return .{ .ptr = &cell };
}

fn accept_pointer_aggregate_element(cell: u8) -> [2]*mut u8 {
    return .{ &cell, &cell };
}

fn accept_member_aggregate_field(packet: Packet) -> PtrPacket {
    return .{ .ptr = packet.ptr };
}

fn accept_index_aggregate_field(values: [2]*mut u8) -> PtrPacket {
    return .{ .ptr = values[0] };
}

fn reject_struct_fields() -> Packet {
    return .{ .tag = 300, .ptr = null, .bytes = .{1, 999} };
}

fn reject_local_array_element() -> void {
    let xs: [2]u8 = .{1, 300};
}

fn reject_assignment_array_element() -> void {
    var xs: [2]u8 = uninit;
    xs = .{1, 400};
}

fn reject_call_array_element() -> void {
    take_bytes(.{1, 500});
}

fn reject_short_array() -> [2]u8 {
    return .{1};
}

fn reject_long_array() -> [2]u8 {
    return .{1, 2, 3};
}

fn reject_missing_struct_field() -> Packet {
    return .{ .tag = 1, .ptr = make_ptr() };
}

fn reject_duplicate_struct_field() -> Packet {
    return .{ .tag = 1, .ptr = make_ptr(), .tag = 2, .bytes = .{1, 2} };
}

fn reject_unknown_struct_field() -> Packet {
    return .{ .tag = 1, .ptr = make_ptr(), .extra = 2, .bytes = .{1, 2} };
}

fn accept_alias_aggregate_literals() -> PacketAlias {
    let xs: Bytes = .{1, 2};
    return .{ .tag = 3, .ptr = make_alias_ptr(), .bytes = xs };
}

fn reject_alias_array_element() -> Bytes {
    return .{1, 600};
}

fn reject_alias_struct_fields() -> PacketAlias {
    return .{ .tag = 700, .ptr = null, .bytes = .{1, 2} };
}

fn reject_alias_call_array_element() -> void {
    take_alias_bytes(.{1, 800});
}

fn reject_cast_array_element() -> Bytes {
    return (.{1, 900} as Bytes);
}

fn reject_cast_short_array() -> Bytes {
    return (.{1} as Bytes);
}

fn reject_cast_struct_fields() -> PacketAlias {
    return (.{ .tag = 901, .ptr = null, .bytes = .{1, 2} } as PacketAlias);
}

fn reject_cast_missing_struct_field() -> PacketAlias {
    return (.{ .tag = 1, .ptr = make_ptr() } as PacketAlias);
}

fn accept_packed_bits_literals() -> FlagsAlias {
    let flags: FlagsAlias = .{ .ready = true, .busy = false };
    take_flags(.{ .ready = flags.ready, .busy = true });
    return flags;
}

fn reject_packed_bits_field_type() -> FlagsAlias {
    return .{ .ready = 1, .busy = false };
}

fn reject_packed_bits_missing_field() -> FlagsAlias {
    return .{ .ready = true };
}

fn reject_packed_bits_duplicate_field() -> FlagsAlias {
    return .{ .ready = true, .ready = false, .busy = false };
}

fn reject_packed_bits_unknown_field() -> FlagsAlias {
    return .{ .ready = true, .missing = false, .busy = false };
}
