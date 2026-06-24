// kernel/drivers/virtio/virtio_blk_async — an INTERRUPT-DRIVEN virtio-blk read. The
// companion to virtio_blk.mc's `blk_read_sector`, which POLLS the used ring in a
// `vq_wait_used` loop. Here the request is submitted and the CPU sleeps; the device's
// used-ring interrupt (routed through the PLIC) reaps the completion and `async_complete`s
// the broker request id, so an `async fn` can `await` a real device IRQ — proving async is
// device-backed, not a timer demo.
//
// SPLIT of responsibilities (so the ISR stays `#[irq_context]`-clean):
//   - SUBMIT (blk_read_sector_async): reserve a broker slot, build the 3-descriptor chain
//     (header/data/status), record the head descriptor id ↔ broker id and the data buffer's
//     bus address in a small fixed table, kick the device, and return the broker id. The
//     future over that id is a plain ReqFut (kernel/lib/async_future.mc).
//   - COMPLETE (blk_irq_reap): called from the device IRQ. Reaps every used-ring entry
//     WITHOUT calling the buffer-reclaiming `vq_complete_chain` (which frees DMA buffers — not
//     IRQ-safe). It advances the used cursor, reads the sector's first word straight from the
//     recorded data buffer, translates the head descriptor id back to the broker id, returns the
//     three descriptors to the free list (`vq_free_chain3`, pure vq-field manipulation — IRQ-safe),
//     releases the request's buffer-pool slot, and `async_complete`s the broker id.
//
// WHY A FIXED BUFFER POOL (the resource-leak fix):
//   The DMA header/data/status buffers are allocated ONCE at `blk_async_init` — MAP_LEN identical
//   sets — and their owned handles are `forget_unchecked` into a fixed `BlkBufPool` that owns the
//   memory for the device's lifetime (bounded: MAP_LEN*(16+512+1) bytes, NOT a per-read leak).
//   Each `blk_read_sector_async` claims a free pool slot, writes the request header into that
//   slot's pooled header memory, re-mints `DeviceBuffer` views over the slot's stored bus
//   addresses, and submits them; it allocates and frees NOTHING per read. The ISR frees the three
//   descriptors (replenishing the free list so the queue never wedges QUEUE-FULL) and frees the
//   pool slot (so its buffers can back the next request). Because nothing is alloc/free-d per
//   read, there is no per-read leak; because the ISR only manipulates vq fields and pool flags
//   (never the DMA allocator), it stays `#[irq_context]`-safe. A slot is reused only after the
//   IRQ that completed its request marked it free, so a slot's buffers are never aliased by two
//   in-flight requests, and the descriptors are freed exactly once (the map entry is cleared
//   first, so a stale/duplicate completion finds no entry and frees nothing — no double-free).
//
// DESCRIPTOR ↔ BROKER-ID MAPPING (why a fixed table is sound):
//   The map is a small fixed array `BlkReqMap` of {present, desc_id, broker_id, data_addr}
//   entries, bounded by MAX_INFLIGHT. At submit we insert one entry; at IRQ we look up the
//   reaped head descriptor id and find its broker id. It is sound because:
//     (1) the head descriptor id is the virtio completion TOKEN — the device returns exactly
//         the id we submitted in `used.ring[].id`, and the virtqueue free-list guarantees a
//         submitted descriptor id is not reused until it is freed, so while a request is in
//         flight its head id uniquely identifies it;
//     (2) the table is keyed by that head id and an entry lives from submit to the IRQ that
//         reaps it, so the lookup is unambiguous;
//     (3) a stale/duplicate completion (an id we have no entry for) maps to nothing and is a
//         harmless no-op — exactly the same fail-safe the broker's `async_complete(unknown id)`
//         already gives.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/dma.mc";
import "std/addr.mc";
import "kernel/lib/async.mc";
import "kernel/core/process.mc";

