// kernel/arch/riscv64/mmode_dma_time — the std/dma + std/time PLATFORM PRIMITIVES
// for the M-mode (`-bios none`) virtio runtimes, in PURE MC (no C). This is the
// all-MC replacement for the DMA pool + CLINT time source that blk_runtime.c
// supplied via platform.h / platform_virtio.h (mc_dma_alloc_base/free_base/clean/
// invalidate + mc_read_ticks/mc_udelay).
//
// These functions are the `extern fn` seam that std/dma.mc and std/time.mc declare.
// They MUST live in a SEPARATE compilation unit from those std modules: a single MC
// unit may not both `import` the `extern fn mc_read_ticks` declaration AND
// `export fn mc_read_ticks` a definition of it (one-name-per-unit). This object is
// linked alongside the driver/demo object, whose typed `extern fn` declarations the
// linker binds to these definitions by name (exactly as the C providers were).
//
// To avoid emitting a SECOND copy of std's exported helpers (which would clash at
// link with the driver object's copies), this module imports NOTHING from std: it
// uses only language builtins (raw pointer loads/stores). The address-class extern
// params (DmaAddr/PAddr) lower to pointer-sized usize, so the symbols match by name.
//
// Time: the CLINT mtime MMIO @ 0x0200_BFF8 (10 MHz on QEMU virt). Unlike the S-mode
// path (where the CLINT is not PMP-mapped into S-mode and rdtime is used), M-mode
// reaches the CLINT directly.
// DMA: a 16-byte-aligned bump pool over coherent QEMU memory; the ownership
// transitions are identities (no cache maintenance; bus addr == CPU phys addr).

const CLINT_MTIME: usize = 0x0200_BFF8;

// Read the M-mode CLINT mtime counter (10 MHz on QEMU virt).
fn read_mtime() -> u64 {
    var t: u64 = 0;
    unsafe { t = raw.load<u64>(phys(CLINT_MTIME)); }
    return t;
}

// std/time tick source. The typed `Ticks` (= counter<u64>) the std declares lowers
// to a plain u64 across the ABI; the symbol is matched by name.
export fn mc_read_ticks() -> u64 {
    return read_mtime();
}

// Busy-wait `us` microseconds. 10 ticks/us at the QEMU virt 10 MHz timebase.
export fn mc_udelay(us: u32) -> void {
    let target: u64 = read_mtime() + (us as u64) * 10;
    while read_mtime() < target {}
}

// ----- std/dma platform primitives: a 16-byte-aligned bump pool -----
//
// The blk request chain holds three buffers (header/data/status) outstanding at once;
// the bare net path holds an RX ring + TX frames; and the TCP/HTTP/TLS family drives
// many RX refills + TX segments with nothing freed (bump pool). The pool matches the
// 8 MiB the C TCP runtimes carried so it serves every M-mode virtio gate. A bump
// allocator never aliases live buffers; `free` is a no-op (the pool is one-shot for
// these smoke tests). Exhaustion traps rather than overruns.
const DMA_POOL_LEN: usize = 8 * 1024 * 1024;
global g_dma_pool: [8388608]u8;
global g_dma_off: usize = 0;

export fn mc_dma_alloc_base(len: usize) -> usize {
    let aligned: usize = (g_dma_off + 15) & ~(15 as usize);
    if aligned + len > DMA_POOL_LEN {
        unreachable; // pool exhausted
    }
    g_dma_off = aligned + len;
    var i: usize = 0;
    while i < len {
        g_dma_pool[aligned + i] = 0;
        i = i + 1;
    }
    return (&g_dma_pool[aligned]) as usize;
}

// dev_addr/cpu_addr are the std's DmaAddr/PAddr (pointer-sized); taken as usize here
// (symbol matched by name). No-op: the bump pool is one-shot for this smoke test.
export fn mc_dma_free_base(_dev_addr: usize, _cpu_addr: usize, _len: usize) -> void {
}

// DMA ownership transitions — identity on QEMU's coherent memory.
export fn mc_dma_clean_for_device_base(_dev_addr: usize, _cpu_addr: usize, _len: usize) -> void {
}

export fn mc_dma_invalidate_for_cpu_base(dev_addr: usize, _len: usize) -> usize {
    // No-IOMMU: the bus address equals the CPU physical address.
    return dev_addr;
}
