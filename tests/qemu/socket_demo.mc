// Test wrappers around the UDP socket layer for the host driver.

import "kernel/net/udp_socket.mc";

const SOCK_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;

global g_socks: SocketTable;

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
export fn sk_deliver(dst_port: u16, src_ip: u32, src_port: u16, src_addr: usize, len: usize) -> u32 {
    switch socket_deliver(&g_socks, dst_port, src_ip, src_port, src_addr, len) {
        ok(b) => {
            return 1;
        }
        err(e) => {
            return 0;
        }
    }
}
export fn sk_recv(idx: usize, out_addr: usize, max: usize) -> u64 {
    switch socket_recv(&g_socks, idx, out_addr, max) {
        ok(n) => {
            return n;
        }
        err(e) => {
            return SOCK_ERR;
        }
    }
}
export fn sk_last_ip(idx: usize) -> u32 {
    return socket_last_src_ip(&g_socks, idx);
}
export fn sk_last_port(idx: usize) -> u32 {
    return socket_last_src_port(&g_socks, idx) as u32;
}
