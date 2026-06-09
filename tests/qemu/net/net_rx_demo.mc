// Test wrappers for the RX demultiplex path: build a real Ethernet+IPv4+UDP frame,
// feed it to net_rx_deliver (as the NIC driver would on RX), and recv the payload
// from the bound socket — the receive path end to end, no loopback shortcut.

import "kernel/net/net_rx.mc"; // transitively brings udp, udp_socket, std/bytes, std/addr
// ETH_HDR / RX_ETYPE_IPV4 come from net_rx.mc (top-level consts are import-visible).

global g_socks: SocketTable;
global g_frame: [128]u8;

// Build an eth+ip+udp frame carrying the 3-byte payload "RX!"; return its length.
export fn build_frame(src_ip: u32, dst_ip: u32, sport: u16, dport: u16) -> usize {
    var w: ByteWriter = byte_writer(pa((&g_frame[0]) as usize), 128);
    // Ethernet: dst + src MAC (filler) + ethertype.
    var i: usize = 0;
    while i < 12 {
        bw_u8(&w, i, 0xFF);
        i = i + 1;
    }
    bw_be16(&w, 12, RX_ETYPE_IPV4);
    // IPv4 header (20 bytes): version/IHL, protocol UDP, src/dst.
    bw_u8(&w, ETH_HDR + 0, 0x45);
    bw_u8(&w, ETH_HDR + 9, 17);
    bw_be32(&w, ETH_HDR + 12, src_ip);
    bw_be32(&w, ETH_HDR + 16, dst_ip);
    // Payload "RX!" then the UDP header + checksum over it.
    let payload_len: usize = 3;
    bw_u8(&w, ETH_HDR + 20 + 8 + 0, 0x52); // R
    bw_u8(&w, ETH_HDR + 20 + 8 + 1, 0x58); // X
    bw_u8(&w, ETH_HDR + 20 + 8 + 2, 0x21); // !
    udp_write(&w, ETH_HDR + 20, src_ip, dst_ip, sport, dport, payload_len);
    return ETH_HDR + 20 + 8 + payload_len;
}

export fn sk_init() -> void {
    socket_table_init(&g_socks);
}
export fn sk_bind(idx: usize, port: u16) -> u32 {
    switch socket_bind(&g_socks, idx, port) {
        ok(b) => {
            return 1;
        }
        err(e) => {
            return 0;
        }
    }
}
export fn rx_deliver(len: usize) -> u32 {
    switch net_rx_deliver(&g_socks, (&g_frame[0]) as usize, len) {
        ok(b) => {
            return 1;
        }
        err(e) => {
            return 0;
        }
    }
}
export fn sk_recv(idx: usize, dst: usize, max: usize) -> u64 {
    switch socket_recv(&g_socks, idx, dst, max) {
        ok(n) => {
            return n;
        }
        err(e) => {
            return 0xFFFF_FFFF_FFFF_FFFF;
        }
    }
}
export fn sk_last_port(idx: usize) -> u32 {
    return socket_last_src_port(&g_socks, idx) as u32;
}
