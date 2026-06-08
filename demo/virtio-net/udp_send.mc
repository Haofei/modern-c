// Send a real UDP datagram through the virtio-net driver: build Ethernet + IPv4 +
// UDP + payload into a TX frame (after the 12-byte virtio-net header) and push it
// through the DMA ownership cycle. The L2/L3 headers use the typed net byte-view
// helpers; the UDP header + checksum are written by `udp_write` through a ByteWriter
// over the same buffer memory (one UDP implementation, real checksum). Demonstrates
// the UDP layer in real transmission.

import "demo/virtio-net/virtio_net.mc"; // nic_init + the shared consts (TX_QUEUE, ...)
import "kernel/net/ethernet.mc";
import "kernel/net/ipv4.mc";
import "kernel/net/udp.mc";
import "std/bytes.mc";
import "std/dma.mc";

const NET_HDR: usize = 12;       // virtio-net header precedes the Ethernet frame
const IP_PROTO_UDP_B: u8 = 17;
const UDP_PAYLOAD_LEN: usize = 7; // "UDPTEST"

export fn udp_transmit(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq) -> bool {
    let frame_len: usize = ETH_HDR_LEN + 20 + 8 + UDP_PAYLOAD_LEN; // eth+ip+udp+payload
    var cpu: CpuBuffer = alloc(NET_HDR + frame_len);

    let eth_at: usize = NET_HDR;          // 12
    let ip_at: usize = eth_at + ETH_HDR_LEN; // 26
    let udp_at: usize = ip_at + 20;       // 46
    let payload_at: usize = udp_at + 8;   // 54

    let src_ip: u32 = 0x0A00_020F; // 10.0.2.15 (QEMU guest)
    let dst_ip: u32 = 0x0A00_0202; // 10.0.2.2  (QEMU gateway)

    var dst_mac: MacAddr = mac_broadcast();
    var src_mac: MacAddr = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };
    eth_write_header(&cpu, eth_at, &dst_mac, &src_mac, ETHERTYPE_IPV4);

    // IPv4 header: protocol UDP, payload = the UDP segment (header + data).
    ipv4_write_header(&cpu, ip_at, IP_PROTO_UDP_B, src_ip, dst_ip, 8 + UDP_PAYLOAD_LEN);

    // Payload "UDPTEST" (must be in place before udp_write checksums it).
    write_u8(&cpu, payload_at + 0, 0x55); // U
    write_u8(&cpu, payload_at + 1, 0x44); // D
    write_u8(&cpu, payload_at + 2, 0x50); // P
    write_u8(&cpu, payload_at + 3, 0x54); // T
    write_u8(&cpu, payload_at + 4, 0x45); // E
    write_u8(&cpu, payload_at + 5, 0x53); // S
    write_u8(&cpu, payload_at + 6, 0x54); // T

    // UDP header + pseudo-header checksum, written into the same buffer memory.
    var w: ByteWriter = byte_writer(cpu_addr(&cpu), cpu.len);
    udp_write(&w, udp_at, src_ip, dst_ip, 0x1234, 0x0035, UDP_PAYLOAD_LEN); // sport 4660, dport 53

    // DMA ownership cycle: hand off, submit, wait, reclaim.
    let dev: DeviceBuffer = clean_for_device(cpu);
    vq_submit_tx(txq, dev);
    vq_kick(regs, TX_QUEUE);
    var spins: u32 = 0;
    while spins < 1_000_000 {
        if vq_has_used(txq) {
            let done: DeviceBuffer = vq_complete(txq);
            free(invalidate_for_cpu(done));
            return true;
        }
        spins = spins + 1;
    }
    return false;
}
