// Test wrappers around the UDP layer for the host driver: build a datagram and
// read its fields / validate its checksum over a plain byte buffer.

import "kernel/net/udp.mc";
import "std/bytes.mc";
import "std/addr.mc";

export fn udp_build(buf: usize, buflen: usize, off: usize, src_ip: u32, dst_ip: u32, src_port: u16, dst_port: u16, payload_len: usize) -> void {
    var w: ByteWriter = byte_writer(pa(buf), buflen);
    udp_write(&w, off, src_ip, dst_ip, src_port, dst_port, payload_len);
}

export fn udp_sport(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: UdpHeader = udp_parse(&r, off);
    return h.src_port as u32;
}

export fn udp_dport(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: UdpHeader = udp_parse(&r, off);
    return h.dst_port as u32;
}

export fn udp_len(buf: usize, buflen: usize, off: usize) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    var h: UdpHeader = udp_parse(&r, off);
    return h.length as u32;
}

export fn udp_valid(buf: usize, buflen: usize, off: usize, src_ip: u32, dst_ip: u32) -> u32 {
    var r: ByteReader = byte_reader(pa(buf), buflen);
    if udp_checksum_valid(&r, off, src_ip, dst_ip) {
        return 1;
    }
    return 0;
}
