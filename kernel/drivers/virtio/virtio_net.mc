// kernel/drivers/virtio/virtio_net — virtio-net (virtio 1.x) with RX + TX queues.
//
// Builds on std/virtio (transport + handshake) and std/virtqueue (split queue
// with a descriptor free list). Frames cross the queues as linear `move` DMA
// handles, so the ownership cycle is compile-checked. Net protocol logic lives in
// kernel/net; this file is only the device glue.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/time.mc";
import "kernel/net/arp.mc";    // brings kernel/net/ethernet.mc transitively
import "kernel/net/icmp.mc";   // brings kernel/net/ipv4.mc transitively
import "kernel/net/packet.mc"; // Ipv4Addr

const VIRTIO_NET_DEVICE_ID: u32 = 1;
const VIRTIO_F_VERSION_1_HI: u32 = 1; // feature bit 32 → high-word bit 0
const RX_QUEUE: u32 = 0;              // virtio-net: queue 0 = rx, queue 1 = tx
const TX_QUEUE: u32 = 1;

const NET_HDR_LEN: usize = 12;   // virtio_net_hdr precedes every frame
const FRAME_AT: usize = 12;      // ...so the Ethernet frame starts at offset 12
const ETH_MIN_FRAME: usize = 60; // minimum Ethernet frame (ARP/ICMP frames are
                                 // 42 bytes and get zero-padded up to this)
const RX_BUF_LEN: usize = 2048;
const RX_REFILL: u32 = 4;       // device-writable buffers kept posted
const PING_IDENT: u16 = 0x1234; // ICMP echo identifier we send and expect back
const PING_SEQ: u16 = 1;        // ICMP echo sequence number
const IO_TIMEOUT_TICKS: u64 = 10_000_000; // ~1s at the CLINT's 10 MHz (real-time bound)
// (ARP_OP_REPLY comes from kernel/net/arp.mc)

// (Our MAC/IP identity comes from the platform `Machine`, threaded in as
// `src_mac` / `src_ip` rather than hard-coded in the driver.)

// The driver's recoverable failure modes — a typed error instead of a lossy
// `bool` (the caller learns *why* it failed). Success carries a placeholder `true`.
enum NetError {
    DeviceInitFailed, // virtio handshake / feature negotiation failed
    QueueUnavailable, // a virtqueue could not be set up
    ArpFailed,        // no usable ARP reply from the gateway
    PingTimeout,      // no ICMP echo reply in time
    BadReply,         // a reply arrived but did not match our request
}

// The device-class surface: the register block plus the RX/TX queues, bundled
// into one handle. The net stack (ARP/IPv4/ICMP) never sees these — it works on
// cpu-owned buffers — so this stays the boundary between transport/queue and
// protocol.
struct NetDevice {
    regs: MmioPtr<VirtioMmio>,
    rxq: *mut Virtq,
    txq: *mut Virtq,
}

// Post one device-writable RX buffer for the card to fill.
fn post_rx_buffer(rxq: *mut Virtq) -> void {
    let cpu: CpuBuffer = alloc(RX_BUF_LEN);
    let dev: DeviceBuffer = clean_for_device(cpu); // cpu consumed
    switch vq_submit_rx(rxq, dev) {                // dev consumed (in flight, or reclaimed)
        ok(id) => {}
        err(e) => {} // queue full: the refill is skipped and the buffer reclaimed inside
    }
}

// A completion timed out, or the device returned an inconsistent used-ring entry: the queue
// still owns submitted buffers. Reset the device so it relinquishes them, then reclaim and
// free every in-flight buffer (rather than abandoning them or trapping). After a fault the
// NIC must be re-initialised (`nic_init`) before reuse; callers report the failure upward.
fn nic_fault_reset(regs: MmioPtr<VirtioMmio>, q: *mut Virtq) -> void {
    virtio_reset(regs);
    vq_reset_reclaim(q);
}

// Bring the card up: require VERSION_1, set up both queues, go live, and post the
// initial RX buffers.
export fn nic_init(dev: *NetDevice) -> Result<bool, NetError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let rxq: *mut Virtq = dev.rxq;
    let txq: *mut Virtq = dev.txq;
    switch virtio_init(regs, VIRTIO_NET_DEVICE_ID, 0, VIRTIO_F_VERSION_1_HI) {
        ok(up) => {}
        err(e) => { return err(.DeviceInitFailed); }
    }
    switch vq_setup(regs, RX_QUEUE, rxq) {
        ok(up) => {}
        err(e) => { return err(.QueueUnavailable); }
    }
    switch vq_setup(regs, TX_QUEUE, txq) {
        ok(up) => {}
        err(e) => { return err(.QueueUnavailable); }
    }
    virtio_driver_ok(regs);

    var i: u32 = 0;
    while i < RX_REFILL {
        post_rx_buffer(rxq);
        i = i + 1;
    }
    vq_kick(regs, RX_QUEUE);
    return ok(true);
}