const VIRTIO_BLK_DEVICE_ID: u32 = 2;
const VIRTIO_BLK_T_IN: u32 = 0; // read from disk into memory
const SECTOR_SIZE: usize = 512;
const BLK_HDR_SIZE: usize = 16;
const MAP_LEN: usize = 8; // bounded by MAX_INFLIGHT
const VRING_QSIZE: u16 = 8;

// virtio-mmio interrupt_status bit 0 = the used ring was updated (a buffer completed).
const VIRTIO_INT_USED: u32 = 0x1;

// One submit-time record tying a virtio head descriptor id to a broker request id (and the
// bus address of that request's data buffer, so the ISR can read the sector result without
// reconstructing the owned DMA handle).
struct BlkReqMapEntry {
    present: bool,
    desc_id: u16,
    pool_slot: usize, // the BlkBufPool slot backing this request (freed by the IRQ)
    broker_id: u64,
    data_addr: u64,
}

struct BlkReqMap {
    e: [MAP_LEN]BlkReqMapEntry,
}

export fn blk_map_init(m: *mut BlkReqMap) -> void {
    var i: usize = 0;
    while i < MAP_LEN {
        m.e[i].present = false;
        m.e[i].desc_id = 0;
        m.e[i].pool_slot = 0;
        m.e[i].broker_id = 0;
        m.e[i].data_addr = 0;
        i = i + 1;
    }
}

// Insert a submit-time record. Returns false if the table is full (the caller then cancels
// the reserved broker slot and fails the submit).
fn blk_map_insert(m: *mut BlkReqMap, desc_id: u16, pool_slot: usize, broker_id: u64, data_addr: u64) -> bool {
    var i: usize = 0;
    while i < MAP_LEN {
        if !m.e[i].present {
            m.e[i].present = true;
            m.e[i].desc_id = desc_id;
            m.e[i].pool_slot = pool_slot;
            m.e[i].broker_id = broker_id;
            m.e[i].data_addr = data_addr;
            return true;
        }
        i = i + 1;
    }
    return false;
}

// ----- fixed per-request DMA buffer pool -----
//
// MAP_LEN sets of {header, data, status}, allocated ONCE at init and owned by the pool for the
// device's lifetime. A slot stores each buffer's device (bus) address — and the header's CPU
// address, so the submit path can write the request header into the pooled memory by re-minting
// a CpuBuffer view over it. `free[i]` gates reuse: a slot is claimed at submit and released by
// the IRQ that completes its request, so an in-flight request's buffers are never aliased.
struct BlkBufSlot {
    hdr_dev: u64,
    hdr_cpu: usize,
    data_dev: u64,
    status_dev: u64,
    free: bool,
}

struct BlkBufPool {
    s: [MAP_LEN]BlkBufSlot,
}

// Allocate every slot's three buffers ONCE and hand their memory to the pool. The owned
// CpuBuffers are `forget_unchecked` after their addresses are recorded: the pool now owns the
// memory for the device's lifetime (a bounded one-time reservation, not a per-read leak), which
// is exactly why the per-read path never has to alloc/free and the IRQ never has to call the
// (non-irq-safe) DMA allocator.
fn blk_pool_init(p: *mut BlkBufPool) -> void {
    var i: usize = 0;
    while i < MAP_LEN {
        var hdr: CpuBuffer = alloc(BLK_HDR_SIZE);
        var data: CpuBuffer = alloc(SECTOR_SIZE);
        var status: CpuBuffer = alloc(1);
        p.s[i].hdr_dev = (device_addr_of_cpu(&hdr) as usize) as u64;
        p.s[i].hdr_cpu = pa_value(cpu_addr(&hdr));
        p.s[i].data_dev = (device_addr_of_cpu(&data) as usize) as u64;
        p.s[i].status_dev = (device_addr_of_cpu(&status) as usize) as u64;
        p.s[i].free = true;
        // The pool keeps these bytes alive for the device's lifetime; drop the owned handles
        // (their addresses are recorded above) so the move-checker does not require a free.
        unsafe { forget_unchecked(hdr); }
        unsafe { forget_unchecked(data); }
        unsafe { forget_unchecked(status); }
        i = i + 1;
    }
}

