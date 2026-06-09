// A fuzzer for the receive path: feed pseudo-random (and random-but-UDP-shaped)
// frames to net_rx_deliver and confirm it always returns a typed result — never an
// out-of-bounds read (which would trap the bounds-checked reader and abort). This
// exercises the parser's length handling: any frame length, any UDP length field.

import "kernel/net/net_rx.mc"; // brings udp, udp_socket, std/bytes, std/addr
import "std/math.mc";          // wrapping_shl_u32

global g_socks: SocketTable;
global g_buf: [256]u8;

// xorshift32 PRNG (deterministic, seedable). The left shifts use the wrapping helper
// because MC's `<<` is checked — xorshift relies on bits wrapping away, not trapping.
fn rng(state: u32) -> u32 {
    var x: u32 = state;
    x = x ^ wrapping_shl_u32(x, 13);
    x = x ^ (x >> 17);
    x = x ^ wrapping_shl_u32(x, 5);
    return x;
}

export fn fuzz_init() -> void {
    socket_table_init(&g_socks);
    switch socket_bind(&g_socks, 0, 53) {
        ok(b) => {}
        err(e) => {}
    }
}

// Pure-random frame of `len` bytes. Returns 0 if net_rx_deliver returned ok, 1 if it
// returned a typed error. Either way it must *return* (no OOB / trap).
export fn fuzz_random(seed: u32, len: usize) -> u32 {
    var w: ByteWriter = byte_writer(pa((&g_buf[0]) as usize), 256);
    var state: u32 = seed | 1;
    var i: usize = 0;
    while i < len {
        state = rng(state);
        bw_u8(&w, i, (state & 0x0000_00FF) as u8);
        i = i + 1;
    }
    switch net_rx_deliver(&g_socks, (&g_buf[0]) as usize, len) {
        ok(b) => {
            return 0;
        }
        err(e) => {
            return 1;
        }
    }
}

// Deterministic reproducer: a zeroed IPv4/UDP frame of `frame_len` with the given
// UDP length field, to pinpoint which length triggers a parser fault.
export fn fuzz_exact(frame_len: usize, udp_len: u16) -> u32 {
    socket_table_init(&g_socks);
    switch socket_bind(&g_socks, 0, 53) {
        ok(b) => {}
        err(e) => {}
    }
    var w: ByteWriter = byte_writer(pa((&g_buf[0]) as usize), 256);
    var i: usize = 0;
    while i < 256 {
        bw_u8(&w, i, 0);
        i = i + 1;
    }
    bw_be16(&w, 12, 0x0800);
    bw_u8(&w, 23, 17);
    bw_be16(&w, 36, 53);
    bw_be16(&w, 38, udp_len);
    switch net_rx_deliver(&g_socks, (&g_buf[0]) as usize, frame_len) {
        ok(b) => {
            return 0;
        }
        err(e) => {
            return 1;
        }
    }
}

// Random frame shaped like IPv4/UDP to port 53, but with a RANDOM UDP length field —
// fuzzes the length arithmetic (the BadLength guard + payload bounds). Re-inits the
// socket table so the deliver path stays reachable (not stuck QueueFull).
export fn fuzz_udp(seed: u32, len: usize) -> u32 {
    socket_table_init(&g_socks);
    switch socket_bind(&g_socks, 0, 53) {
        ok(b) => {}
        err(e) => {}
    }
    var w: ByteWriter = byte_writer(pa((&g_buf[0]) as usize), 256);
    var state: u32 = seed | 1;
    var i: usize = 0;
    while i < len {
        state = rng(state);
        bw_u8(&w, i, (state & 0x0000_00FF) as u8);
        i = i + 1;
    }
    if len >= 42 {
        bw_be16(&w, 12, 0x0800); // ethertype IPv4
        bw_u8(&w, 23, 17);       // IP protocol UDP (offset 14+9)
        bw_be16(&w, 36, 53);     // UDP dst port (offset 34+2)
        state = rng(state);
        bw_be16(&w, 38, (state & 0x0000_FFFF) as u16); // RANDOM UDP length field
    }
    switch net_rx_deliver(&g_socks, (&g_buf[0]) as usize, len) {
        ok(b) => {
            return 0;
        }
        err(e) => {
            return 1;
        }
    }
}
