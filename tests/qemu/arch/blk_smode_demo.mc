// S-mode/OpenSBI virtio-blk smoke — in PURE MC (no C). Revalidates the EXISTING MC
// virtio-blk driver (tests/qemu/fs/blk_demo.mc -> kernel/drivers/virtio/virtio_blk.mc)
// under REAL OpenSBI firmware in S-mode, instead of the M-mode `-bios none` path.
// This is the all-MC replacement for kernel/arch/riscv64/blk_smode_runtime.c.
//
// The boot seam (a0=hartid/a1=dtb preserved into s_entry), the SBI console +
// shutdown, the rdtime-backed time source, the bump DMA pool, and the virtio-mmio
// device probe are the shared MC modules (sbi.mc / sbi_virtio_platform.mc). The
// vring memory + the Virtq handle are provided here as zeroed globals (the driver
// does vq_setup over them); the driver call (blk_demo_run) is IDENTICAL to the
// M-mode path. satp is left 0 (Bare = flat physical); OpenSBI's PMP permits S-mode
// virtio-mmio + RAM DMA so the flat-physical driver works unchanged.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "tests/qemu/fs/blk_demo.mc";

const VIRTIO_ID_BLK: u32 = 2;

// vring memory for the single blk queue (zeroed in BSS; the driver lays out the
// split virtqueue over it).
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_vq: Virtq;

export fn s_entry(_hartid: u64, _dtb: u64) -> void {
    sbi_puts("blk: S-mode under OpenSBI\n");

    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_BLK);
    if !virtio_device_present(regs) {
        sbi_puts("NODEV\n");
        sbi_shutdown();
        while true {}
    }
    sbi_puts("blk: device found\n");

    g_vq.desc = &g_desc;
    g_vq.avail = &g_avail;
    g_vq.used = &g_used;

    let word: u64 = blk_demo_run(regs, &g_vq, 0);
    if word == 0xFFFF_FFFF_FFFF_FFFF {
        sbi_puts("BLK-INIT-FAIL\n");
        sbi_shutdown();
        while true {}
    }
    if word == 0xFFFF_FFFF_FFFF_FFFE {
        sbi_puts("BLK-READ-FAIL\n");
        sbi_shutdown();
        while true {}
    }

    // `word` is the first little-endian 32-bit word of sector 0.
    sbi_puts("BLK-READ ");
    sbi_putchar((word & 0xFF) as u8);
    sbi_putchar(((word >> 8) & 0xFF) as u8);
    sbi_putchar(((word >> 16) & 0xFF) as u8);
    sbi_putchar(((word >> 24) & 0xFF) as u8);
    sbi_puts("\nBLK-OK\n");

    sbi_shutdown();
    while true {}
}

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack but
// DO NOT clobber a0/a1 before the call, so s_entry receives them as its first two
// args. `#[section(".text.boot")]` pins `_start` to 0x80200000 (sbi.ld KEEPs
// .text.boot first), where OpenSBI jumps.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
