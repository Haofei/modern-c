// Durable policy/audit persistence proof (production-readiness §3.1 #3): checkpoint a
// block_persistent_audit POLICY snapshot to a virtio-blk disk on the FIRST boot, then a SECOND
// boot (fresh kernel + cleared RAM, SAME disk image) LOADS it back and verifies every field —
// proving the capability policy/audit state survives a real reboot through durable storage, not
// just an in-RAM roundtrip.
//
// This exercises the real production path end-to-end: the generic BlockDevice trait
// (kernel/fs/blockdev.mc) over the virtio-blk adapter (kernel/drivers/virtio/virtio_blk_blockdev.mc)
// driving the block-backed checkpoint API (kernel/core/block_persistent_audit.mc).
//
// Self-sequencing (no boot-mode arg): try to LOAD the policy snapshot first. If it loads and the
// fields match, this is the second boot -> print AUDIT-PERSIST-OK. Otherwise (a fresh/zeroed disk
// fails the magic check) this is the first boot -> SAVE the checkpoint -> print AUDIT-PERSIST-WROTE.
// The harness (tools/fs/blk-audit-persist-test.sh) boots QEMU twice with the same -drive file and
// asserts WROTE then OK. Bare-metal M-mode runtime, like blk_persist_demo.mc.

import "tests/qemu/lib/test_report.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "kernel/drivers/virtio/virtio_blk.mc";
import "kernel/drivers/virtio/virtio_blk_blockdev.mc";
import "kernel/core/block_persistent_audit.mc";
import "kernel/fs/blockdev.mc";
import "std/addr.mc";

const VIRTIO_ID_BLK: u32 = 2;
const FINISHER: usize = 0x0010_0000; // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;

// The block that holds the durable policy checkpoint (sector 0 left for other fixtures).
const POLICY_BLOCK: u64 = 1;

// The policy snapshot we persist on boot 1 and re-verify on boot 2.
const POLICY_VERSION: u64 = 0xC0DE;
const THROTTLE_AT: u32 = 11;
const REVOKE_AT: u32 = 22;
const KILL_AT: u32 = 33;
const REVOCATION_EPOCH: u64 = 0xABCD;

// vring memory for the single blk queue (zeroed BSS; the driver lays out the split virtqueue).
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_vq: Virtq;

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

    // Second boot? Try to load the durable policy checkpoint and verify every field.
    switch block_persistent_policy_load(&dev, POLICY_BLOCK) {
        ok(p) => {
            // MC has no `&&`; accumulate the match into a single bool.
            var good: bool = true;
            if p.policy_version != POLICY_VERSION { good = false; }
            if p.throttle_at != THROTTLE_AT { good = false; }
            if p.revoke_at != REVOKE_AT { good = false; }
            if p.kill_at != KILL_AT { good = false; }
            if p.revocation_epoch != REVOCATION_EPOCH { good = false; }
            if good {
                uputs("AUDIT-PERSIST-OK\n"); // policy survived a reboot: RAM cleared, disk kept it
            } else {
                uputs("AUDIT-PERSIST-MISMATCH\n");
            }
            halt();
        }
        err(e) => {} // fresh/zeroed disk fails the magic check -> first boot, fall through to save
    }

    // First boot: lay down the policy checkpoint so the next boot finds it.
    switch block_persistent_policy_save(&dev, POLICY_BLOCK, POLICY_VERSION, THROTTLE_AT, REVOKE_AT, KILL_AT, REVOCATION_EPOCH) {
        ok(v) => { uputs("AUDIT-PERSIST-WROTE\n"); }
        err(e) => { uputs("AUDIT-PERSIST-SAVE-FAIL\n"); }
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
