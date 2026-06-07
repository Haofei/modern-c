// MC standard library — `virtqueue`: the virtio split virtqueue (§2.7). Owns the
// vring layout, queue setup, and the producer/consumer protocol — so the device
// driver never touches the shared rings directly. The raw cross-actor memory
// (the one part that isn't single-owner) is concentrated here behind a typed API.

import "virtio.mc";
import "barrier.mc";

const QUEUE_SIZE: u16 = 8;
const VRING_DESC_F_WRITE: u16 = 2; // buffer is device-writable

// Split-virtqueue structures laid out per the spec, in DMA memory.
struct VringDesc { addr: u64, len: u32, flags: u16, next: u16 }
struct DescTable { d: [8]VringDesc }
struct VringAvail { flags: u16, idx: u16, ring: [8]u16, used_event: u16 }
struct UsedElem { id: u32, len: u32 }
struct VringUsed { flags: u16, idx: u16, ring: [8]UsedElem, avail_event: u16 }

// A driver-side handle bundling the three vring regions plus the consumer
// cursor. The driver builds one from the DMA'd memory the platform provides.
struct Virtq {
    desc: *mut DescTable,
    avail: *mut VringAvail,
    used: *mut VringUsed,
    last_used: u16,
}

fn lo32(a: u64) -> u32 { return (a & 0x0000_0000_FFFF_FFFF) as u32; }
fn hi32(a: u64) -> u32 { return (a >> 32) as u32; }

// The device-visible (bus) address of a DMA buffer. On a no-IOMMU platform this
// is the physical address; a generic helper so drivers don't open-code the cast.
export fn bus_addr(comptime T: type, p: *mut T) -> u64 {
    return p as usize as u64;
}

// Program the queue's three region addresses into the device and mark it ready
// (§4.2.3.2). Absorbs the 64-bit-address split across the low/high registers.
export fn vq_setup(regs: MmioPtr<VirtioMmio>, q: u32, vq: *mut Virtq) -> void {
    let desc_a: u64 = vq.desc as usize as u64;
    let avail_a: u64 = vq.avail as usize as u64;
    let used_a: u64 = vq.used as usize as u64;

    regs.queue_sel.write(q, .release);
    regs.queue_num.write(QUEUE_SIZE as u32, .release);
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
}

// Add a single buffer to the queue and publish it in the available ring.
// `device_readable` = the device reads it (TX); otherwise it writes it (RX).
// Returns the descriptor head index. (v0: one descriptor per buffer, slot 0.)
export fn vq_add_buf(vq: *mut Virtq, addr: u64, len: u32, device_readable: bool) -> u16 {
    var flags: u16 = 0;
    if !device_readable {
        flags = VRING_DESC_F_WRITE;
    }
    vq.desc.d[0].addr = addr;
    vq.desc.d[0].len = len;
    vq.desc.d[0].flags = flags;
    vq.desc.d[0].next = 0;

    let cap: u16 = QUEUE_SIZE;
    let slot: usize = (vq.avail.idx % cap) as usize;
    vq.avail.ring[slot] = 0;
    wmb(); // descriptor + ring entry visible before the index bump
    vq.avail.idx = vq.avail.idx + 1;
    return 0;
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

// Advance the consumer cursor past one reaped used entry.
export fn vq_reap(vq: *mut Virtq) -> void {
    vq.last_used = vq.last_used + 1;
}

// Busy-wait (bounded) until the device reaps a buffer; true if it did.
export fn vq_wait_used(vq: *mut Virtq, max_spins: u32) -> bool {
    var spins: u32 = 0;
    while spins < max_spins {
        if vq_used_ready(vq) {
            vq_reap(vq);
            return true;
        }
        spins = spins + 1;
    }
    return false;
}
