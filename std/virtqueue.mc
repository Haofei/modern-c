// MC standard library — `virtqueue`: the virtio split virtqueue (§2.7). Owns the
// vring layout, queue setup, and the producer/consumer protocol — so the device
// driver never touches the shared rings directly. The raw cross-actor memory
// (the one part that isn't single-owner) is concentrated here behind a typed API.
//
// Buffers cross the queue boundary as linear `move` DMA handles (std/dma), not
// raw addresses: a buffer must be `clean_for_device`-d before it can be
// submitted, the CPU cannot touch it while it is in flight, and it is handed back
// (still device-owned) for the driver to reclaim — all checked at compile time.

import "virtio.mc";
import "barrier.mc";
import "dma.mc";

const QUEUE_SIZE: u16 = 8; // backing-array capacity (the negotiated size is ≤ this)
const VRING_DESC_F_WRITE: u16 = 2; // buffer is device-writable

// Split-virtqueue structures laid out per the spec, in DMA memory.
struct VringDesc { addr: u64, len: u32, flags: u16, next: u16 }
struct DescTable { d: [8]VringDesc }
struct VringAvail { flags: u16, idx: u16, ring: [8]u16, used_event: u16 }
struct UsedElem { id: u32, len: u32 }
struct VringUsed { flags: u16, idx: u16, ring: [8]UsedElem, avail_event: u16 }

// A driver-side handle bundling the three vring regions, the negotiated size,
// and the consumer cursor. Built from the DMA'd memory the platform provides.
struct Virtq {
    desc: *mut DescTable,
    avail: *mut VringAvail,
    used: *mut VringUsed,
    size: u16,
    last_used: u16,
}

// One reaped used-ring entry: which descriptor completed and how many bytes the
// device wrote (the received length for an RX buffer).
struct Completion {
    id: u16,
    len: u32,
}

fn lo32(a: u64) -> u32 { return (a & 0x0000_0000_FFFF_FFFF) as u32; }
fn hi32(a: u64) -> u32 { return (a >> 32) as u32; }

// The device-visible (bus) address of a DMA buffer. On a no-IOMMU platform this
// is the physical address; a generic helper so drivers don't open-code the cast.
export fn bus_addr(comptime T: type, p: *mut T) -> u64 {
    return p as usize as u64;
}

// Program the queue's three region addresses into the device and mark it ready
// (§4.2.3.2). Negotiates the queue size against the device's `queue_num_max`
// (capped at the backing-array size). Returns false if the queue is unavailable.
export fn vq_setup(regs: MmioPtr<VirtioMmio>, q: u32, vq: *mut Virtq) -> bool {
    regs.queue_sel.write(q, .release);
    let max: u32 = regs.queue_num_max.read(.acquire);
    if max == 0 {
        return false; // queue does not exist
    }
    var size: u32 = QUEUE_SIZE as u32;
    if max < size {
        size = max;
    }
    vq.size = size as u16;
    regs.queue_num.write(size, .release);

    let desc_a: u64 = vq.desc as usize as u64;
    let avail_a: u64 = vq.avail as usize as u64;
    let used_a: u64 = vq.used as usize as u64;
    regs.queue_desc_low.write(lo32(desc_a), .release);
    regs.queue_desc_high.write(hi32(desc_a), .release);
    regs.queue_driver_low.write(lo32(avail_a), .release);
    regs.queue_driver_high.write(hi32(avail_a), .release);
    regs.queue_device_low.write(lo32(used_a), .release);
    regs.queue_device_high.write(hi32(used_a), .release);
    regs.queue_ready.write(1, .release);

    vq.avail.flags = 0;
    vq.avail.idx = 0;
    vq.used.flags = 0;
    vq.last_used = 0;
    return true;
}

// Submit a device-owned buffer on the TX path: publish a single device-readable
// descriptor and advance the available ring. Consumes the `DeviceBuffer` and
// hands it back as the in-flight handle (still device-owned) for the driver to
// reclaim once the device returns it on the used ring. (v0: descriptor slot 0.)
export fn vq_submit_tx(vq: *mut Virtq, buf: DeviceBuffer) -> DeviceBuffer {
    let addr: u64 = device_addr(&buf) as u64; // borrow the handle's address
    let len: u32 = buf.len as u32;
    vq.desc.d[0].addr = addr;
    vq.desc.d[0].len = len;
    vq.desc.d[0].flags = 0; // device reads it
    vq.desc.d[0].next = 0;

    let cap: u16 = vq.size;
    let slot: usize = (vq.avail.idx % cap) as usize;
    vq.avail.ring[slot] = 0;
    wmb(); // descriptor + ring entry visible before the index bump
    vq.avail.idx = vq.avail.idx + 1;
    return buf; // in-flight handle
}

// Notify the device that `q` has new buffers (§4.2.3.3): order then doorbell.
export fn vq_kick(regs: MmioPtr<VirtioMmio>, q: u32) -> void {
    wmb();
    regs.queue_notify.write(q, .release);
}

// Has the device returned a buffer on the used ring since we last reaped?
export fn vq_used_ready(vq: *mut Virtq) -> bool {
    rmb();
    return vq.used.idx != vq.last_used;
}

// Reap one completed buffer: read the used-ring entry (which descriptor, and the
// device-written length) and advance the consumer cursor. Call only when
// `vq_used_ready` is true.
export fn vq_pop_used(vq: *mut Virtq) -> Completion {
    rmb();
    let cap: u16 = vq.size;
    let slot: usize = (vq.last_used % cap) as usize;
    let id: u16 = vq.used.ring[slot].id as u16;
    let len: u32 = vq.used.ring[slot].len;
    vq.last_used = vq.last_used + 1;
    return .{ .id = id, .len = len };
}

// Busy-wait (bounded) until the device returns a buffer; true if it did.
export fn vq_wait_used(vq: *mut Virtq, max_spins: u32) -> bool {
    var spins: u32 = 0;
    while spins < max_spins {
        if vq_used_ready(vq) {
            return true;
        }
        spins = spins + 1;
    }
    return false;
}
