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
//     IRQ-safe). It only advances the used cursor, reads the sector's first word straight from
//     the recorded data buffer, translates the head descriptor id back to the broker id, and
//     `async_complete`s it. Buffer reclaim is deferred to the awaiter after the await returns.
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
        m.e[i].broker_id = 0;
        m.e[i].data_addr = 0;
        i = i + 1;
    }
}

// Insert a submit-time record. Returns false if the table is full (the caller then cancels
// the reserved broker slot and fails the submit).
fn blk_map_insert(m: *mut BlkReqMap, desc_id: u16, broker_id: u64, data_addr: u64) -> bool {
    var i: usize = 0;
    while i < MAP_LEN {
        if !m.e[i].present {
            m.e[i].present = true;
            m.e[i].desc_id = desc_id;
            m.e[i].broker_id = broker_id;
            m.e[i].data_addr = data_addr;
            return true;
        }
        i = i + 1;
    }
    return false;
}

// The handle the device IRQ needs: the queue to reap, the map to translate ids, the broker to
// complete, and the process table to wake the parked awaiter. A single global of this type is
// shared between the submit path and the ISR (the ISR reads it through `blk_irq_reap`).
struct BlkAsyncDev {
    regs: MmioPtr<VirtioMmio>,
    vq: *mut Virtq,
    map: *mut BlkReqMap,
    broker: *mut AsyncBroker,
    procs: *mut ProcTable,
}

// Bring the block device up (handshake + queue setup) and initialize the id map.
export fn blk_async_init(dev: *mut BlkAsyncDev) -> Result<bool, bool> {
    blk_map_init(dev.map);
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

    var hdr: CpuBuffer = alloc(BLK_HDR_SIZE);
    write_le32(&hdr, 0, VIRTIO_BLK_T_IN);
    write_le32(&hdr, 4, 0);
    write_le64(&hdr, 8, sector);

    var data: CpuBuffer = alloc(SECTOR_SIZE);
    var status: CpuBuffer = alloc(1);

    let hdr_d: DeviceBuffer = clean_for_device(hdr);
    let data_d: DeviceBuffer = clean_for_device(data);
    let status_d: DeviceBuffer = clean_for_device(status);

    // Capture the data buffer's bus address before it is consumed by the submit, so the ISR can
    // read the completed sector's first word directly (the device wrote it there).
    let data_addr: u64 = (device_addr(&data_d) as usize) as u64;

    var head: u16 = 0;
    switch vq_submit_chain3(dev.vq, hdr_d, data_d, status_d, true) {
        ok(h) => { head = h; }
        err(e) => {
            // Buffers were reclaimed inside vq_submit_chain3; release the reserved broker slot.
            let _c: bool = async_cancel_slot(dev.broker, id);
            return ASYNC_NO_ID;
        }
    }

    if !blk_map_insert(dev.map, head, id, data_addr) {
        // Map full (cannot happen while in-flight ≤ MAX_INFLIGHT, but fail closed): the chain is
        // already queued; cancel the broker slot so the id is unknown and the later IRQ no-ops.
        let _c: bool = async_cancel_slot(dev.broker, id);
        return ASYNC_NO_ID;
    }

    vq_kick(dev.regs, 0);
    return id;
}

// ---- IRQ side --------------------------------------------------------------------------------
//
// Everything below runs in INTERRUPT context and is `#[irq_context]`-verified: only field
// reads/writes, a `raw.load`, and calls to already-irq_context-annotated callees
// (async_complete). It deliberately does NOT call `vq_complete_chain` / `vq_free_desc` (which
// free DMA buffers); the used cursor is advanced by hand and buffer reclaim is left to the
// awaiter after `await` returns.

// Translate a reaped head descriptor id back to its broker id, clearing the map entry. Returns
// ASYNC_NO_ID for an id we have no record of (a stale/duplicate completion — a safe no-op).
#[irq_context]
fn blk_map_take(m: *mut BlkReqMap, desc_id: u16) -> u64 {
    var i: usize = 0;
    while i < MAP_LEN {
        if m.e[i].present && m.e[i].desc_id == desc_id {
            let id: u64 = m.e[i].broker_id;
            m.e[i].present = false;
            return id;
        }
        i = i + 1;
    }
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
                let bid: u64 = blk_map_take(dev.map, head);
                if bid != ASYNC_NO_ID {
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
