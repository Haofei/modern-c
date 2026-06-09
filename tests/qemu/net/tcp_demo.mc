// Test wrappers around the TCP layer for the host driver.

import "kernel/net/tcp.mc";
import "std/bytes.mc";
import "std/addr.mc";

export fn tcp_build(buf: usize, buflen: usize, off: usize, src_ip: u32, dst_ip: u32, sport: u16, dport: u16, seq: u32, ack: u32, flags: u16, window: u16, payload_len: usize) -> void {
    var w: ByteWriter = byte_writer(pa(buf), buflen);
    tcp_write(&w, off, src_ip, dst_ip, sport, dport, seq, ack, flags, window, payload_len);
}

export fn tcp_get_sport(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: TcpHeader = tcp_parse(&r, off);
    return h.src_port as u32;
}
export fn tcp_get_dport(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: TcpHeader = tcp_parse(&r, off);
    return h.dst_port as u32;
}
export fn tcp_get_seq(buf: usize, buflen: usize, off: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: TcpHeader = tcp_parse(&r, off);
    return h.seq as u64;
}
export fn tcp_get_ack(buf: usize, buflen: usize, off: usize) -> u64 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: TcpHeader = tcp_parse(&r, off);
    return h.ack as u64;
}
export fn tcp_get_flags(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: TcpHeader = tcp_parse(&r, off);
    return h.flags as u32;
}
export fn tcp_get_window(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: TcpHeader = tcp_parse(&r, off);
    return h.window as u32;
}

export fn tcp_valid(buf: usize, buflen: usize, off: usize, src_ip: u32, dst_ip: u32, seg_len: u16) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    if tcp_checksum_valid(&r, off, src_ip, dst_ip, seg_len) {
        return 1;
    }
    return 0;
}
