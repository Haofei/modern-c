// kernel/drivers/virtio/virtio_net_async — an INTERRUPT-DRIVEN virtio-net TX/RX. The companion to
// virtio_net.mc's `nic_tx_frame`, which POLLS the TX used ring in a `tx_wait_reclaim` loop. Here a
// frame send or one-shot receive is submitted and the CPU sleeps; the device's used-ring interrupt
// (routed through the PLIC) reaps the completion and `async_complete`s the broker request id, so an
// async poll/await can resolve from a real network device IRQ — proving async is device-backed for
// the NIC, not a poll loop.
//
// This is the virtio-net analogue of virtio_blk_async.mc and reuses its exact shape: a fixed DMA
// buffer pool (no per-send alloc/free — the leak fix), a desc-id ↔ broker-id map, an irq_context
// reaper that only manipulates vq fields + broker calls, and an explicit capacity contract.
//
// RX follows the same structure on queue 0 with a device-WRITE buffer. A caller submits a receive
// request with a destination buffer; the IRQ copies the delivered Ethernet frame (past the 12-byte
// virtio_net_hdr) into that destination and completes the broker id with the copied byte count.
//
// CAPACITY CONTRACT (NET_ASYNC_MAX, the honest in-flight ceiling for TX):
//   A TX frame is NET_DESC_PER_FRAME = 1 descriptor. The TX queue has VRING_QSIZE = 8 descriptors,
//   so the TX backend can have at most VRING_QSIZE / NET_DESC_PER_FRAME = 8 sends in flight AT THE
//   DEVICE — NET_ASYNC_MAX. This per-backend cap is DISTINCT from the broker's MAX_INFLIGHT (8, the
//   GLOBAL cap shared across every async kind). A send consumes one broker slot AND one TX pool slot,
//   so TX async concurrency is min(8, 8) = 8. MAP_LEN sizes the id-map and the DMA buffer pool to
//   exactly NET_ASYNC_MAX, so the pool-claim is the honest back-pressure point: a claimed slot always
//   has its 1 descriptor available (NET_ASYNC_MAX * NET_DESC_PER_FRAME = 8 <= VRING_QSIZE = 8).
//
// WHY A FIXED BUFFER POOL (the resource-leak fix, identical to virtio_blk_async):
//   The TX DMA buffers are allocated ONCE at `net_async_init` — MAP_LEN identical frame buffers —
//   and their owned handles are `forget_unchecked` into a fixed `NetBufPool` that owns the memory
//   for the device's lifetime (bounded MAP_LEN*FRAME_BUF_LEN, NOT a per-send leak). Each
//   `net_send_frame_async` claims a free slot, copies the caller's frame into that slot's pooled
//   memory, re-mints a DeviceBuffer view over its stored bus address, and submits it; it allocates
//   and frees NOTHING per send. The ISR frees the single descriptor (replenishing the free list so
//   the queue never wedges QUEUE-FULL) and frees the pool slot — no DMA-allocator call in the ISR,
//   so it stays `#[irq_context]`-safe and there is no per-send leak. A slot is reused only after the
//   IRQ that completed its send marked it free, so two in-flight sends never alias a slot, and the
//   descriptor is freed exactly once (the map entry is cleared first, so a stale/duplicate
//   completion finds no entry and frees nothing — no double-free).

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/alloc/dma.mc";
import "std/addr.mc";
import "kernel/lib/async.mc";
import "kernel/core/process.mc";

const VIRTIO_NET_DEVICE_ID: u32 = 1;
const VIRTIO_NET_F_VERSION_1_HI: u32 = 1; // feature bit 32 → high-word bit 0 (virtio 1.x)
const RX_QUEUE: u32 = 0; // virtio-net: queue 0 = rx, queue 1 = tx
const TX_QUEUE: u32 = 1;

const VRING_QSIZE: u16 = 8;

