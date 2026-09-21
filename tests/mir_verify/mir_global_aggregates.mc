struct GlobalPacket {
    tag: u8,
    ptr: *mut u8,
    bytes: [2]u8,
}

packed bits GlobalFlags: u8 {
    ready: bool,
    busy: bool,
}

type GlobalBytes = [2]u8;
type GlobalPacketAlias = GlobalPacket;
type GlobalFlagsAlias = GlobalFlags;

global ok_bytes: GlobalBytes = .{1, 2};
global ok_raw_flags: GlobalFlagsAlias = 0xff;
global reject_global_array_element: GlobalBytes = .{1, 300};
global reject_global_array_shape: GlobalBytes = .{1};
global reject_global_struct_fields: GlobalPacketAlias = .{ .tag = 400, .ptr = null, .bytes = .{1, 999} };
global reject_global_struct_missing: GlobalPacketAlias = .{ .tag = 1, .ptr = null };
global reject_global_flags_type: GlobalFlagsAlias = .{ .ready = 1, .busy = false };
global reject_global_flags_missing: GlobalFlagsAlias = .{ .ready = true };
global reject_raw_flags_range: GlobalFlagsAlias = 0x100;
