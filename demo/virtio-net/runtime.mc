// Bare-metal riscv64 runtime for the virtio-net driver, in PURE MC (the all-MC replacement for
// demo/virtio-net/runtime.c). Does the platform's job — virtio-mmio device discovery + DMA memory +
// the vring backing store — and hands the MC driver (virtio_net.mc) the device base plus the
// virtqueue. Reports progress over the QEMU `virt` 16550 UART, then exits via the SiFive finisher.
//
// Imports nothing from std: virtio_net.mc already emits std/virtqueue + std/virtio's exported
// symbols, so the vring structs are mirrored locally (the FULL std/virtqueue.mc Virtq layout — the
// old C runtime under-declared it) and `regs` is passed as an opaque usize (== MmioPtr<VirtioMmio>).

const CLINT_MTIME: usize = 0x0200_BFF8;
const UART: usize = 0x1000_0000;
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;
const VIRTIO_MMIO_BASE: usize = 0x1000_1000;
const VIRTIO_MMIO_STRIDE: usize = 0x1000;
const VIRTIO_MMIO_COUNT: usize = 8;
const VIRTIO_MAGIC: u32 = 0x7472_6976;
const VIRTIO_NET_ID: u32 = 1;

// vring structs — mirror std/virtqueue.mc EXACTLY (the driver reads them through txq's pointers).
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

// The MC virtio-net driver (demo/virtio-net/virtio_net.mc). `regs` is the raw virtio-mmio base.
extern fn nic_init(regs: usize, txq: *mut Virtq) -> i32;
extern fn nic_transmit(regs: usize, txq: *mut Virtq, payload_len: u16) -> i32;

// ----- CLINT time source (consumed by the driver via std/time externs) -----
export fn mc_read_ticks() -> u64 {
    var t: u64 = 0;
    unsafe { t = raw.load<u64>(phys(CLINT_MTIME)); }
    return t;
}
export fn mc_udelay(us: u32) -> void {
    let target: u64 = mc_read_ticks() + (us as u64) * 10;
    while mc_read_ticks() < target {}
}

// ----- DMA bounce pool (single-slot, zeroed; consumed via std/dma externs) -----
const DMA_POOL_LEN: usize = 2048;
const DMA_ALIGN: usize = 16;
global g_dma_pool: [2064]u8; // 2048 usable + 16 bytes of slack for the runtime 16-byte alignment
global g_dma_in_use: u32 = 0;
// Fallible variant: 0 on exhaustion / in-use (no hang) so std/dma's try_alloc can return a typed
// DmaError. Single source of truth; the infallible mc_dma_alloc_base wraps it.
export fn mc_dma_alloc_base_try(len: usize) -> usize {
    if len > DMA_POOL_LEN {
        return 0; // request larger than the single-slot pool
    }
    if g_dma_in_use != 0 {
        return 0; // the single buffer is already outstanding
    }
    g_dma_in_use = 1;
    // 16-align the frame (virtio descriptors + the device DMA expect it; matches the old C
    // `__attribute__((aligned(16)))` on the pool).
    let base: usize = ((&g_dma_pool) as usize + (DMA_ALIGN - 1)) & ~(DMA_ALIGN - 1);
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
        while true {} // contract violation: too large, or a buffer is already outstanding
    }
    return base;
}
export fn mc_dma_free_base(dev_addr: usize, cpu_addr: usize, len: usize) -> void {
    g_dma_in_use = 0;
}
export fn mc_dma_clean_for_device_base(dev_addr: usize, cpu_addr: usize, len: usize) -> void {}
export fn mc_dma_invalidate_for_cpu_base(dev_addr: usize, len: usize) -> usize {
    return dev_addr;
}

// ----- vring backing memory -----
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_txq: Virtq;

// ----- bare 16550 UART console -----
fn putc_(c: u8) -> void {
    unsafe { raw.store<u8>(phys(UART), c); }
}
fn puts_(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        putc_(b);
        i = i + 1;
    }
}
fn hex_digit(v: u32) -> u8 {
    let n: u32 = v & 0xf;
    if n < 10 {
        return (48 + n) as u8;
    }
    return (87 + n) as u8;
}
fn puthex(v: u64) -> void {
    putc_(48); // '0'
    putc_(120); // 'x'
    var shift: i32 = 60;
    while shift >= 0 {
        putc_(hex_digit((v >> (shift as u32)) as u32));
        shift = shift - 4;
    }
}

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

export fn test_main() -> void {
    let regs: usize = find_net_device();
    if regs == 0 {
        puts_("NODEV\n");
    } else {
        puts_("DISC ");
        puthex(regs as u64);
        putc_(10);
        g_txq.desc = &g_desc;
        g_txq.avail = &g_avail;
        g_txq.used = &g_used;
        if nic_init(regs, &g_txq) == 0 {
            puts_("INIT-FAIL\n");
        } else {
            puts_("INIT-OK\n");
            if nic_transmit(regs, &g_txq, 60) == 0 {
                puts_("TX-FAIL\n");
            } else {
                puts_("VIRTIO-TX-OK\n");
            }
        }
    }
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
