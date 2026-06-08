// Live receive path end to end: bring the NIC up, ARP the gateway (slirp replies,
// putting a real frame on the RX queue), copy that frame off the queue, and route it
// through the production receive demux (net_rx_deliver -> socket layer). One object
// importing both the driver and net_rx (the ETHERTYPE_IPV4 const clash was resolved
// by renaming net_rx's to RX_ETYPE_IPV4).

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/net/net_rx.mc";

const OUR_IP: u32 = 0x0A00_020F; // 10.0.2.15
const GW_IP: u32 = 0x0A00_0202;  // 10.0.2.2

global g_socks: SocketTable;

export fn rx_route_init(port: u16) -> void {
    socket_table_init(&g_socks);
    switch socket_bind(&g_socks, 0, port) {
        ok(b) => {}
        err(e) => {}
    }
}

// Bring up the NIC, ARP the gateway, and copy the next received frame into `buf`.
export fn rx_live_get_frame(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq, buf: usize, max: usize) -> usize {
    var dev: NetDevice = .{ .regs = regs, .rxq = rxq, .txq = txq };
    switch nic_init(&dev) {
        ok(up) => {}
        err(e) => {
            return 0;
        }
    }
    var mac: MacAddr = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };
    if !nic_send_arp(regs, txq, &mac, OUR_IP, GW_IP) {
        return 0;
    }
    return nic_rx_into(&dev, buf, max);
}

// Route a received frame through the demux: 0x8000_0000|len if delivered to a socket
// (UDP), else `len` (a real frame classified — e.g. an ARP reply -> NotIpv4).
export fn rx_route(buf: usize, len: usize) -> u32 {
    switch net_rx_deliver(&g_socks, buf, len) {
        ok(b) => {
            return 0x8000_0000 | (len as u32);
        }
        err(e) => {
            return len as u32;
        }
    }
}
