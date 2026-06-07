// virtio-net driver (virtio 1.x). With the transport and split virtqueue in
// std/virtio + std/virtqueue, this file is *only* the net-specific logic. Buffers
// flow through the queue as linear `move` DMA handles (std/dma), so the ownership
// cycle is checked at compile time: a frame must be `clean_for_device`-d before
// it can be submitted, the CPU cannot touch it while in flight, and it is
// reclaimed (`invalidate_for_cpu`) before it can be read or freed again.

import "std/virtio.mc";
import "std/virtqueue.mc";

const VIRTIO_NET_DEVICE_ID: u32 = 1;
const VIRTIO_F_VERSION_1_HI: u32 = 1; // feature bit 32 → high-word bit 0
const TX_QUEUE: u32 = 1;              // virtio-net: queue 0 = rx, queue 1 = tx

// Bring the card up: require VERSION_1, set up the TX queue, go live.
export fn nic_init(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq) -> bool {
    if !virtio_init(regs, VIRTIO_NET_DEVICE_ID, 0, VIRTIO_F_VERSION_1_HI) {
        return false;
    }
    if !vq_setup(regs, TX_QUEUE, txq) {
        return false;
    }
    virtio_driver_ok(regs);
    return true;
}

// Transmit one frame through the full DMA ownership cycle: allocate a cpu-owned
// frame (12-byte net header + payload, zeroed), hand it to the device, submit it
// on the TX queue, wait for completion, then reclaim and free it.
export fn nic_transmit(regs: MmioPtr<VirtioMmio>, txq: *mut Virtq, payload_len: u16) -> bool {
    let cpu: CpuBuffer = alloc((payload_len as usize) + 12);
    let dev: DeviceBuffer = clean_for_device(cpu); // cpu consumed at handoff
    vq_submit_tx(txq, dev);                        // dev consumed; now in flight
    vq_kick(regs, TX_QUEUE);

    // Wait (bounded) for the device to return the buffer on the used ring.
    var spins: u32 = 0;
    while spins < 1_000_000 {
        if vq_has_used(txq) {
            let done: DeviceBuffer = vq_complete(txq); // reconstructed handle
            free(invalidate_for_cpu(done));            // reclaim and free
            return true;
        }
        spins = spins + 1;
    }
    return false; // device never completed; the buffer stays in flight
}
