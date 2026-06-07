// kernel/drivers/virtio/virtio_net — virtio-net (virtio 1.x) with RX + TX queues.
//
// Builds on std/virtio (transport + handshake) and std/virtqueue (split queue
// with a descriptor free list). Frames cross the queues as linear `move` DMA
// handles, so the ownership cycle is compile-checked. Net protocol logic lives in
// kernel/net; this file is only the device glue.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "kernel/net/arp.mc";  // brings kernel/net/ethernet.mc transitively
import "kernel/net/icmp.mc"; // brings kernel/net/ipv4.mc transitively

const VIRTIO_NET_DEVICE_ID: u32 = 1;
const VIRTIO_F_VERSION_1_HI: u32 = 1; // feature bit 32 → high-word bit 0
const RX_QUEUE: u32 = 0;              // virtio-net: queue 0 = rx, queue 1 = tx
const TX_QUEUE: u32 = 1;

const NET_HDR_LEN: usize = 12;  // virtio_net_hdr precedes every frame
const FRAME_AT: usize = 12;     // ...so the Ethernet frame starts at offset 12
const RX_BUF_LEN: usize = 2048;
const RX_REFILL: u32 = 4;       // device-writable buffers kept posted
// (ARP_OP_REPLY comes from kernel/net/arp.mc)

// Our static identity (host can reach us at OUR_IP).
fn our_mac() -> MacAddr {
    return .{ .bytes = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 } };
}

// Post one device-writable RX buffer for the card to fill.
fn post_rx_buffer(rxq: *mut Virtq) -> void {
    let cpu: CpuBuffer = alloc(RX_BUF_LEN);
    let dev: DeviceBuffer = clean_for_device(cpu); // cpu consumed
    vq_submit_rx(rxq, dev);                        // dev consumed (in flight)
}

// Bring the card up: require VERSION_1, set up both queues, go live, and post the
// initial RX buffers.
export fn nic_init(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq) -> bool {
    if !virtio_init(regs, VIRTIO_NET_DEVICE_ID, 0, VIRTIO_F_VERSION_1_HI) {
        return false;
    }
    if !vq_setup(regs, RX_QUEUE, rxq) {
        return false;
    }
    if !vq_setup(regs, TX_QUEUE, txq) {
        return false;
    }
    virtio_driver_ok(regs);

    var i: u32 = 0;
    while i < RX_REFILL {
        post_rx_buffer(rxq);
        i = i + 1;
    }
    vq_kick(regs, RX_QUEUE);
    return true;
}

// Send a broadcast ARP request for `target_ip` and reclaim the TX buffer.
export fn nic_send_arp(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, src_ip: u32, target_ip: u32) -> bool {
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + 64);
    var smac: MacAddr = our_mac();
    // The virtio_net_hdr at offset 0 is left zeroed by the allocator.
    arp_write_request(&cpu, FRAME_AT, &smac, src_ip, target_ip);
    let dev: DeviceBuffer = clean_for_device(cpu); // cpu consumed
    vq_submit_tx(txq, dev);                        // dev consumed (in flight)
    vq_kick(regs, TX_QUEUE);

    var got: bool = false;
    var spins: u32 = 0;
    while spins < 1_000_000 {
        if vq_has_used(txq) {
            got = true;
            break;
        }
        spins = spins + 1;
    }
    if !got {
        return false; // buffer stuck in flight (device never completed)
    }
    free(invalidate_for_cpu(vq_complete(txq)));
    return true;
}

// Poll the RX queue once. Returns the sender IP of a received ARP reply, or 0 if
// nothing was received (or it was not an ARP reply). Refills the consumed buffer.
export fn nic_poll_arp(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq) -> u32 {
    if !vq_has_used(rxq) {
        return 0;
    }
    let dev: DeviceBuffer = vq_complete(rxq);  // reconstructed, len = bytes received
    var cpu: CpuBuffer = invalidate_for_cpu(dev);

    var sender: u32 = 0;
    if eth_ethertype(&cpu, FRAME_AT) == ETHERTYPE_ARP {
        if arp_oper(&cpu, FRAME_AT) == ARP_OP_REPLY {
            sender = arp_sender_ip(&cpu, FRAME_AT);
        }
    }
    free(cpu);

    // Keep the RX ring topped up.
    post_rx_buffer(rxq);
    vq_kick(regs, RX_QUEUE);
    return sender;
}

// A received frame parsed into plain (copyable) fields, so callers never touch
// the move-typed DMA buffer directly.
struct RxFrame {
    valid: bool,
    ethertype: u16,
    is_arp_reply: bool,
    is_arp_request: bool,
    is_icmp_reply: bool,
    is_icmp_request: bool,
    src_ip: u32,     // sender: ARP sender protocol addr / IPv4 source
    target_ip: u32,  // ARP target protocol addr / IPv4 destination
    src_mac: MacAddr,
    icmp_ident: u16,
    icmp_seq: u16,
}

