// Wire the RX processing path onto the arena: each packet's scratch buffer is an
// arena GenRef, the frame is built + demuxed on that scratch, then the arena is reset
// (reclaim) per packet. A handle held across a reset is caught stale (use-after-reset).

import "kernel/net/net_rx.mc"; // net_rx_deliver, sockets, udp_write, ByteWriter, RX_ETYPE_IPV4
import "std/alloc/arena.mc";

global g_socks: SocketTable;
global g_scratch: [512]u8;

const OUR_IP: u32 = 0x0A00_020F;
const GW_IP: u32 = 0x0A00_0202;

// Build an eth+ipv4+udp frame carrying "RX!" at physical address `addr`; return length.
fn build_frame_at(addr: usize, src_ip: u32, dst_ip: u32, sport: u16, dport: u16) -> usize {
    var w: ByteWriter = byte_writer(pa(addr), 64);
    var i: usize = 0;
    while i < 12 {
        bw_u8(&w, i, 0xFF);
        i = i + 1;
    }
    bw_be16(&w, 12, RX_ETYPE_IPV4);
    bw_u8(&w, ETH_HDR + 0, 0x45);
    bw_u8(&w, ETH_HDR + 9, 17);
    bw_be32(&w, ETH_HDR + 12, src_ip);
    bw_be32(&w, ETH_HDR + 16, dst_ip);
    bw_u8(&w, ETH_HDR + 20 + 8 + 0, 0x52); // R
    bw_u8(&w, ETH_HDR + 20 + 8 + 1, 0x58); // X
    bw_u8(&w, ETH_HDR + 20 + 8 + 2, 0x21); // !
    udp_write(&w, ETH_HDR + 20, src_ip, dst_ip, sport, dport, 3);
    return ETH_HDR + 20 + 8 + 3;
}

// Returns delivered_count | (stale_caught << 8). Expect 2 delivered + stale caught -> 0x102.
export fn net_arena_run() -> u32 {
    socket_table_init(&g_socks);
    switch socket_bind(&g_socks, 0, 1234) {
        ok(b) => {}
        err(e) => {}
    }
    var a: Arena = arena_init(phys_range(pa((&g_scratch[0]) as usize), 512));

    // Prove a handle held across a reset goes stale.
    var stale_caught: u32 = 0;
    let prev: GenRef<u8> = arena_alloc_gen(u8, &a, 1, 1);
    arena_reset(&a);
    switch arena_resolve(u8, &a, prev) {
        ok(addr) => {}
        err(e) => {
            stale_caught = 1;
        }
    }

    var delivered: u32 = 0;
    var i: usize = 0;
    while i < 2 {
        let h: GenRef<u8> = arena_alloc_gen(u8, &a, 64, 4);
        switch arena_resolve(u8, &a, h) {
            ok(addr) => {
                let len: usize = build_frame_at(pa_value(addr), GW_IP, OUR_IP, 5000, 1234);
                switch net_rx_deliver(&g_socks, pa_value(addr), len) {
                    ok(b) => {
                        delivered = delivered + 1;
                    }
                    err(e) => {}
                }
            }
            err(e) => {}
        }
        arena_reset(&a); // per-packet scratch reclaim
        i = i + 1;
    }
    arena_destroy(a);
    return delivered | (stale_caught << 8);
}
