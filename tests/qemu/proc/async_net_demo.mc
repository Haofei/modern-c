// async/await roadmap: DEVICE-BACKED completion over the NETWORK CARD. The virtio-net analogue of
// async_blk_demo.mc — the awaited completion is delivered not by a timer, and not by the disk, but
// by a REAL virtio-net TX used-ring interrupt. An `async fn` submits an async frame send; the task
// sleeps in `wfi`; the virtio-net TX used-ring interrupt (routed through the PLIC, M-mode context 0)
// fires when the device has consumed the frame; the trap dispatcher claims the PLIC source,
// `net_irq_reap` reaps the TX used ring and `async_complete`s the broker request id, and the parked
// `await` resumes. This proves NIC async is device-driven, not a polling `tx_wait_reclaim` loop.
//
// Trace `W i R`:  W (future constructed, about to drive), `i` (the IRQ handler ran in INTERRUPT
// context and reaped a TX completion), R (driven to completion). The token ASYNC-NET-OK plus the
// completion value NET_TX_DONE prove the send round-tripped through the device IRQ.
//
// PRIVILEGE / IRQ ROUTING: identical to async_blk_demo — M-mode (`-bios none`), PLIC M-mode context
// 0, machine external interrupt (mcause = 0x8000…000B). The virtio-net device's PLIC source is
// derived from the probed device's mmio slot (slot N → source N+1).

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/alloc/dma.mc";
import "std/addr.mc";
import "kernel/drivers/virtio/virtio_net_async.mc";
import "kernel/net/arp.mc";
import "kernel/lib/async.mc";
import "kernel/lib/async_future.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";

extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;

const VIRTIO_ID_NET: u32 = 1;

// QEMU virt PLIC, hart 0 MACHINE context 0 (matches kernel/drivers/irq/plic.mc + async_blk_demo).
const PLIC_PRIORITY: usize = 0x0c00_0000;   // + line*4
const PLIC_M_ENABLE: usize = 0x0c00_2000;   // hart 0 M-mode enable bitmap (ctx 0)
const PLIC_M_THRESHOLD: usize = 0x0c20_0000; // hart 0 M-mode threshold (ctx 0)
const PLIC_M_CLAIM: usize = 0x0c20_0004;    // hart 0 M-mode claim/complete (ctx 0)

// virtio-mmio slot 0 base and stride, to derive the PLIC source from the device address.
const VMMIO_SLOT0_BASE: usize = 0x1000_1000;
const VMMIO_SLOT_STRIDE: usize = 0x1000;

// Our (made-up) identity for the ARP request we transmit. The frame just has to be a valid TX frame
// for the device to consume and complete it; whether anyone answers is irrelevant to a TX-completion
// proof.
const SRC_IP: u32 = 0x0A00_0202;    // 10.0.2.2
const TARGET_IP: u32 = 0x0A00_0201; // 10.0.2.1 (the slirp gateway)

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_map: NetReqMap;
global g_pool: NetBufPool;
global g_rxq: Virtq;
global g_rxdesc: DescTable;
global g_rxavail: VringAvail;
global g_rxused: VringUsed;
global g_txq: Virtq;
global g_txdesc: DescTable;
global g_txavail: VringAvail;
global g_txused: VringUsed;
global g_dev: NetAsyncDev;
global g_irq_src: u32 = 0;     // the PLIC source line for the net device
global g_irq_count: u32 = 0;   // device IRQs handled (proof of device-driven completion)

// A scratch buffer to build the ARP frame before handing its bytes to the async submit, which copies
// them into the pooled DMA buffer. (Global so its address is stable; the async path reads it once.)
global g_frame: [64]u8;

// ---- PLIC M-mode context helpers (raw register access) ----

fn plic_enable_src(src: u32) -> void {
    unsafe {
        raw.store<u32>(phys(PLIC_PRIORITY + (src as usize) * 4), 1); // priority > threshold
        raw.store<u32>(phys(PLIC_M_THRESHOLD), 0);
        let cur: u32 = raw.load<u32>(phys(PLIC_M_ENABLE));
        raw.store<u32>(phys(PLIC_M_ENABLE), cur | ((1 as u32) << src));
    }
}

#[irq_context]
fn plic_claim() -> u32 {
    unsafe { return raw.load<u32>(phys(PLIC_M_CLAIM)); }
}

#[irq_context]
fn plic_complete(src: u32) -> void {
    unsafe { raw.store<u32>(phys(PLIC_M_CLAIM), src); }
}

// The PLIC source line for a virtio-mmio device at `addr` on QEMU virt: slot N → source N+1.
fn virtio_plic_source(addr: usize) -> u32 {
    let slot: usize = (addr - VMMIO_SLOT0_BASE) / VMMIO_SLOT_STRIDE;
    return (slot + 1) as u32;
}

// THE DEVICE IRQ ENTRY, called from the runtime trap dispatcher on a machine external interrupt.
// Claim the PLIC source, reap the virtio-net TX used ring (which `async_complete`s the broker id and
// wakes the parked awaiter), and complete at the PLIC. `#[irq_context]`: only the annotated PLIC and
// reap calls. The 'i' trace is emitted by the dispatcher, not here, so this stays verifier-clean.
#[irq_context]
export fn net_on_irq() -> void {
    let src: u32 = plic_claim();
    if src == g_irq_src {
        let _n: u32 = net_irq_reap(&g_dev);
        g_irq_count = g_irq_count + 1;
    }
    plic_complete(src);
}

