// Persist-across-reboot proof (production-readiness §3.1 #3): write a sentinel to a virtio-blk
// disk on the FIRST boot, then a SECOND boot (fresh kernel + cleared RAM, SAME disk image) reads it
// back — proving durable storage survives a real reboot, not just an in-RAM roundtrip.
//
// Self-sequencing (no boot-mode arg): read the persistence sector first. If it already holds the
// sentinel, this is the second boot -> print PERSIST-OK. Otherwise it is the first boot -> write the
// sentinel -> print PERSIST-WROTE. The harness (tools/fs/blk-persist-test.sh) boots QEMU twice with
// the same -drive file and asserts WROTE then OK. Bare-metal M-mode runtime, like blk_mmode_demo.mc.

import "tests/qemu/lib/test_report.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "kernel/drivers/virtio/virtio_blk.mc";
import "std/addr.mc";

const VIRTIO_ID_BLK: u32 = 2;
const FINISHER: usize = 0x0010_0000; // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;
const PERSIST_SECTOR: u64 = 1; // sector 0 is left to the existing blk-test fixture

// vring memory for the single blk queue (zeroed BSS; the driver lays out the split virtqueue).
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_vq: Virtq;
global g_buf: [512]u8; // one sector of scratch (DMA source/destination)

// The 4-byte sentinel written at the start of the persistence sector ('P','E','R','S').
const S0: u8 = 0x50;
const S1: u8 = 0x45;
const S2: u8 = 0x52;
const S3: u8 = 0x53;

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
    g_vq.desc = &g_desc;
    g_vq.avail = &g_avail;
    g_vq.used = &g_used;
    var dev: BlkDevice = .{ .regs = regs, .vq = &g_vq };
    switch blk_init(&dev) {
        ok(b) => {}
        err(e) => { uputs("BLK-INIT-FAIL\n"); halt(); }
    }

    // Read the persistence sector into g_buf.
    switch blk_read_into(&dev, PERSIST_SECTOR, pa((&g_buf[0]) as usize)) {
        ok(b) => {}
        err(e) => { uputs("BLK-READ-FAIL\n"); halt(); }
    }

    // Second boot? The sentinel is already on disk. (MC has no `&&`; nest the checks.)
    var persisted: bool = false;
    if g_buf[0] == S0 {
        if g_buf[1] == S1 {
            if g_buf[2] == S2 {
                if g_buf[3] == S3 {
                    persisted = true;
                }
            }
        }
    }
    if persisted {
        uputs("PERSIST-OK\n"); // survived a reboot: RAM was cleared, the disk kept the sentinel
        halt();
    }

    // First boot: lay down the sentinel so the next boot finds it.
    g_buf[0] = S0;
    g_buf[1] = S1;
    g_buf[2] = S2;
    g_buf[3] = S3;
    var i: usize = 4;
    while i < 512 {
        g_buf[i] = 0;
        i = i + 1;
    }
    switch blk_write(&dev, PERSIST_SECTOR, pa((&g_buf[0]) as usize)) {
        ok(b) => { uputs("PERSIST-WROTE\n"); }
        err(e) => { uputs("BLK-WRITE-FAIL\n"); }
    }
    halt();
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode; pin `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
