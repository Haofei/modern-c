// virtio-net driver (virtio 1.x). With the transport and the split virtqueue in
// std/virtio + std/virtqueue, this file is *only* the net-specific logic: the
// packet header layout and the init/transmit sequence — which now read like the
// spec's numbered steps. The C runtime (virtio_runtime.c) does platform
// discovery and hands over the device MmioPtr plus the DMA'd virtqueue memory.

import "../../std/virtio.mc";
import "../../std/virtqueue.mc";

const VIRTIO_NET_DEVICE_ID: u32 = 1;
const VIRTIO_F_VERSION_1_HI: u32 = 1; // feature bit 32 → high-word bit 0
const NET_HDR_LEN: u32 = 12;
const TX_QUEUE: u32 = 1;              // virtio-net: queue 0 = rx, queue 1 = tx

// virtio-net header, prepended to every frame (§5.1.6); 12 bytes (modern).
struct VirtioNetHdr {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
    num_buffers: u16,
}

struct PacketBuf {
    hdr: VirtioNetHdr,
    data: [64]u8,
}

// Bring the card up: negotiate VERSION_1, set up the TX queue, go live.
export fn nic_init(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq) -> bool {
    if !virtio_init(regs, VIRTIO_NET_DEVICE_ID, 0, VIRTIO_F_VERSION_1_HI) {
        return false;
    }
    vq_setup(regs, TX_QUEUE, txq);
    virtio_driver_ok(regs);
    return true;
}

// Transmit one frame: stamp the (no-offload) header, hand the buffer to the TX
// queue, ring the doorbell, and wait for the device to reap it.
export fn nic_transmit(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, pkt: *mut PacketBuf, payload_len: u16) -> bool {
    pkt.hdr.flags = 0;
    pkt.hdr.gso_type = 0;
    pkt.hdr.num_buffers = 0;

    let addr: u64 = bus_addr(PacketBuf, pkt);
    let total: u32 = (payload_len as u32) + NET_HDR_LEN;

    vq_add_buf(txq, addr, total, true); // device-readable (TX)
    vq_kick(regs, TX_QUEUE);
    return vq_wait_used(txq, 1_000_000);
}