// A real async fn whose single `await` resolves against a REAL device completion: req_over makes a
// ReqFut over the broker id returned by the async submit, and the await suspends until the
// virtio-net TX IRQ async_completes that id. Lowered to a stackless state machine (spec §33.2).
async fn send_frame(b: *mut AsyncBroker, id: u64) -> i32 {
    let w: i32 = await req_over(b, id);
    return w;
}

// Build a broadcast ARP request into g_frame (virtio_net_hdr zeroed at offset 0, Ethernet ARP at
// offset 12) and return the total framed length. We borrow a CpuBuffer VIEW over g_frame to reuse
// the audited arp/eth writers, then forget the view (g_frame owns the bytes).
fn build_arp_frame() -> usize {
    var i: usize = 0;
    while i < 64 {
        g_frame[i] = 0;
        i = i + 1;
    }
    let cpu_at: usize = (&g_frame[0]) as usize;
    var dev: DmaAddr = uninit;
    unsafe { dev = (cpu_at as DmaAddr); }
    let view: CpuBuffer = .{ .dev_addr = dev, .cpu_addr = pa(cpu_at), .len = 64 };
    var mac: MacAddr = my_mac();
    let frame_len: usize = arp_write_request(&view, 12, &mac, SRC_IP, TARGET_IP);
    unsafe { forget_unchecked(view); }
    return 12 + frame_len; // virtio_net_hdr (12) + Ethernet ARP frame (42) = 54
}

fn my_mac() -> MacAddr {
    return .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };
}

export fn async_net_demo() -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);

    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_NET);
    if !virtio_device_present(regs) {
        puts_("NODEV\n");
        return 0;
    }

    // Wire each queue's three vring regions, then assign the device globals as WHOLE aggregates (a
    // single struct copy) — a field store into a global the IRQ handler reaches would lower to a
    // race-instrumented accessor; a whole-struct assignment lowers to a plain copy, sound here
    // because every field is written before any interrupt is enabled below.
    g_rxq.desc = &g_rxdesc;
    g_rxq.avail = &g_rxavail;
    g_rxq.used = &g_rxused;
    g_txq.desc = &g_txdesc;
    g_txq.avail = &g_txavail;
    g_txq.used = &g_txused;

    g_dev = .{
        .regs = regs,
        .rxq = &g_rxq,
        .txq = &g_txq,
        .map = &g_map,
        .pool = &g_pool,
        .broker = &g_broker,
        .procs = &g_procs,
    };

    switch net_async_init(&g_dev) {
        ok(up) => {}
        err(e) => {
            puts_("NET-INIT-FAIL\n");
            return 0;
        }
    }

    // Route the device's PLIC source to this hart (M-mode context 0) and enable M-external IRQs.
    g_irq_src = virtio_plic_source(regs as usize);
    plic_enable_src(g_irq_src);
    enable_external_interrupt(); // mie.MEIE

    let frame_len: usize = build_arp_frame();
    let frame_ptr: usize = (&g_frame[0]) as usize;

    // REPEATED-SEND leak probe. A TX frame consumes 1 of the 8 (VRING_QSIZE) TX descriptors per send;
    // the ISR must free it (and the pool slot) on completion or the free list would erode and a later
    // send would hit QUEUE-FULL (ASYNC_NO_ID) and the DMA buffer would leak. We do NSENDS sequential
    // sends, each awaited to completion via the device IRQ; if descriptors + pool slots are reclaimed
    // in the ISR, every send succeeds and the TX free list returns to full (8) after each. We assert
    // FULL after the last send (the leak-regression guard, like async_blk's free=8).
    let nsends: usize = 3;
    var word: i32 = 0;
    var n: usize = 0;
    while n < nsends {
        let id: u64 = net_send_frame_async(&g_dev, frame_ptr, frame_len);
        if id == ASYNC_NO_ID {
            puts_("\nNET-QUEUE-FULL\n");
            return 0;
        }

        var f: send_frame__Fut = send_frame(&g_broker, id);
        putc_(87); // 'W' — future built, about to drive under wfi
        // Drive to completion: poll with interrupts off, wfi until the device IRQ async_completes it.
        drive_irq(&f, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
        putc_(82); // 'R' — resumed

        word = send_frame__Fut_take_result(&f);
        if word != NET_TX_DONE {
            puts_("\nNET-VALUE-FAIL\n");
            return 0;
        }
        n = n + 1;
    }

    // After all sends completed, the TX descriptor free list must be fully replenished — proof the
    // ISR returns every frame's descriptor + pool slot (no QUEUE-FULL leak). VRING_QSIZE == 8.
    let free_now: u16 = vq_free_count(&g_txq);
    puts_("\nfree=");
    putc_((48 + (free_now % 10) as u8)); // single decimal digit (8)
    putc_(10);
    if free_now == 8 {
        puts_("NET-NOLEAK-OK\n"); // all NSENDS sends succeeded AND TX free list back to full
    } else {
        puts_("NET-NOLEAK-FAIL\n");
        return 0;
    }

    return word as u32;
}