// The device (bus) address of a still-cpu-owned buffer. On the no-IOMMU model the bus address is
// recorded in `dev_addr` from `alloc`, so this is the same address `clean_for_device` would later
// expose via `device_addr` — captured here so we can record it before forgetting the handle.
fn device_addr_of_cpu(b: *CpuBuffer) -> DmaAddr {
    return b.dev_addr;
}

// Claim a free pool slot, returning its index, or MAP_LEN if none is free (back-pressure).
fn blk_pool_claim(p: *mut BlkBufPool) -> usize {
    var i: usize = 0;
    while i < MAP_LEN {
        if p.s[i].free {
            p.s[i].free = false;
            return i;
        }
        i = i + 1;
    }
    return MAP_LEN;
}

// Release a pool slot back for reuse. Pure field write — IRQ-safe.
#[irq_context]
fn blk_pool_release(p: *mut BlkBufPool, slot: usize) -> void {
    if slot < MAP_LEN {
        p.s[slot].free = true;
    }
}

// The handle the device IRQ needs: the queue to reap, the map to translate ids, the broker to
// complete, and the process table to wake the parked awaiter. A single global of this type is
// shared between the submit path and the ISR (the ISR reads it through `blk_irq_reap`).
struct BlkAsyncDev {
    regs: MmioPtr<VirtioMmio>,
    vq: *mut Virtq,
    map: *mut BlkReqMap,
    pool: *mut BlkBufPool,
    broker: *mut AsyncBroker,
    procs: *mut ProcTable,
}

// Bring the block device up (handshake + queue setup), initialize the id map, and reserve the
// fixed per-request DMA buffer pool (allocated once here for the device's lifetime).
export fn blk_async_init(dev: *mut BlkAsyncDev) -> Result<bool, bool> {
    blk_map_init(dev.map);
    blk_pool_init(dev.pool);
    switch virtio_init(dev.regs, VIRTIO_BLK_DEVICE_ID, 0, 0) {
        ok(up) => {}
        err(e) => { return err(false); }
    }
    switch vq_setup(dev.regs, 0, dev.vq) {
        ok(up) => {}
        err(e) => { return err(false); }
    }
    virtio_driver_ok(dev.regs);
    return ok(true);
}

