// Bare-metal riscv64 M-mode (`-bios none`) virtio-blk runtime — in PURE MC (no C).
// The all-MC replacement for kernel/arch/riscv64/blk_runtime.c. Revalidates the
// EXISTING MC virtio-blk driver (tests/qemu/fs/blk_demo.mc ->
// kernel/drivers/virtio/virtio_blk.mc) under the M-mode `-bios none` path (QEMU
// jumps straight to 0x80000000 in M-mode; there is NO firmware), distinct from the
// S-mode/OpenSBI path (tests/qemu/arch/blk_smode_demo.mc).
//
// The device probe is the shared MC virtio-mmio probe (sbi_virtio_probe.mc — pure
// MMIO, identical in M- and S-mode); the vring memory + the Virtq handle are zeroed
// globals here (the driver lays out the split virtqueue over them); the driver call
// (blk_demo_run) is IDENTICAL to the S-mode path. Console is the bare 16550 UART
// (no SBI), and the std/dma + std/time platform primitives (CLINT mtime time source
// + bump DMA pool) are a SEPARATE MC object (mmode_dma_time.mc) linked beside this
// one so its definitions bind the std `extern fn` seam by name.

import "tests/qemu/lib/test_report.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "tests/qemu/fs/blk_demo.mc";

const VIRTIO_ID_BLK: u32 = 2;
const FINISHER: usize = 0x0010_0000; // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;

// vring memory for the single blk queue (zeroed in BSS; the driver lays out the
// split virtqueue over it).
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_vq: Virtq;

// Power off via the SiFive test finisher (never returns).
fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

export fn test_main() -> void {
    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_BLK);
    if !virtio_device_present(regs) {
        uputs("NODEV\n");
        halt();
    }
    uputs("blk: device found\n");

    g_vq.desc = &g_desc;
    g_vq.avail = &g_avail;
    g_vq.used = &g_used;

    let word: u64 = blk_demo_run(regs, &g_vq, 0);
    if word == 0xFFFF_FFFF_FFFF_FFFF {
        uputs("BLK-INIT-FAIL\n");
        halt();
    }
    if word == 0xFFFF_FFFF_FFFF_FFFE {
        uputs("BLK-READ-FAIL\n");
        halt();
    }

    // `word` is the first little-endian 32-bit word of sector 0.
    uputs("BLK-READ ");
    uputc((word & 0xFF) as u8);
    uputc(((word >> 8) & 0xFF) as u8);
    uputc(((word >> 16) & 0xFF) as u8);
    uputc(((word >> 24) & 0xFF) as u8);
    uputs("\nBLK-OK\n");

    halt();
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. `#[section(".text.start")]` pins
// `_start` there (virt.ld: `*(.text.start)` first, `ENTRY(_start)`). Set the stack
// and call into the kernel; never returns.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
