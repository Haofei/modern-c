// kernel/net/net_rx — the receive demultiplex path. Parses a received Ethernet frame
// (Ethernet -> IPv4 -> UDP) over a bounds-checked reader and delivers the UDP payload
// to the socket layer via `socket_deliver`. This is what the NIC driver's RX
// completion calls on each frame. Non-IPv4 / non-UDP / malformed frames are dropped
// with a typed reason; a datagram for an unbound port surfaces the socket layer's
// NoListener. (Assumes a 20-byte IPv4 header, IHL=5 — options are a follow-up.)

import "std/bytes.mc";
import "kernel/net/udp.mc";
import "kernel/net/udp_socket.mc";

const ETH_HDR: usize = 14;
const IP_HDR: usize = 20;
const UDP_HDR: usize = 8;
const RX_ETYPE_IPV4: u16 = 0x0800;
const IP_PROTO_UDP_B: u8 = 17;

enum RxError {
    TooShort,  // frame smaller than eth+ip+udp headers
    NotIpv4,   // ethertype is not IPv4
    NotUdp,    // IP protocol is not UDP
    BadLength, // UDP length field is nonsensical
    Delivery,  // socket layer rejected it (e.g. no listener)
}

// Parse + deliver one received frame located at `frame` (`len` bytes).
export fn net_rx_deliver(t: *mut SocketTable, frame: usize, len: usize) -> Result<bool, RxError> {
    if len < (ETH_HDR + IP_HDR + UDP_HDR) {
        return err(.TooShort);
    }
    var r: ByteReader = byte_reader(pa(frame), len);

    let ethertype: u16 = br_be16(&r, 12);
    if ethertype != RX_ETYPE_IPV4 {
        return err(.NotIpv4);
    }

    let proto: u8 = br_u8(&r, ETH_HDR + 9);
    if proto != IP_PROTO_UDP_B {
        return err(.NotUdp);
    }
    let src_ip: u32 = br_be32(&r, ETH_HDR + 12);

    let udp_at: usize = ETH_HDR + IP_HDR;
    var h: UdpHeader = udp_parse(&r, udp_at);
    let total: usize = h.length as usize;
    if total < UDP_HDR {
        return err(.BadLength);
    }
    if (udp_at + total) > len {
        return err(.BadLength);
    }
    let payload_at: usize = udp_at + UDP_HDR;
    let payload_len: usize = total - UDP_HDR;

    switch socket_deliver(t, h.dst_port, src_ip, h.src_port, frame + payload_at, payload_len) {
        ok(b) => {
            return ok(true);
        }
        err(e) => {
            return err(.Delivery);
        }
    }
}
