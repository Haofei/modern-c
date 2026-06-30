// NIC bring-up seam for the integrated kernel + network image, in PURE MC (the all-MC replacement
// for kmain_net_runtime.c). The console, mc_halt, the callee-saved context switch, mc_thread_init,
// and the `.text.start` `_start` come from the shared M-mode bring-up (context_runtime.mc); this
// unit adds the NIC seam: the CLINT time source, the DMA bounce pool, the virtio-net probe, the
// vring backing memory, and `test_main` — discover the NIC, build the TX queue, run kmain_net, and
// report KERNEL-NET-OK when the core subsystems came up and a UDP datagram was transmitted.
//
// It imports NOTHING from std on purpose: std/virtqueue + std/virtio + std/dma + std/time each emit
// strong exported symbols, and the integrated demo object (kmain_net_demo.mc) already emits those.
// A second copy here would be a duplicate-definition link error. So the vring structs are mirrored
// locally (the demo owns the real Virtq logic; this unit only fills txq.desc/avail/used), `regs` is
// passed as an opaque usize (ABI-identical to the demo's MmioPtr<VirtioMmio>), and the platform
// primitives the driver calls via extern (mc_read_ticks/mc_udelay/mc_dma_*) are defined here.

const CLINT_MTIME: usize = 0x0200_BFF8;     // QEMU virt CLINT mtime (10 MHz under -machine virt)
const VIRTIO_MMIO_BASE: usize = 0x1000_1000; // first virtio-mmio transport
const VIRTIO_MMIO_STRIDE: usize = 0x1000;
const VIRTIO_MMIO_COUNT: usize = 8;
const VIRTIO_MAGIC: u32 = 0x7472_6976;       // "virt" little-endian magic at offset 0
const VIRTIO_NET_ID: u32 = 1;                // DeviceID 1 = network card (offset 8)

// ----- vring structs: mirror std/virtqueue.mc EXACTLY (layout must match; the demo's driver reads
// these through the pointers stored in txq). Local copies avoid importing std/virtqueue, whose many
// exported fns would clash at link with the demo object's copies. -----
struct VringDesc { addr: u64, len: u32, flags: u16, next: u16 }
struct DescTable { d: [8]VringDesc }
struct VringAvail { flags: u16, idx: u16, ring: [8]u16, used_event: u16 }
struct UsedElem { id: u32, len: u32 }
struct VringUsed { flags: u16, idx: u16, ring: [8]UsedElem, avail_event: u16 }
struct Virtq {
    desc: *mut DescTable,
    avail: *mut VringAvail,
    used: *mut VringUsed,
    size: u16,
    free_head: u16,
    num_free: u16,
    last_used: u16,
    inflight_addr: [8]u64,
    inflight_len: [8]u32,
    inflight_present: [8]bool,
}

// From the shared M-mode bring-up runtime (context_runtime.mc).
extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;

// The integrated kernel+network demo (tests/qemu/net/kmain_net_demo.mc). On the demo side `regs` is
// an MmioPtr<VirtioMmio>; here it is the raw virtio-mmio base address (ABI-identical: a pointer).
extern fn kmain_net(region_base: usize, region_len: usize, regs: usize, txq: *mut Virtq) -> u32;

// ----- CLINT time source (M-mode); consumed by the driver via the std/time externs -----
export fn mc_read_ticks() -> u64 {
    var t: u64 = 0;
    unsafe { t = raw.load<u64>(phys(CLINT_MTIME)); }
    return t;
}
export fn mc_udelay(us: u32) -> void {
    let target: u64 = mc_read_ticks() + (us as u64) * 10; // 10 ticks/us on QEMU virt
    while mc_read_ticks() < target {}
}

// ----- DMA bounce pool (one-shot); consumed by the driver via the std/dma externs -----
const DMA_POOL_LEN: usize = 2048;
global g_dma_pool: [2048]u8;
global g_dma_in_use: u32 = 0;