// Send a broadcast ARP request for `target_ip` and reclaim the TX buffer.
export fn nic_send_arp(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, src_mac: *MacAddr, src_ip: u32, target_ip: u32) -> bool {
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + ETH_MIN_FRAME);
    // The virtio_net_hdr at offset 0 is left zeroed by the allocator.
    arp_write_request(&cpu, FRAME_AT, src_mac, src_ip, target_ip);
    let dev: DeviceBuffer = clean_for_device(cpu); // cpu consumed
    switch vq_submit_tx(txq, dev) {                // dev consumed (in flight, or reclaimed)
        ok(id) => {}
        err(e) => { return false; } // queue full: buffer reclaimed inside, nothing to send
    }
    vq_kick(regs, TX_QUEUE);

    if !vq_wait_used(txq, IO_TIMEOUT_TICKS) {
        nic_fault_reset(regs, txq); // device never completed: reclaim, don't abandon
        return false;
    }
    switch vq_complete(txq) {
        ok(cb) => {
            let rb: DeviceBuffer = cb.buf; // reclaim the full allocation, not the used length
            unsafe { forget_unchecked(cb); }
            free(invalidate_for_cpu(rb));
            return true;
        }
        err(e) => {
            nic_fault_reset(regs, txq); // inconsistent completion: reset and reclaim
            return false;
        }
    }
}

// Poll the RX queue once. Returns the sender IP of a received ARP reply, or 0 if
// nothing was received (or it was not an ARP reply). Refills the consumed buffer.
export fn nic_poll_arp(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq) -> u32 {
    if !vq_has_used(rxq) {
        return 0;
    }
    switch vq_complete(rxq) {
        ok(cb) => {
            let dev: DeviceBuffer = cb.buf; // buffer len = full allocation; used in cb.used_len
            unsafe { forget_unchecked(cb); }
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
        err(e) => {
            nic_fault_reset(regs, rxq); // inconsistent completion: reset and reclaim
            return 0;
        }
    }
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

// Parse the Ethernet frame in a received RX buffer into a plain record, reading only the
// `len` bytes the device actually delivered (never the whole allocation).
fn parse_rx_frame(cpu: *CpuBuffer, len: usize) -> RxFrame {
    var out: RxFrame = .{
        .valid = true, .ethertype = 0,
        .is_arp_reply = false, .is_arp_request = false,
        .is_icmp_reply = false, .is_icmp_request = false,
        .src_ip = 0, .target_ip = 0,
        .src_mac = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } },
        .icmp_ident = 0, .icmp_seq = 0,
    };
    // Only parse fields the device actually delivered: check the received length before
    // reading the Ethernet header, then the ARP / IPv4+ICMP bodies (42 bytes past FRAME_AT).
    if len >= FRAME_AT + 14 {
        out.ethertype = eth_ethertype(cpu, FRAME_AT);
        out.src_mac = eth_read_mac(cpu, FRAME_AT + 6);
        if out.ethertype == ETHERTYPE_ARP {
            if len >= FRAME_AT + 28 {
                let oper: u16 = arp_oper(cpu, FRAME_AT);
                out.src_ip = arp_sender_ip(cpu, FRAME_AT);
                out.target_ip = arp_target_ip(cpu, FRAME_AT);
                if oper == ARP_OP_REPLY {
                    out.is_arp_reply = true;
                }
                if oper == ARP_OP_REQUEST {
                    out.is_arp_request = true;
                }
            }
        }
        if out.ethertype == ETHERTYPE_IPV4 {
            // Only treat it as ICMP after the IPv4 header checks out: full length, valid
            // header checksum, and protocol == ICMP.
            let ip_at: usize = FRAME_AT + 14;
            if len >= FRAME_AT + 42 {
                if ipv4_checksum_valid(cpu, ip_at) {
                    if ipv4_protocol(cpu, ip_at) == IP_PROTO_ICMP {
                        let kind: u8 = icmp_type(cpu, FRAME_AT);
                        out.src_ip = ipv4_src_ip(cpu, ip_at);
                        out.target_ip = ipv4_dst_ip(cpu, ip_at);
                        out.icmp_ident = icmp_ident(cpu, FRAME_AT);
                        out.icmp_seq = icmp_seq(cpu, FRAME_AT);
                        if kind == ICMP_ECHO_REPLY {
                            out.is_icmp_reply = true;
                        }
                        if kind == ICMP_ECHO_REQUEST {
                            out.is_icmp_request = true;
                        }
                    }
                }
            }
        }
    }
    return out;
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
    let start: Ticks = read_ticks();
    while !timed_out(start, read_ticks(), IO_TIMEOUT_TICKS) {
        if vq_has_used(rxq) {
            switch vq_complete(rxq) {
                ok(cb) => {
                    let recv: usize = cb.used_len as usize; // bytes the device actually wrote
                    let dev: DeviceBuffer = cb.buf;
                    unsafe { forget_unchecked(cb); }
                    var cpu: CpuBuffer = invalidate_for_cpu(dev);
                    out = parse_rx_frame(&cpu, recv);
                    free(cpu);
                    post_rx_buffer(rxq);
                    vq_kick(regs, RX_QUEUE);
                    return out;
                }
                err(e) => {
                    nic_fault_reset(regs, rxq); // inconsistent completion: reset and reclaim
                    return out; // out.valid stays false
                }
            }
        }
    }
    return out;
}

