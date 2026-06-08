// MC standard library — `virtqueue`: the virtio split virtqueue (§2.7).
//
// Owns the vring layout, queue setup, a descriptor **free list**, and the
// producer/consumer protocol, so a driver can have multiple buffers in flight on
// both the TX and RX paths. Buffers cross the queue as linear `move` DMA handles
// (std/dma): a buffer must be `clean_for_device`-d before it can be submitted,
// the CPU cannot touch it while in flight, and it is handed back (reconstructed
// from the in-flight record, with the device-written length) for the driver to
// reclaim. The cross-actor shared memory — the one part that isn't single-owner —
// is concentrated here behind that typed API.

import "virtio.mc";
import "barrier.mc";
import "dma.mc";
import "time.mc";

const QUEUE_SIZE: u16 = 8; // backing-array capacity (negotiated size is ≤ this)
const VRING_DESC_F_NEXT: u16 = 1;  // descriptor chains to `next`
const VRING_DESC_F_WRITE: u16 = 2; // buffer is device-writable (RX)

// Split-virtqueue structures laid out per the spec, in DMA memory.
struct VringDesc { addr: u64, len: u32, flags: u16, next: u16 }
struct DescTable { d: [8]VringDesc }
struct VringAvail { flags: u16, idx: u16, ring: [8]u16, used_event: u16 }
struct UsedElem { id: u32, len: u32 }
struct VringUsed { flags: u16, idx: u16, ring: [8]UsedElem, avail_event: u16 }

// A driver-side handle bundling the three vring regions, the negotiated size, a
// free-descriptor list, the used-ring cursor, and an in-flight record (the bus
// address each outstanding descriptor carries, so the buffer can be reconstructed
// when the device returns it).
struct Virtq {
    desc: *mut DescTable,
    avail: *mut VringAvail,
    used: *mut VringUsed,
    size: u16,
    free_head: u16,
    num_free: u16,
    last_used: u16,
    inflight_addr: [8]u64,
}

fn lo32(a: u64) -> u32 { return (a & 0x0000_0000_FFFF_FFFF) as u32; }
fn hi32(a: u64) -> u32 { return (a >> 32) as u32; }

// The device-visible (bus) address of a DMA buffer (no-IOMMU: the physical
// address). A generic helper so drivers don't open-code the cast.
export fn bus_addr(comptime T: type, p: *mut T) -> u64 {
    return p as usize as u64;
}

// ----- descriptor free list -----

// Chain every descriptor onto the free list (called by vq_setup).
fn vq_init_free(vq: *mut Virtq) -> void {
    var i: u16 = 0;
    while i < vq.size {
        vq.desc.d[i as usize].next = i + 1;
        i = i + 1;
    }
    vq.free_head = 0;
    vq.num_free = vq.size;
}

// How many descriptors are free (a producer checks this before submitting).
export fn vq_free_count(vq: *mut Virtq) -> u16 {
    return vq.num_free;
}

// Take a descriptor off the free list. Traps if none are free — callers gate on
// `vq_free_count`.
fn vq_alloc_desc(vq: *mut Virtq) -> u16 {
    if vq.num_free == 0 {
        unreachable; // queue full
    }
    let id: u16 = vq.free_head;
    vq.free_head = vq.desc.d[id as usize].next;
    vq.num_free = vq.num_free - 1;
    return id;
}

// Return a descriptor to the free list.
fn vq_free_desc(vq: *mut Virtq, id: u16) -> void {
    vq.desc.d[id as usize].next = vq.free_head;
    vq.free_head = id;
    vq.num_free = vq.num_free + 1;
}

// ----- queue setup -----

// Why a queue could not be set up.
enum VqError {
    QueueUnavailable, // the device reports queue_num_max == 0 for this queue
}