// A TX frame: the 12-byte virtio_net_hdr precedes the Ethernet frame in one linear buffer.
const NET_HDR_LEN: usize = 12;
const FRAME_AT: usize = 12;
const FRAME_BUF_LEN: usize = 2048; // generous: virtio_net_hdr + a full Ethernet frame

// CAPACITY CONTRACT — see the file header. A TX frame is one descriptor.
const NET_DESC_PER_FRAME: usize = 1;
const NET_ASYNC_MAX: usize = (VRING_QSIZE as usize) / NET_DESC_PER_FRAME; // = 8
const MAP_LEN: usize = NET_ASYNC_MAX;

// virtio-mmio interrupt_status bit 0 = the used ring was updated (a buffer completed).
const VIRTIO_INT_USED: u32 = 0x1;

// One submit-time record tying a virtio head descriptor id to a broker request id (and the pool
// slot backing the request, freed by the IRQ).
struct NetReqMapEntry {
    present: bool,
    desc_id: u16,
    pool_slot: usize,
    broker_id: u64,
    dst: usize,
    max: usize,
}

struct NetReqMap {
    e: [MAP_LEN]NetReqMapEntry,
}

export fn net_map_init(m: *mut NetReqMap) -> void {
    var i: usize = 0;
    while i < MAP_LEN {
        m.e[i].present = false;
        m.e[i].desc_id = 0;
        m.e[i].pool_slot = 0;
        m.e[i].broker_id = 0;
        m.e[i].dst = 0;
        m.e[i].max = 0;
        i = i + 1;
    }
}

// Insert a submit-time record. Returns false if the table is full (the caller then cancels the
// reserved broker slot and fails the submit).
fn net_map_insert(m: *mut NetReqMap, desc_id: u16, pool_slot: usize, broker_id: u64, dst: usize, max: usize) -> bool {
    var i: usize = 0;
    while i < MAP_LEN {
        if !m.e[i].present {
            m.e[i].present = true;
            m.e[i].desc_id = desc_id;
            m.e[i].pool_slot = pool_slot;
            m.e[i].broker_id = broker_id;
            m.e[i].dst = dst;
            m.e[i].max = max;
            return true;
        }
        i = i + 1;
    }
    return false;
}

// ----- fixed per-send DMA buffer pool -----
//
// MAP_LEN frame buffers, allocated ONCE at init and owned by the pool for the device's lifetime. A
// slot stores its buffer's device (bus) address — and the CPU address, so the submit path can copy
// the caller's frame into the pooled memory by re-minting a CpuBuffer view over it. `free[i]` gates
// reuse: a slot is claimed at submit and released by the IRQ that completes its send.
struct NetBufSlot {
    buf_dev: u64,
    buf_cpu: usize,
    free: bool,
}

struct NetBufPool {
    s: [MAP_LEN]NetBufSlot,
}

// Allocate every slot's frame buffer ONCE and hand its memory to the pool. The owned CpuBuffers are
// `forget_unchecked` after their addresses are recorded: the pool now owns the memory for the
// device's lifetime (a bounded one-time reservation, not a per-send leak), which is exactly why the
// per-send path never has to alloc/free and the IRQ never calls the (non-irq-safe) DMA allocator.
fn net_pool_init(p: *mut NetBufPool) -> void {
    var i: usize = 0;
    while i < MAP_LEN {
        var buf: CpuBuffer = alloc(FRAME_BUF_LEN);
        p.s[i].buf_dev = (device_addr_of_cpu(&buf) as usize) as u64;
        p.s[i].buf_cpu = pa_value(cpu_addr(&buf));
        p.s[i].free = true;
        unsafe { forget_unchecked(buf); }
        i = i + 1;
    }
}

// The device (bus) address of a still-cpu-owned buffer (no-IOMMU: recorded in `dev_addr` at alloc).
fn device_addr_of_cpu(b: *CpuBuffer) -> DmaAddr {
    return b.dev_addr;
}

