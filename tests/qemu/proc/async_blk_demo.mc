// async/await roadmap: DEVICE-BACKED completion. The capstone of the IRQ-backed async path —
// the awaited completion is delivered not by a timer (async_irq/async_future demos) but by a REAL
// virtio-blk device interrupt. An `async fn` submits an async read of sector 0; the task sleeps
// in `wfi`; the virtio-blk used-ring interrupt (routed through the PLIC, M-mode context 0) fires;
// the trap dispatcher claims the PLIC source, `blk_irq_reap` reaps the used ring and
// `async_complete`s the broker request id with the sector's first word; the parked `await`
// resumes. This proves async is device-driven, not a polling timer demo.
//
// Trace `W <i> R`:  W (future constructed, about to drive), `i` (the IRQ handler ran in INTERRUPT
// context and reaped a device completion), R (driven to completion). The token ASYNC-BLK-OK plus
// the printed sector word "DISK" prove the value round-tripped from the disk via the device IRQ.
//
// PRIVILEGE / IRQ ROUTING: this boots in M-mode (`-bios none`, like every async_*_runtime), so it
// uses the M-mode PLIC context 0 (PLIC_BASE 0x0c00_0000, the same context kernel/drivers/irq/plic.mc
// targets) and the machine external interrupt (mcause = 0x8000…000B). On QEMU virt the virtio-mmio
// slot at 0x1000_1000 is PLIC source 1 (slot N → source N+1); we derive the source from the probed
// device address so it tracks whichever slot QEMU placed the device in.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "kernel/drivers/virtio/virtio_blk_async.mc";
import "kernel/lib/async.mc";
import "kernel/lib/async_future.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";

extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;

const VIRTIO_ID_BLK: u32 = 2;

// QEMU virt PLIC, hart 0 MACHINE context 0 (matches kernel/drivers/irq/plic.mc).
const PLIC_BASE: usize = 0x0c00_0000;
const PLIC_PRIORITY: usize = 0x0c00_0000;   // + line*4
const PLIC_M_ENABLE: usize = 0x0c00_2000;   // hart 0 M-mode enable bitmap (ctx 0)
const PLIC_M_THRESHOLD: usize = 0x0c20_0000; // hart 0 M-mode threshold (ctx 0)
const PLIC_M_CLAIM: usize = 0x0c20_0004;    // hart 0 M-mode claim/complete (ctx 0)

// virtio-mmio slot 0 base and stride, to derive the PLIC source from the device address.
const VMMIO_SLOT0_BASE: usize = 0x1000_1000;
const VMMIO_SLOT_STRIDE: usize = 0x1000;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_map: BlkReqMap;
global g_vq: Virtq;
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_dev: BlkAsyncDev;
global g_irq_src: u32 = 0;     // the PLIC source line for the blk device
global g_irq_count: u32 = 0;   // device IRQs handled (proof of device-driven completion)

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
// Claim the PLIC source, reap the virtio-blk used ring (which `async_complete`s the broker id and
// wakes the parked awaiter), and complete at the PLIC. `#[irq_context]`: only the annotated PLIC
// and reap calls. The 'i' trace is emitted by the dispatcher (an opaque MMIO extern), not here, so
// this stays verifier-clean.
#[irq_context]
export fn blk_on_irq() -> void {
    let src: u32 = plic_claim();
    if src == g_irq_src {
        let _n: u32 = blk_irq_reap(&g_dev);
        g_irq_count = g_irq_count + 1;
    }
    plic_complete(src);
}

// A real async fn whose single `await` resolves against a REAL device completion: req_begin makes
// a ReqFut over the broker id returned by the async submit, and the await suspends until the
// virtio-blk IRQ async_completes that id. Lowered to a stackless state machine (spec §33.2).
async fn read_sector0(b: *mut AsyncBroker, id: u64) -> i32 {
    let w: i32 = await req_over(b, id);
    return w;
}

export fn async_blk_demo() -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);

    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_BLK);
    if !virtio_device_present(regs) {
        puts_("NODEV\n");
        return 0;
    }

    // Assign these globals as WHOLE aggregates (a single struct copy), not field-by-field: a field
    // store into a global struct that the IRQ handler also reaches (via &g_dev / g_dev.vq) would be
    // lowered to a race-instrumented `mc_race_store` accessor (the globals are cross-context shared).
    // A whole-struct assignment lowers to a plain copy, which is what we want — and it is sound here
    // because every field is written before any interrupt is enabled below.
    g_vq.desc = &g_desc;
    g_vq.avail = &g_avail;
    g_vq.used = &g_used;

    g_dev = .{
        .regs = regs,
        .vq = &g_vq,
        .map = &g_map,
        .broker = &g_broker,
        .procs = &g_procs,
    };

    switch blk_async_init(&g_dev) {
        ok(up) => {}
        err(e) => {
            puts_("BLK-INIT-FAIL\n");
            return 0;
        }
    }

    // Route the device's PLIC source to this hart (M-mode context 0) and enable M-external IRQs.
    g_irq_src = virtio_plic_source(regs as usize);
    plic_enable_src(g_irq_src);
    enable_external_interrupt();   // mie.MEIE

    // Submit the async read and build a future over its broker id.
    let id: u64 = blk_read_sector_async(&g_dev, 0);
    if id == ASYNC_NO_ID {
        puts_("BLK-SUBMIT-FAIL\n");
        return 0;
    }

    var f: read_sector0__Fut = read_sector0(&g_broker, id);
    putc_(87); // 'W' — future built, about to drive under wfi
    // Drive to completion: poll with interrupts off, wfi until the device IRQ async_completes it.
    drive_irq(&f, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
    putc_(82); // 'R' — resumed

    let word: i32 = read_sector0__Fut_take_result(&f);
    return word as u32;
}