// Fallible variant: returns 0 on exhaustion / in-use (no trap) so std/dma's `try_alloc` can
// surface a typed DmaError. Single source of truth; infallible `mc_dma_alloc_base` wraps it.
export fn mc_dma_alloc_base_try(len: usize) -> usize {
    if len > DMA_POOL_LEN {
        return 0; // request larger than the one-shot pool
    }
    if g_dma_in_use != 0 {
        return 0; // the single buffer is already outstanding
    }
    g_dma_in_use = 1;
    let base: usize = (&g_dma_pool) as usize;
    var i: usize = 0;
    while i < len {
        unsafe { raw.store<u8>(phys(base + i), 0); }
        i = i + 1;
    }
    return base;
}

export fn mc_dma_alloc_base(len: usize) -> usize {
    let base: usize = mc_dma_alloc_base_try(len);
    if base == 0 {
        // Fail closed and DIAGNOSABLY: trap (reports the fault site) rather than spin forever in a
        // silent `while true {}` that is indistinguishable from a hang. The fallible `try` variant
        // above is the typed-NoMem path for production broker/device callers.
        unreachable; // DMA pool exhausted or single buffer already in use
    }
    return base;
}
export fn mc_dma_free_base(_dev_addr: usize, _cpu_addr: usize, _len: usize) -> void {
    g_dma_in_use = 0; // one-shot pool: free just releases the in-use flag (args unused)
}
export fn mc_dma_clean_for_device_base(_dev_addr: usize, _cpu_addr: usize, _len: usize) -> void {
    // identity-mapped, cache-coherent under QEMU: nothing to flush
}
export fn mc_dma_invalidate_for_cpu_base(dev_addr: usize, _len: usize) -> usize {
    return dev_addr; // identity-mapped: the CPU address equals the device address
}

// ----- vring backing memory + heap -----
// Typed vring globals; the driver in the demo object reads/writes them through the pointers stored
// in txq. Taking their address (`&g_desc`) yields a properly-typed, provenance-carrying pointer —
// unlike an int-to-pointer cast off a computed offset, which the verifier cannot prove well-formed.
// DescTable's natural alignment (8, from its u64 fields) satisfies QEMU's split-virtqueue layout.
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_txq: Virtq;
global g_heap_region: [262144]u8;

// Probe the 8 virtio-mmio slots for a virtio-net device (magic + DeviceID 1); return its base or 0.
fn find_net_device() -> usize {
    var i: usize = 0;
    while i < VIRTIO_MMIO_COUNT {
        let slot: usize = VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE;
        var magic: u32 = 0;
        var devid: u32 = 0;
        unsafe {
            magic = raw.load<u32>(phys(slot));
            devid = raw.load<u32>(phys(slot + 8));
        }
        if magic == VIRTIO_MAGIC && devid == VIRTIO_NET_ID {
            return slot;
        }
        i = i + 1;
    }
    return 0;
}

// ASCII hex digit for the low nibble of `v`.
fn hex_digit(v: u32) -> u8 {
    let n: u32 = v & 0xf;
    if n < 10 {
        return (48 + n) as u8; // '0'
    }
    return (87 + n) as u8; // 'a' - 10
}

export fn test_main() -> void {
    puts_("kmain-net boot (integrated kernel + network)\n");
    let regs: usize = find_net_device();
    if regs == 0 {
        puts_("NODEV\n");
        mc_halt();
    }
    g_txq.desc = &g_desc;
    g_txq.avail = &g_avail;
    g_txq.used = &g_used;
    let region: usize = (&g_heap_region) as usize;
    let stages: u32 = kmain_net(region, 262144, regs, (&g_txq) as *mut Virtq);
    puts_("\nstages=0x");
    putc_(hex_digit(stages >> 4));
    putc_(hex_digit(stages));
    putc_(10); // '\n'
    if stages == 0x3F {
        puts_("KERNEL-NET-OK\n"); // core subsystems + networking
    } else {
        puts_("KERNEL-NET-INCOMPLETE\n");
    }
    mc_halt();
}