// Claim a free pool slot, returning its index, or MAP_LEN if none is free (back-pressure).
fn net_pool_claim(p: *mut NetBufPool) -> usize {
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
fn net_pool_release(p: *mut NetBufPool, slot: usize) -> void {
    if slot < MAP_LEN {
        p.s[slot].free = true;
    }
}

// Re-mint a CpuBuffer VIEW over a pool slot's pooled frame memory so the submit path can copy the
// caller's frame into it. The pool owns the underlying bytes; this is a borrow used transiently
// (written, then consumed by clean_for_device which is identity on coherent memory).
fn net_slot_view(s: *NetBufSlot, len: usize) -> CpuBuffer {
    var dev: DmaAddr = uninit;
    unsafe { dev = (s.buf_dev as usize) as DmaAddr; }
    return .{ .dev_addr = dev, .cpu_addr = pa(s.buf_cpu), .len = len };
}

// Re-mint a DeviceBuffer VIEW over a pooled bus address of the given length (audited DMA boundary).
fn net_view(dev_addr: u64, len: usize) -> DeviceBuffer {
    var dev: DmaAddr = uninit;
    unsafe { dev = (dev_addr as usize) as DmaAddr; }
    return .{ .dev_addr = dev, .len = len };
}

// The handle the device IRQ needs: the TX queue to reap, the map to translate ids, the broker to
// complete, and the process table to wake the parked awaiter. A single global of this type is shared
// between the submit path and the ISR (the ISR reads it through `net_irq_reap`).
struct NetAsyncDev {
    regs: MmioPtr<VirtioMmio>,
    rxq: *mut Virtq,
    txq: *mut Virtq,
    tx_map: *mut NetReqMap,
    tx_pool: *mut NetBufPool,
    rx_map: *mut NetReqMap,
    rx_pool: *mut NetBufPool,
    broker: *mut AsyncBroker,
    procs: *mut ProcTable,
}

// Bring the NIC up (handshake + RX/TX queue setup), initialize the id map, and reserve the fixed
// per-send DMA buffer pool (allocated once here for the device's lifetime). Both queues are set up
// (virtio requires every queue a device exposes to be configured before DRIVER_OK) but only the TX
// queue is driven async here.
export fn net_async_init(dev: *mut NetAsyncDev) -> Result<bool, bool> {
    net_map_init(dev.tx_map);
    net_map_init(dev.rx_map);
    net_pool_init(dev.tx_pool);
    net_pool_init(dev.rx_pool);
    switch virtio_init(dev.regs, VIRTIO_NET_DEVICE_ID, 0, VIRTIO_NET_F_VERSION_1_HI) {
        ok(up) => {}
        err(e) => { return err(false); }
    }
    switch vq_setup(dev.regs, RX_QUEUE, dev.rxq) {
        ok(up) => {}
        err(e) => { return err(false); }
    }
    switch vq_setup(dev.regs, TX_QUEUE, dev.txq) {
        ok(up) => {}
        err(e) => { return err(false); }
    }
    virtio_driver_ok(dev.regs);
    return ok(true);
}

// Submit an ASYNC send of the `frame_len`-byte frame at `frame_ptr` (a complete virtio TX buffer:
// the 12-byte virtio_net_hdr at offset 0 followed by the Ethernet frame at FRAME_AT). Reserve a
// broker slot, claim a pool slot, copy the frame into the pooled buffer, submit the single TX
// descriptor, record desc-id ↔ broker-id, kick the device, and return the broker id (or ASYNC_NO_ID
// on back-pressure / submit failure, releasing what it reserved). The completion arrives later via
// the TX used-ring IRQ (net_irq_reap), which `async_complete`s this id with NET_TX_DONE.
export fn net_send_frame_async(dev: *mut NetAsyncDev, frame_ptr: usize, frame_len: usize) -> u64 {
    let id: u64 = async_submit(dev.broker);
    if id == ASYNC_NO_ID {
        return ASYNC_NO_ID; // broker full — back-pressure
    }

    // Claim a free pool slot. MAP_LEN == NET_ASYNC_MAX, the descriptor-bound capacity, so this is the
    // HONEST back-pressure point: when all slots are taken, all 8 descriptors are in use and a
    // further send genuinely cannot be queued. Fail closed: release the broker slot and report
    // back-pressure.
    let slot: usize = net_pool_claim(dev.tx_pool);
    if slot >= MAP_LEN {
        let _c: bool = async_cancel_slot(dev.broker, id);
        return ASYNC_NO_ID;
    }

    // Clamp the copy length to the pooled buffer (defensive; callers pass small frames).
    var n: usize = frame_len;
    if n > FRAME_BUF_LEN {
        n = FRAME_BUF_LEN;
    }

    // Copy the caller's frame into this slot's POOLED memory by re-minting a CpuBuffer view over its
    // stored CPU/bus addresses (the pool owns the memory; we only borrow it to write).
    let view: CpuBuffer = net_slot_view(&dev.tx_pool.s[slot], n);
    var i: usize = 0;
    while i < n {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(frame_ptr + i)); }
        write_u8(&view, i, b);
        i = i + 1;
    }
    // Flush the frame to the device and consume the borrowed view (identity on coherent memory); we
    // discard the produced DeviceBuffer and re-mint our own view below, since the pool — not this
    // transient handle — owns the lifetime.
    let _flushed: DeviceBuffer = clean_for_device(view);
    unsafe { forget_unchecked(_flushed); }

    // Re-mint a device-buffer VIEW over the slot's stored bus address to submit. It is a VIEW, not an
    // owned handle: the pool keeps the memory alive, so vq_submit_tx consuming it (forget on success,
    // reclaim-as-no-op on error) does not free pool memory.
    let txbuf: DeviceBuffer = net_view(dev.tx_pool.s[slot].buf_dev, n);

    var head: u16 = 0;
    switch vq_submit_tx(dev.txq, txbuf) {
        ok(h) => { head = h; }
        err(e) => {
            // On error vq_submit_tx ran invalidate_for_cpu+free on the view; on the coherent
            // no-IOMMU model `free` is a no-op (pool memory untouched), so the slot is still valid —
            // release it and the broker slot and fail closed.
            net_pool_release(dev.tx_pool, slot);
            let _c: bool = async_cancel_slot(dev.broker, id);
            return ASYNC_NO_ID;
        }
    }

    if !net_map_insert(dev.tx_map, head, slot, id, 0, 0) {
        // Map full (cannot happen while in-flight ≤ MAP_LEN, but fail closed): the frame is already
        // queued. Cancel the broker slot so the id is unknown; the IRQ will reap the head, find no
        // map entry, free the descriptor, but NOT the pool slot — so release it here.
        net_pool_release(dev.tx_pool, slot);
        let _c: bool = async_cancel_slot(dev.broker, id);
        return ASYNC_NO_ID;
    }

    vq_kick(dev.regs, TX_QUEUE);
    return id;
}