// Wait (bounded) for one RX frame, parse it, free + refill the buffer, and return
// the plain record. `valid` is false on timeout.
fn rx_receive(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq) -> RxFrame {
    var out: RxFrame = .{
        .valid = false, .ethertype = 0,
        .is_arp_reply = false, .is_arp_request = false,
        .is_icmp_reply = false, .is_icmp_request = false,
        .src_ip = 0, .target_ip = 0,
        .src_mac = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } },
        .icmp_ident = 0, .icmp_seq = 0,
    };
    var spins: u32 = 0;
    while spins < 5_000_000 {
        if vq_has_used(rxq) {
            let dev: DeviceBuffer = vq_complete(rxq);
            var cpu: CpuBuffer = invalidate_for_cpu(dev);
            out.valid = true;
            out.ethertype = eth_ethertype(&cpu, FRAME_AT);
            out.src_mac = eth_read_mac(&cpu, FRAME_AT + 6);
            if out.ethertype == ETHERTYPE_ARP {
                let oper: u16 = arp_oper(&cpu, FRAME_AT);
                out.src_ip = arp_sender_ip(&cpu, FRAME_AT);
                out.target_ip = arp_target_ip(&cpu, FRAME_AT);
                if oper == ARP_OP_REPLY {
                    out.is_arp_reply = true;
                }
                if oper == ARP_OP_REQUEST {
                    out.is_arp_request = true;
                }
            }
            if out.ethertype == ETHERTYPE_IPV4 {
                let kind: u8 = icmp_type(&cpu, FRAME_AT);
                out.src_ip = ipv4_src_ip(&cpu, FRAME_AT + 14);
                out.target_ip = ipv4_dst_ip(&cpu, FRAME_AT + 14);
                out.icmp_ident = icmp_ident(&cpu, FRAME_AT);
                out.icmp_seq = icmp_seq(&cpu, FRAME_AT);
                if kind == ICMP_ECHO_REPLY {
                    out.is_icmp_reply = true;
                }
                if kind == ICMP_ECHO_REQUEST {
                    out.is_icmp_request = true;
                }
            }
            free(cpu);
            post_rx_buffer(rxq);
            vq_kick(regs, RX_QUEUE);
            return out;
        }
        spins = spins + 1;
    }
    return out;
}

// Wait (bounded) for the device to return a TX buffer and reclaim it.
fn tx_wait_reclaim(txq: *mut Virtq) -> bool {
    var spins: u32 = 0;
    while spins < 1_000_000 {
        if vq_has_used(txq) {
            free(invalidate_for_cpu(vq_complete(txq)));
            return true;
        }
        spins = spins + 1;
    }
    return false;
}

// Ping the gateway: ARP for its MAC, send an ICMP echo request, await the reply.
// The full Ethernet/IPv4/ICMP path over real virtio-net DMA.
export fn nic_ping_gateway(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq, src_ip: u32, gw_ip: u32) -> bool {
    // 1. Resolve the gateway's hardware address.
    if !nic_send_arp(regs, txq, src_ip, gw_ip) {
        return false;
    }
    var arp_rx: RxFrame = rx_receive(regs, rxq);
    if !arp_rx.is_arp_reply {
        return false;
    }
    var gw_mac: MacAddr = arp_rx.src_mac;

    // 2. Send an ICMP echo request to the gateway.
    var smac: MacAddr = our_mac();
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + 64);
    icmp_write_echo_request(&cpu, FRAME_AT, &smac, &gw_mac, src_ip, gw_ip, 0x1234, 1);
    let dev: DeviceBuffer = clean_for_device(cpu);
    vq_submit_tx(txq, dev);
    vq_kick(regs, TX_QUEUE);
    if !tx_wait_reclaim(txq) {
        return false;
    }

    // 3. Await the ICMP echo reply.
    var icmp_rx: RxFrame = rx_receive(regs, rxq);
    return icmp_rx.is_icmp_reply;
}

// ----- inbound responder (the host→guest "pingable" path) -----

fn send_arp_reply(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, our_ip: u32, dst_mac: *MacAddr, dst_ip: u32) -> void {
    var smac: MacAddr = our_mac();
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + 64);
    arp_write_reply(&cpu, FRAME_AT, &smac, our_ip, dst_mac, dst_ip);
    let dev: DeviceBuffer = clean_for_device(cpu);
    vq_submit_tx(txq, dev);
    vq_kick(regs, TX_QUEUE);
    tx_wait_reclaim(txq);
}

fn send_icmp_reply(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, our_ip: u32, dst_mac: *MacAddr, dst_ip: u32, ident: u16, seq: u16) -> void {
    var smac: MacAddr = our_mac();
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + 64);
    icmp_write_echo_reply(&cpu, FRAME_AT, &smac, dst_mac, our_ip, dst_ip, ident, seq);
    let dev: DeviceBuffer = clean_for_device(cpu);
    vq_submit_tx(txq, dev);
    vq_kick(regs, TX_QUEUE);
    tx_wait_reclaim(txq);
}

// Serve one inbound frame: answer an ARP request or an ICMP echo request aimed at
// our address. Returns true if a reply was sent. This is what makes the guest
// answerable to a host `ping` (host→guest needs a tap netdev to exercise).
export fn nic_serve_once(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq, our_ip: u32) -> bool {
    var rx: RxFrame = rx_receive(regs, rxq);
    if !rx.valid {
        return false;
    }
    if rx.is_arp_request {
        if rx.target_ip == our_ip {
            send_arp_reply(regs, txq, our_ip, &rx.src_mac, rx.src_ip);
            return true;
        }
    }
    if rx.is_icmp_request {
        if rx.target_ip == our_ip {
            send_icmp_reply(regs, txq, our_ip, &rx.src_mac, rx.src_ip, rx.icmp_ident, rx.icmp_seq);
            return true;
        }
    }
    return false;
}

// The kernel's network event loop (poll mode): serve up to `rounds` frames,
// returning how many replies were sent.
export fn nic_serve(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq, our_ip: u32, rounds: u32) -> u32 {
    var served: u32 = 0;
    var i: u32 = 0;
    while i < rounds {
        if nic_serve_once(regs, rxq, txq, our_ip) {
            served = served + 1;
        }
        i = i + 1;
    }
    return served;
}