// Submit an ASYNC read of `sector`: reserve a broker slot, build + kick the 3-descriptor
// request chain, record desc-id ↔ broker-id, and return the broker id (or ASYNC_NO_ID on a
// full broker / submit failure, releasing the reserved slot). The completion arrives later via
// the device IRQ (blk_irq_reap), which `async_complete`s this id with the sector's first word.
export fn blk_read_sector_async(dev: *mut BlkAsyncDev, sector: u64) -> u64 {
    let id: u64 = async_submit(dev.broker);
    if id == ASYNC_NO_ID {
        return ASYNC_NO_ID; // broker full — back-pressure
    }

    // Claim a free pool slot. (Bounded by MAP_LEN, which matches both the broker depth and the
    // descriptor budget — VRING_QSIZE/3 — so a free broker slot generally implies a free pool
    // slot; fail closed and release the broker slot if not.)
    let slot: usize = blk_pool_claim(dev.pool);
    if slot >= MAP_LEN {
        let _c: bool = async_cancel_slot(dev.broker, id);
        return ASYNC_NO_ID;
    }

    // Write the request header into this slot's POOLED header memory by re-minting a CpuBuffer view
    // over its stored CPU/bus addresses (the pool owns the memory; we only borrow it to write).
    let hdr_view: CpuBuffer = blk_slot_hdr_view(&dev.pool.s[slot]);
    write_le32(&hdr_view, 0, VIRTIO_BLK_T_IN);
    write_le32(&hdr_view, 4, 0);
    write_le64(&hdr_view, 8, sector);
    // clean_for_device flushes the header to the device and consumes the borrowed view (identity
    // on coherent memory); we discard the produced DeviceBuffer and re-mint our own views below,
    // since the pool — not this transient handle — owns the lifetime.
    let _flushed: DeviceBuffer = clean_for_device(hdr_view);
    unsafe { forget_unchecked(_flushed); }

    // Re-mint device-buffer views over the slot's three stored bus addresses to submit. These are
    // VIEWS, not owned handles: the pool keeps the memory alive, so `vq_submit_chain3` consuming
    // them (it `forget_unchecked`s on success, or reclaims on error — see below) does not free
    // pool memory.
    let hdr_d: DeviceBuffer = blk_view(dev.pool.s[slot].hdr_dev, BLK_HDR_SIZE);
    let data_d: DeviceBuffer = blk_view(dev.pool.s[slot].data_dev, SECTOR_SIZE);
    let status_d: DeviceBuffer = blk_view(dev.pool.s[slot].status_dev, 1);

    let data_addr: u64 = dev.pool.s[slot].data_dev;

    var head: u16 = 0;
    switch vq_submit_chain3(dev.vq, hdr_d, data_d, status_d, true) {
        ok(h) => { head = h; }
        err(e) => {
            // On error vq_submit_chain3 ran invalidate_for_cpu+free on the three views. On the
            // coherent no-IOMMU model `free` is a no-op (the pool memory is untouched), so the
            // slot is still valid — just release it and the broker slot and fail closed.
            blk_pool_release(dev.pool, slot);
            let _c: bool = async_cancel_slot(dev.broker, id);
            return ASYNC_NO_ID;
        }
    }

    if !blk_map_insert(dev.map, head, slot, id, data_addr) {
        // Map full (cannot happen while in-flight ≤ MAP_LEN, but fail closed): the chain is already
        // queued. Cancel the broker slot so the id is unknown; the IRQ will still reap the head,
        // find no map entry, free the descriptors, but NOT the pool slot — so release it here.
        blk_pool_release(dev.pool, slot);
        let _c: bool = async_cancel_slot(dev.broker, id);
        return ASYNC_NO_ID;
    }

    vq_kick(dev.regs, 0);
    return id;
}

// Re-mint a CpuBuffer VIEW over a pool slot's pooled header memory so the submit path can write
// the request header into it. The pool owns the underlying bytes; this is a borrow used only
// transiently (written, then consumed by clean_for_device which is identity on coherent memory).
fn blk_slot_hdr_view(s: *BlkBufSlot) -> CpuBuffer {
    var dev: DmaAddr = uninit;
    unsafe { dev = (s.hdr_dev as usize) as DmaAddr; }
    return .{ .dev_addr = dev, .cpu_addr = pa(s.hdr_cpu), .len = BLK_HDR_SIZE };
}

// Re-mint a DeviceBuffer VIEW over a pooled bus address of the given length (audited DMA boundary).
fn blk_view(dev_addr: u64, len: usize) -> DeviceBuffer {
    var dev: DmaAddr = uninit;
    unsafe { dev = (dev_addr as usize) as DmaAddr; }
    return .{ .dev_addr = dev, .len = len };
}

// ---- IRQ side --------------------------------------------------------------------------------
//
// Everything below runs in INTERRUPT context and is `#[irq_context]`-verified: only field
// reads/writes, a `raw.load`, and calls to already-irq_context-annotated callees (async_complete,
// vq_free_chain3, blk_pool_release). It deliberately does NOT call `vq_complete_chain` (which
// reconstructs and could free DMA buffers); it returns the three descriptors to the free list with
// the pure-field-manipulation `vq_free_chain3` and releases the pool slot — no DMA-allocator call,
// so no per-read leak and no non-irq-safe call.

// Translate a reaped head descriptor id back to its broker id and pool slot, clearing the map
// entry. Returns ASYNC_NO_ID (and leaves `*out_slot` = MAP_LEN) for an id we have no record of
// (a stale/duplicate completion — a safe no-op). Clearing `present` first makes a duplicate
// completion for the same head find nothing, so the descriptors/slot are freed exactly once.
#[irq_context]
fn blk_map_take(m: *mut BlkReqMap, desc_id: u16, out_slot: *mut usize) -> u64 {
    var i: usize = 0;
    while i < MAP_LEN {
        if m.e[i].present && m.e[i].desc_id == desc_id {
            let id: u64 = m.e[i].broker_id;
            out_slot.* = m.e[i].pool_slot;
            m.e[i].present = false;
            return id;
        }
        i = i + 1;
    }
    out_slot.* = MAP_LEN;
    return ASYNC_NO_ID;
}