// Program the queue's three region addresses into the device, negotiate the size
// against `queue_num_max`, and initialize the free list. Returns `QueueUnavailable`
// if the device does not provide this queue.
export fn vq_setup(regs: MmioPtr<VirtioMmio>, q: u32, vq: *mut Virtq) -> Result<bool, VqError> {
    regs.queue_sel.write(q, .release);
    let max: u32 = regs.queue_num_max.read(.acquire);
    if max == 0 {
        return err(.QueueUnavailable);
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
    vq_init_free(vq);
    return ok(true);
}

// ----- submit / complete -----

// Submit one buffer: allocate a descriptor, record the buffer's address (so it
// can be reconstructed on completion), publish it in the available ring, and
// consume the device-owned handle. `device_writable` = the device writes it (RX);
// otherwise the device reads it (TX). Returns the descriptor id (the token).
fn vq_submit(vq: *mut Virtq, buf: DeviceBuffer, device_writable: bool) -> u16 {
    let id: u16 = vq_alloc_desc(vq);
    let addr: u64 = (device_addr(&buf) as usize) as u64; // bus addr → descriptor word
    let len: u32 = buf.len as u32;
    drop(buf); // the device now owns the buffer; we keep its address on record

    var flags: u16 = 0;
    if device_writable {
        flags = VRING_DESC_F_WRITE;
    }
    vq.inflight_addr[id as usize] = addr;
    vq.desc.d[id as usize].addr = addr;
    vq.desc.d[id as usize].len = len;
    vq.desc.d[id as usize].flags = flags;
    vq.desc.d[id as usize].next = 0;

    let slot: usize = (vq.avail.idx % vq.size) as usize;
    vq.avail.ring[slot] = id;
    wmb(); // descriptor + ring entry visible before the index bump
    vq.avail.idx = vq.avail.idx + 1;
    return id;
}

export fn vq_submit_tx(vq: *mut Virtq, buf: DeviceBuffer) -> u16 {
    return vq_submit(vq, buf, false);
}

export fn vq_submit_rx(vq: *mut Virtq, buf: DeviceBuffer) -> u16 {
    return vq_submit(vq, buf, true);
}

// Submit a three-descriptor chain (a virtio-blk request): `header` (device reads),
// `data` (device reads if `data_writable` is false, writes if true), and `status`
// (device writes). The descriptors are linked via F_NEXT; only the head is
// published in the available ring. Consumes the three device-owned buffers and
// returns the head descriptor id (the completion token).
export fn vq_submit_chain3(vq: *mut Virtq, header: DeviceBuffer, data: DeviceBuffer, status: DeviceBuffer, data_writable: bool) -> u16 {
    let id0: u16 = vq_alloc_desc(vq);
    let id1: u16 = vq_alloc_desc(vq);
    let id2: u16 = vq_alloc_desc(vq);

    let a0: u64 = (device_addr(&header) as usize) as u64;
    let l0: u32 = header.len as u32;
    let a1: u64 = (device_addr(&data) as usize) as u64;
    let l1: u32 = data.len as u32;
    let a2: u64 = (device_addr(&status) as usize) as u64;
    let l2: u32 = status.len as u32;
    drop(header);
    drop(data);
    drop(status);

    // header: device-read, chains to data.
    vq.desc.d[id0 as usize].addr = a0;
    vq.desc.d[id0 as usize].len = l0;
    vq.desc.d[id0 as usize].flags = VRING_DESC_F_NEXT;
    vq.desc.d[id0 as usize].next = id1;

    // data: device-read or device-write, chains to status.
    var data_flags: u16 = VRING_DESC_F_NEXT;
    if data_writable {
        data_flags = VRING_DESC_F_NEXT | VRING_DESC_F_WRITE;
    }
    vq.desc.d[id1 as usize].addr = a1;
    vq.desc.d[id1 as usize].len = l1;
    vq.desc.d[id1 as usize].flags = data_flags;
    vq.desc.d[id1 as usize].next = id2;

    // status: device-write, last in chain.
    vq.desc.d[id2 as usize].addr = a2;
    vq.desc.d[id2 as usize].len = l2;
    vq.desc.d[id2 as usize].flags = VRING_DESC_F_WRITE;
    vq.desc.d[id2 as usize].next = 0;

    vq.inflight_addr[id0 as usize] = a0; // track the head for bookkeeping

    let slot: usize = (vq.avail.idx % vq.size) as usize;
    vq.avail.ring[slot] = id0;
    wmb(); // descriptors + ring entry visible before the index bump
    vq.avail.idx = vq.avail.idx + 1;
    return id0;
}

// Free a descriptor chain starting at `head` (following F_NEXT). `next` is read
// before each descriptor is freed (freeing rewrites the `next` field).
fn vq_free_chain(vq: *mut Virtq, head: u16) -> void {
    var id: u16 = head;
    var more: bool = true;
    while more {
        let flags: u16 = vq.desc.d[id as usize].flags;
        let next: u16 = vq.desc.d[id as usize].next;
        vq_free_desc(vq, id);
        if (flags & VRING_DESC_F_NEXT) != 0 {
            id = next;
        } else {
            more = false;
        }
    }
}

// Reap one completed descriptor chain: read the used head, free the whole chain,
// and return the device-written length. Call only when `vq_has_used` is true.
export fn vq_complete_chain(vq: *mut Virtq) -> u32 {
    rmb();
    let slot: usize = (vq.last_used % vq.size) as usize;
    let head: u16 = vq.used.ring[slot].id as u16;
    let len: u32 = vq.used.ring[slot].len;
    vq.last_used = vq.last_used + 1;
    vq_free_chain(vq, head);
    return len;
}

// Notify the device that `q` has new buffers (§4.2.3.3): order then doorbell.
export fn vq_kick(regs: MmioPtr<VirtioMmio>, q: u32) -> void {
    wmb();
    regs.queue_notify.write(q, .release);
}

// Has the device returned a buffer on the used ring since we last reaped?
export fn vq_has_used(vq: *mut Virtq) -> bool {
    rmb();
    return vq.used.idx != vq.last_used;
}

// Block until the device returns a buffer on `vq`'s used ring, or `timeout` ticks
// elapse. Returns true if a completion is ready (the caller then reaps it with
// vq_complete / vq_complete_chain). Replaces the hand-rolled read_ticks/timed_out
// spin in each driver — the vq-specific form of `poll_until` (the probe needs the
// virtqueue, which a non-capturing fn pointer can't carry yet).
export fn vq_wait_used(vq: *mut Virtq, timeout: u64) -> bool {
    let start: Ticks = read_ticks();
    while !timed_out(start, read_ticks(), timeout) {
        if vq_has_used(vq) {
            return true;
        }
    }
    return false;
}

// The number of bytes the device wrote into the next completed buffer (the
// received length on RX). Call only when `vq_has_used` is true.
export fn vq_used_len(vq: *mut Virtq) -> u32 {
    rmb();
    let slot: usize = (vq.last_used % vq.size) as usize;
    return vq.used.ring[slot].len;
}

// Reap one completed buffer: read the used entry, free its descriptor, and hand
// back the device-owned buffer reconstructed from the in-flight record, with its
// length set to the bytes the device wrote. The driver then reclaims it
// (`invalidate_for_cpu`). Call only when `vq_has_used` is true.
export fn vq_complete(vq: *mut Virtq) -> DeviceBuffer {
    rmb();
    let slot: usize = (vq.last_used % vq.size) as usize;
    let id: u16 = vq.used.ring[slot].id as u16;
    let len: u32 = vq.used.ring[slot].len;
    vq.last_used = vq.last_used + 1;
    let addr: u64 = vq.inflight_addr[id as usize];
    vq_free_desc(vq, id);
    return .{ .dev_addr = (addr as usize) as DmaAddr, .len = len as usize };
}