// Submit a one-shot ASYNC receive. The device writes into a pooled RX DMA buffer; when an RX used
// entry arrives, the IRQ copies the Ethernet frame (excluding the virtio_net_hdr) into `dst`, caps
// it at `max`, and completes this id with the copied byte count.
export fn net_recv_frame_async(dev: *mut NetAsyncDev, dst: usize, max: usize) -> u64 {
    let id: u64 = async_submit(dev.broker);
    if id == ASYNC_NO_ID {
        return ASYNC_NO_ID;
    }

    let slot: usize = net_pool_claim(dev.rx_pool);
    if slot >= MAP_LEN {
        let _c: bool = async_cancel_slot(dev.broker, id);
        return ASYNC_NO_ID;
    }

    let rxbuf: DeviceBuffer = net_view(dev.rx_pool.s[slot].buf_dev, FRAME_BUF_LEN);
    var head: u16 = 0;
    switch vq_submit_rx(dev.rxq, rxbuf) {
        ok(h) => { head = h; }
        err(e) => {
            net_pool_release(dev.rx_pool, slot);
            let _c: bool = async_cancel_slot(dev.broker, id);
            return ASYNC_NO_ID;
        }
    }

    if !net_map_insert(dev.rx_map, head, slot, id, dst, max) {
        net_pool_release(dev.rx_pool, slot);
        let _c: bool = async_cancel_slot(dev.broker, id);
        return ASYNC_NO_ID;
    }

    vq_kick(dev.regs, RX_QUEUE);
    return id;
}

