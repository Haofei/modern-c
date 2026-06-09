extern fn consume_pointer(p: *mut u8) -> void;

fn pass_array_element_address() -> void {
    var buf: [4]u8 = uninit;
    consume_pointer(&buf[0]);
}