// Wait (bounded by a real-time deadline) for the device to return a TX buffer.
fn tx_wait_reclaim(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq) -> bool {
    if vq_wait_used(txq, IO_TIMEOUT_TICKS) {
        switch vq_complete(txq) {
            ok(cb) => {
                let rb: DeviceBuffer = cb.buf; // reclaim the full allocation, not used length
                unsafe { forget_unchecked(cb); }
                free(invalidate_for_cpu(rb));
                return true;
            }
            err(e) => {
                nic_fault_reset(regs, txq); // inconsistent completion: reset and reclaim
                return false;
            }
        }
    }
    nic_fault_reset(regs, txq); // timeout: reclaim the stuck buffer rather than abandon it
    return false;
}

// Ping the gateway: ARP for its MAC, send an ICMP echo request, await the reply.
// The full Ethernet/IPv4/ICMP path over real virtio-net DMA.
export fn nic_ping_gateway(dev: *NetDevice, src_mac: *MacAddr, src_ip: Ipv4Addr, gw_ip: Ipv4Addr) -> Result<bool, NetError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let rxq: *mut Virtq = dev.rxq;
    let txq: *mut Virtq = dev.txq;
    // 1. Resolve the gateway's hardware address.
    if !nic_send_arp(regs, txq, src_mac, src_ip.raw, gw_ip.raw) {
        return err(.ArpFailed);
    }
    var arp_rx: RxFrame = rx_receive(regs, rxq);
    if !arp_rx.is_arp_reply {
        return err(.ArpFailed);
    }
    if arp_rx.src_ip != gw_ip.raw {
        return err(.BadReply); // a reply, but not from the gateway we asked about
    }
    var gw_mac: MacAddr = arp_rx.src_mac;

    // 2. Send an ICMP echo request to the gateway.
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + ETH_MIN_FRAME);
    icmp_write_echo_request(&cpu, FRAME_AT, src_mac, &gw_mac, src_ip.raw, gw_ip.raw, PING_IDENT, PING_SEQ);
    let frame: DeviceBuffer = clean_for_device(cpu);
    switch vq_submit_tx(txq, frame) {
        ok(id) => {}
        err(e) => { return err(.PingTimeout); } // queue full: buffer reclaimed inside
    }
    vq_kick(regs, TX_QUEUE);
    if !tx_wait_reclaim(regs, txq) {
        return err(.PingTimeout);
    }

    // 3. Await the ICMP echo reply — and confirm it is *our* reply (from the
    // gateway, echoing our identifier and sequence) rather than unrelated traffic.
    var icmp_rx: RxFrame = rx_receive(regs, rxq);
    if !icmp_rx.is_icmp_reply {
        return err(.PingTimeout);
    }
    if icmp_rx.src_ip != gw_ip.raw {
        return err(.BadReply);
    }
    if icmp_rx.icmp_ident != PING_IDENT {
        return err(.BadReply);
    }
    if icmp_rx.icmp_seq != PING_SEQ {
        return err(.BadReply);
    }
    return ok(true);
}

// Resolve `target_ip`'s hardware address via ARP (send a request, await the reply).
export fn nic_arp_resolve(dev: *NetDevice, src_mac: *MacAddr, src_ip: u32, target_ip: u32) -> Result<MacAddr, NetError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let rxq: *mut Virtq = dev.rxq;
    let txq: *mut Virtq = dev.txq;
    if !nic_send_arp(regs, txq, src_mac, src_ip, target_ip) {
        return err(.ArpFailed);
    }
    var rx: RxFrame = rx_receive(regs, rxq);
    if !rx.is_arp_reply {
        return err(.ArpFailed);
    }
    if rx.src_ip != target_ip {
        return err(.BadReply);
    }
    return ok(rx.src_mac);
}