// ---- IRQ side --------------------------------------------------------------------------------
//
// Everything below runs in INTERRUPT context and is `#[irq_context]`-verified: only field
// reads/writes, a `raw.load`, and calls to already-irq_context-annotated callees (async_complete,
// vq_free_desc, net_pool_release). It deliberately does NOT call vq_complete (which reconstructs and
// could free DMA buffers); it returns the single descriptor to the free list with the pure-field
// vq_free_desc and releases the pool slot — no DMA-allocator call, so no per-send leak and no
// non-irq-safe call.

// The value async_complete delivers on a successful TX completion ("the frame went out"). A nonzero
// sentinel so the awaiter can distinguish a real completion from a zero default.
export const NET_TX_DONE: i32 = 1;

// Translate a reaped head descriptor id back to its broker id and pool slot, clearing the map entry.
// Returns ASYNC_NO_ID (and leaves `*out_slot` = MAP_LEN) for an id we have no record of (a
// stale/duplicate completion — a safe no-op). Clearing `present` first makes a duplicate completion
// for the same head find nothing, so the descriptor/slot are freed exactly once.
#[irq_context]
fn net_map_take(m: *mut NetReqMap, desc_id: u16, out_slot: *mut usize, out_dst: *mut usize, out_max: *mut usize) -> u64 {
    var i: usize = 0;
    while i < MAP_LEN {
        if m.e[i].present && m.e[i].desc_id == desc_id {
            let id: u64 = m.e[i].broker_id;
            out_slot.* = m.e[i].pool_slot;
            out_dst.* = m.e[i].dst;
            out_max.* = m.e[i].max;
            m.e[i].present = false;
            return id;
        }
        i = i + 1;
    }
    out_slot.* = MAP_LEN;
    out_dst.* = 0;
    out_max.* = 0;
    return ASYNC_NO_ID;
}

// Reap one used-ring entry by hand: read the head id and used length at the consumer cursor,
// advance the cursor, and write the used length to `out_len`. Returns the head descriptor id, or
// 0xFFFF if the id is out of range (a misbehaving device — we still advance to avoid wedging the
// ISR). Call only when `vq.used.idx != vq.last_used`.
#[irq_context]
fn net_reap_one_head(vq: *mut Virtq, out_len: *mut u32) -> u16 {
    let slot: usize = (vq.last_used % VRING_QSIZE) as usize;
    let raw_id: u32 = vq.used.ring[slot].id;
    out_len.* = vq.used.ring[slot].len;
    vq.last_used = vq.last_used + 1; // advance consumer cursor (wraps mod 2^16, depth ≤ 8)
    if raw_id >= VRING_QSIZE as u32 {
        return 0xFFFF;
    }
    return raw_id as u16;
}

#[irq_context]
fn net_copy_rx_frame(pool: *mut NetBufPool, slot: usize, dst: usize, max: usize, used_len: u32) -> usize {
    if slot >= MAP_LEN {
        return 0;
    }
    var n: usize = 0;
    let total: usize = used_len as usize;
    if total > FRAME_AT {
        n = total - FRAME_AT;
        let cap: usize = FRAME_BUF_LEN - FRAME_AT;
        if n > cap {
            n = cap;
        }
        if n > max {
            n = max;
        }
        var i: usize = 0;
        let src: usize = pool.s[slot].buf_cpu + FRAME_AT;
        while i < n {
            var b: u8 = 0;
            unsafe { b = raw.load<u8>(phys(src + i)); }
            unsafe { raw.store<u8>(phys(dst + i), b); }
            i = i + 1;
        }
    }
    return n;
}