// The data buffer bus address recorded for a head descriptor id (0 if unknown).
#[irq_context]
fn blk_map_data_addr(m: *mut BlkReqMap, desc_id: u16) -> u64 {
    var i: usize = 0;
    while i < MAP_LEN {
        if m.e[i].present && m.e[i].desc_id == desc_id {
            return m.e[i].data_addr;
        }
        i = i + 1;
    }
    return 0;
}

// Reap one used-ring entry by hand: read the head id at the consumer cursor, advance the cursor.
// Returns the head descriptor id, or 0xFFFF if the id is out of range (a misbehaving device — we
// still advance to avoid wedging the ISR). Call only when `vq.used.idx != vq.last_used`.
#[irq_context]
fn blk_reap_one_head(vq: *mut Virtq) -> u16 {
    let slot: usize = (vq.last_used % VRING_QSIZE) as usize;
    let raw_id: u32 = vq.used.ring[slot].id;
    vq.last_used = vq.last_used + 1; // advance consumer cursor (queue depth 1, no 2^16 wrap risk)
    if raw_id >= VRING_QSIZE as u32 {
        return 0xFFFF;
    }
    return raw_id as u16;
}

// THE DEVICE IRQ HANDLER. Called from the trap dispatcher when the virtio-blk used-ring
// interrupt fires (after the PLIC source is claimed by the caller). It: reads interrupt_status,
// loops while the used ring has new entries reaping each, translates the head id → broker id,
// reads the completed sector's first little-endian word straight from the data buffer, and
// `async_complete`s the broker id with it (waking the parked awaiter). Then it ACKs the device
// interrupt. Returns how many completions it reaped (0 if this was not a used-ring interrupt) so
// the caller can trace it. `#[irq_context]`: no heap, no blocking, no buffer frees — only the
// annotated broker calls plus field/MMIO loads.
#[irq_context]
export fn blk_irq_reap(dev: *mut BlkAsyncDev) -> u32 {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let st: u32 = regs.interrupt_status.read(.acquire);
    var reaped: u32 = 0;
    if (st & VIRTIO_INT_USED) != 0 {
        let vq: *mut Virtq = dev.vq;
        // Bounded by the queue depth (VRING_QSIZE): at most that many buffers can be in flight, so
        // at most that many used entries can be pending — a hard bound for the irq_context verifier.
        var guard: usize = 0;
        while guard < VRING_QSIZE as usize {
            if vq.used.idx == vq.last_used {
                break;
            }
            guard = guard + 1;
            let head: u16 = blk_reap_one_head(vq);
            if head != 0xFFFF {
                let addr: u64 = blk_map_data_addr(dev.map, head);
                var word: i32 = 0;
                if addr != 0 {
                    unsafe { word = raw.load<i32>(phys(addr as usize)); }
                }
                var slot: usize = MAP_LEN;
                let bid: u64 = blk_map_take(dev.map, head, &slot);
                if bid != ASYNC_NO_ID {
                    // The map entry was present (and is now cleared), so this head is a real
                    // in-flight chain we have not freed yet: return its three descriptors to the
                    // free list (replenishing the queue) and release the buffer-pool slot, then
                    // wake the awaiter. Doing this only on a present entry means a stale/duplicate
                    // completion frees nothing — no double-free of descriptors or pool slot.
                    vq_free_chain3(vq, head);
                    blk_pool_release(dev.pool, slot);
                    let _ok: bool = async_complete(dev.broker, dev.procs, bid, word);
                }
            }
            reaped = reaped + 1;
        }
    }
    // ACK the bits we handled so the device de-asserts its interrupt line.
    regs.interrupt_ack.write(st, .release);
    return reaped;
}
