// kernel/arch/riscv64/sbi_dma_time — the std/dma + std/time PLATFORM PRIMITIVES for
// the S-mode/OpenSBI virtio runtimes, in PURE MC (no C). This is the all-MC
// replacement for the C providers that blk_smode_runtime.c / net_smode_runtime.c
// used to supply (mc_dma_alloc_base/free_base/clean/invalidate + mc_read_ticks/
// mc_udelay).
//
// These functions are the `extern fn` seam that std/dma.mc and std/time.mc declare.
// They MUST live in a SEPARATE compilation unit from those std modules: a single MC
// unit may not both `import` the `extern fn mc_read_ticks` declaration AND
// `export fn mc_read_ticks` a definition of it (one-name-per-unit). This object is
// linked alongside the driver/demo object, whose typed `extern fn` declarations the
// linker binds to these definitions by name (exactly as the C providers were).
//
// To avoid emitting a SECOND copy of std's exported helpers (which would clash at
// link with the driver object's copies — std fns are plain global symbols, not
// weak), this module imports NOTHING from std: it uses only language builtins
// (raw pointer stores, `&array[i]`) and inline asm. The address-class extern params
// (DmaAddr/PAddr) lower to pointer-sized usize, so the symbols are matched by name.
//
// Time: the architectural `rdtime` CSR (the CLINT/ACLINT mtime MMIO is NOT
// PMP-mapped into S-mode under OpenSBI, so a direct CLINT load faults; rdtime is
// kept in sync with the 10 MHz QEMU virt mtimer — same frequency as the M-mode
// CLINT path, so the `* 10` us scaling is unchanged).
// DMA: a 16-byte-aligned bump pool over coherent QEMU memory; the ownership
// transitions are identities (no cache maintenance; bus addr == CPU phys addr).

// Read the S-mode `time` CSR (rdtime).
fn rdtime() -> u64 {
    var t: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "rdtime %0"
                out("t0") t: u64
            }
        }
    }
    return t;
}

// std/time tick source. The typed `Ticks` (= counter<u64>) the std declares lowers
// to a plain u64 across the ABI; the symbol is matched by name.
export fn mc_read_ticks() -> u64 {
    return rdtime();
}

// Busy-wait `us` microseconds. 10 ticks/us at the QEMU virt 10 MHz timebase.
export fn mc_udelay(us: u32) -> void {
    let target: u64 = rdtime() + (us as u64) * 10;
    while rdtime() < target {}
}

// ----- std/dma platform primitives: a 16-byte-aligned bump pool -----
//
// Multiple buffers can be outstanding at once (the blk request chain holds three;
// the net path holds an RX ring + TX frames). A bump allocator never aliases live
// buffers; `free` is a no-op (the pool is one-shot for these smoke tests).
// Exhaustion traps rather than overruns. 64 KiB covers the net RX ring + TX frames;
// the blk path uses only a few hundred bytes.
// 8 MiB: blk/bearssl smoke need only a few KB, but the S-mode TLS/HTTPS path drives many unfreed
// RX refills + TX segments (matching the M-mode mmode_dma_time pool).
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
// (symbol matched by name). No-op: the bump pool is one-shot for these smoke tests.
export fn mc_dma_free_base(dev_addr: usize, cpu_addr: usize, len: usize) -> void {
}

// DMA ownership transitions — identity on QEMU's coherent memory.
export fn mc_dma_clean_for_device_base(dev_addr: usize, cpu_addr: usize, len: usize) -> void {
}

export fn mc_dma_invalidate_for_cpu_base(dev_addr: usize, len: usize) -> usize {
    // No-IOMMU: the bus address equals the CPU physical address.
    return dev_addr;
}