// THE DEVICE IRQ HANDLER. Called from the trap dispatcher when the virtio-net used-ring interrupt
// fires (after the PLIC source is claimed by the caller). It reads interrupt_status, reaps pending
// TX and RX used entries, translates each head id to a broker id, returns the descriptor/pool slot,
// and `async_complete`s the broker id. TX completes with NET_TX_DONE; RX completes with the copied
// Ethernet-frame byte count. Then it ACKs the device interrupt. Returns how many used entries it
// reaped (0 if this was not a used-ring interrupt) so the caller can trace it. `#[irq_context]`: no
// heap, no blocking, no DMA frees — only annotated broker/vq calls plus field/MMIO/raw accesses.
#[irq_context]
export fn net_irq_reap(dev: *mut NetAsyncDev) -> u32 {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let st: u32 = regs.interrupt_status.read(.acquire);
    var reaped: u32 = 0;
    if (st & VIRTIO_INT_USED) != 0 {
        let rxq: *mut Virtq = dev.rxq;
        var rx_guard: usize = 0;
        while rx_guard < VRING_QSIZE as usize {
            if rxq.used.idx == rxq.last_used {
                break;
            }
            rx_guard = rx_guard + 1;
            var rx_used_len: u32 = 0;
            let rx_head: u16 = net_reap_one_head(rxq, &rx_used_len);
            if rx_head != 0xFFFF {
                var rx_slot: usize = MAP_LEN;
                var rx_dst: usize = 0;
                var rx_max: usize = 0;
                let rx_bid: u64 = net_map_take(dev.rx_map, rx_head, &rx_slot, &rx_dst, &rx_max);
                if rx_bid != ASYNC_NO_ID {
                    let rx_n: usize = net_copy_rx_frame(dev.rx_pool, rx_slot, rx_dst, rx_max, rx_used_len);
                    vq_free_desc(rxq, rx_head);
                    net_pool_release(dev.rx_pool, rx_slot);
                    let _rx_ok: bool = async_complete(dev.broker, dev.procs, rx_bid, rx_n as i32);
                }
            }
            reaped = reaped + 1;
        }

        let vq: *mut Virtq = dev.txq;
        // Bounded by the queue depth (VRING_QSIZE): at most that many sends can be in flight, so at
        // most that many used entries can be pending — a hard bound for the irq_context verifier.
        var guard: usize = 0;
        while guard < VRING_QSIZE as usize {
            if vq.used.idx == vq.last_used {
                break;
            }
            guard = guard + 1;
            var tx_used_len: u32 = 0;
            let tx_head: u16 = net_reap_one_head(vq, &tx_used_len);
            if tx_head != 0xFFFF {
                var tx_slot: usize = MAP_LEN;
                var tx_dst: usize = 0;
                var tx_max: usize = 0;
                let tx_bid: u64 = net_map_take(dev.tx_map, tx_head, &tx_slot, &tx_dst, &tx_max);
                if tx_bid != ASYNC_NO_ID {
                    // A real in-flight frame we have not freed yet: return its single descriptor to
                    // the free list (replenishing the queue) and release the buffer-pool slot, then
                    // wake the awaiter. Doing this only on a present entry means a stale/duplicate
                    // completion frees nothing — no double-free.
                    vq_free_desc(vq, tx_head);
                    net_pool_release(dev.tx_pool, tx_slot);
                    let _tx_ok: bool = async_complete(dev.broker, dev.procs, tx_bid, NET_TX_DONE);
                }
            }
            reaped = reaped + 1;
        }
    }
    // ACK the bits we handled so the device de-asserts its interrupt line.
    regs.interrupt_ack.write(st, .release);
    return reaped;
}