// Receive one RX frame (bounded wait) and copy the Ethernet frame (past the 12-byte
// virtio-net header) into `dst`; returns its length (0 on timeout). The decoupled
// real-RX primitive: the caller routes the bytes onward (e.g. to net_rx_deliver),
// keeping the driver independent of the protocol layers.
export fn nic_rx_into(dev: *NetDevice, dst: usize, max: usize) -> usize {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let rxq: *mut Virtq = dev.rxq;
    let start: Ticks = read_ticks();
    while !timed_out(start, read_ticks(), IO_TIMEOUT_TICKS) {
        if vq_has_used(rxq) {
            switch vq_complete(rxq) {
                ok(cb) => {
                    let recv: usize = cb.used_len as usize; // bytes the device actually wrote
                    let d: DeviceBuffer = cb.buf;
                    unsafe { forget_unchecked(cb); }
                    var cpu: CpuBuffer = invalidate_for_cpu(d);
                    let total: usize = recv; // copy out only the received bytes
                    var n: usize = 0;
                    if total > FRAME_AT {
                        n = total - FRAME_AT;
                        if n > max {
                            n = max;
                        }
                        var i: usize = 0;
                        while i < n {
                            let b: u8 = read_u8(&cpu, FRAME_AT + i);
                            unsafe {
                                raw.store<u8>(phys(dst + i), b);
                            }
                            i = i + 1;
                        }
                    }
                    free(cpu);
                    post_rx_buffer(rxq);
                    vq_kick(regs, RX_QUEUE);
                    return n;
                }
                err(e) => {
                    nic_fault_reset(regs, rxq); // inconsistent completion: reset and reclaim
                    return 0;
                }
            }
        }
    }
    return 0;
}

// ----- inbound responder (the host→guest "pingable" path) -----

fn send_arp_reply(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, src_mac: *MacAddr, our_ip: u32, dst_mac: *MacAddr, dst_ip: u32) -> void {
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + ETH_MIN_FRAME);
    arp_write_reply(&cpu, FRAME_AT, src_mac, our_ip, dst_mac, dst_ip);
    let dev: DeviceBuffer = clean_for_device(cpu);
    switch vq_submit_tx(txq, dev) {
        ok(id) => {}
        err(e) => { return; } // queue full: buffer reclaimed inside, drop the reply
    }
    vq_kick(regs, TX_QUEUE);
    tx_wait_reclaim(regs, txq);
}

fn send_icmp_reply(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, src_mac: *MacAddr, our_ip: u32, dst_mac: *MacAddr, dst_ip: u32, ident: u16, seq: u16) -> void {
    var cpu: CpuBuffer = alloc(NET_HDR_LEN + ETH_MIN_FRAME);
    icmp_write_echo_reply(&cpu, FRAME_AT, src_mac, dst_mac, our_ip, dst_ip, ident, seq);
    let dev: DeviceBuffer = clean_for_device(cpu);
    switch vq_submit_tx(txq, dev) {
        ok(id) => {}
        err(e) => { return; } // queue full: buffer reclaimed inside, drop the reply
    }
    vq_kick(regs, TX_QUEUE);
    tx_wait_reclaim(regs, txq);
}

// Serve one inbound frame: answer an ARP request or an ICMP echo request aimed at
// our address. Returns true if a reply was sent. This is what makes the guest
// answerable to a host `ping` (host→guest needs a tap netdev to exercise).
export fn nic_serve_once(dev: *NetDevice, src_mac: *MacAddr, our_ip: Ipv4Addr) -> bool {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let rxq: *mut Virtq = dev.rxq;
    let txq: *mut Virtq = dev.txq;
    var rx: RxFrame = rx_receive(regs, rxq);
    if !rx.valid {
        return false;
    }
    if rx.is_arp_request {
        if rx.target_ip == our_ip.raw {
            send_arp_reply(regs, txq, src_mac, our_ip.raw, &rx.src_mac, rx.src_ip);
            return true;
        }
    }
    if rx.is_icmp_request {
        if rx.target_ip == our_ip.raw {
            send_icmp_reply(regs, txq, src_mac, our_ip.raw, &rx.src_mac, rx.src_ip, rx.icmp_ident, rx.icmp_seq);
            return true;
        }
    }
    return false;
}

// The kernel's network event loop (poll mode): serve up to `rounds` frames,
// returning how many replies were sent. NOTE: each round may allocate an RX
// refill and a TX reply; with the platform's one-shot bump DMA pool (net_runtime),
// sustained serving eventually exhausts it. A recycling DMA allocator (a free list
// in `mc_dma_free`) is the next step for an unbounded event loop.
export fn nic_serve(dev: *NetDevice, src_mac: *MacAddr, our_ip: Ipv4Addr, rounds: u32) -> u32 {
    var served: u32 = 0;
    var i: u32 = 0;
    while i < rounds {
        if nic_serve_once(dev, src_mac, our_ip) {
            served = served + 1;
        }
        i = i + 1;
    }
    return served;
}
