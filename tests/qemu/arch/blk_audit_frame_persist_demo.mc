// Durable AUDIT-FRAME persistence proof (production-readiness §3.1 #3): the policy snapshot already
// persists (blk_audit_persist_demo.mc); this fixture proves the remaining piece — the drained
// AUDIT FRAME (a snapshot of IpcTrace provenance records) also survives a real reboot through
// virtio-blk. On the FIRST boot, record a few KNOWN IPC provenance events into an IpcTrace, drain
// them into a block-backed audit frame and checkpoint it to disk. A SECOND boot (fresh kernel +
// cleared RAM, SAME disk image) LOADS the frame back and field-verifies every recorded event
// (count, seq, from/to/tag/size) plus the frame metadata (policy_version, boot_epoch).
//
// This exercises the real production path end-to-end: the generic BlockDevice trait
// (kernel/fs/blockdev.mc) over the virtio-blk adapter (impl BlockDevice for BlkDevice in kernel/drivers/virtio/virtio_blk.mc)
// driving the block-backed audit-frame API (kernel/core/block_persistent_audit.mc:
// block_persistent_audit_capture / _count / _get / _policy_version / _boot_epoch), draining a
// real kernel/core/ipc_trace.mc IpcTrace.
//
// Self-sequencing (no boot-mode arg): try to LOAD the audit frame first. If it loads and every
// field matches, this is the second boot -> print AUDIT-FRAME-OK. Otherwise (a fresh/zeroed disk
// fails the magic check) this is the first boot -> record + SAVE the frame -> print
// AUDIT-FRAME-WROTE. The harness (tools/fs/blk-audit-frame-persist-test.sh) boots QEMU twice with
// the same -drive file and asserts WROTE then OK. Bare-metal M-mode runtime, like blk_persist_demo.mc.

import "tests/qemu/lib/test_report.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "kernel/drivers/virtio/virtio_blk.mc";
import "kernel/core/block_persistent_audit.mc";
import "kernel/core/ipc_trace.mc";
import "kernel/fs/blockdev.mc";
import "std/addr.mc";

const VIRTIO_ID_BLK: u32 = 2;
const FINISHER: usize = 0x0010_0000; // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;

// The block that holds the durable audit FRAME (sector 0 left for other fixtures; the policy demo
// uses sector 1, so this uses sector 2 to stay independent even on a shared image).
const AUDIT_BLOCK: u64 = 2;

// Frame metadata persisted on boot 1 and re-verified on boot 2.
const POLICY_VERSION: u64 = 0x5151;
const BOOT_EPOCH: u64 = 0x7777;

// The three KNOWN IPC provenance events we record into the trace on boot 1. Each row is
// (from, to, tag, size); seq is assigned 0,1,2 in record order.
const EV_COUNT: usize = 3;
const E0_FROM: u32 = 1;  const E0_TO: u32 = 2;  const E0_TAG: u32 = 0x11;  const E0_SIZE: u32 = 100;
const E1_FROM: u32 = 3;  const E1_TO: u32 = 4;  const E1_TAG: u32 = 0x22;  const E1_SIZE: u32 = 200;
const E2_FROM: u32 = 5;  const E2_TO: u32 = 6;  const E2_TAG: u32 = 0x33;  const E2_SIZE: u32 = 300;

// vring memory for the single blk queue (zeroed BSS; the driver lays out the split virtqueue).
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_vq: Virtq;

// The provenance ring we record into and drain on boot 1.
global g_trace: IpcTrace;

fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

// Verify one persisted event against its expected fields; returns true on full match.
fn check_event(dev: *dyn BlockDevice, i: usize, eseq: u64, efrom: u32, eto: u32, etag: u32, esize: u32) -> bool {
    switch block_persistent_audit_get(dev, AUDIT_BLOCK, i) {
        ok(ev) => {
            var ok2: bool = true;
            if ev.seq != eseq { ok2 = false; }
            if ev.from != efrom { ok2 = false; }
            if ev.to != eto { ok2 = false; }
            if ev.tag != etag { ok2 = false; }
            if ev.size != esize { ok2 = false; }
            return ok2;
        }
        err(e) => { return false; }
    }
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

    // Second boot? Try to load the durable audit frame and field-verify every record.
    switch block_persistent_audit_count(&dev, AUDIT_BLOCK) {
        ok(n) => {
            // MC has no `&&`; accumulate the match into a single bool.
            var good: bool = true;
            if n != EV_COUNT { good = false; }
            switch block_persistent_audit_policy_version(&dev, AUDIT_BLOCK) {
                ok(pv) => { if pv != POLICY_VERSION { good = false; } }
                err(e) => { good = false; }
            }
            switch block_persistent_audit_boot_epoch(&dev, AUDIT_BLOCK) {
                ok(be) => { if be != BOOT_EPOCH { good = false; } }
                err(e) => { good = false; }
            }
            if !check_event(&dev, 0, 0, E0_FROM, E0_TO, E0_TAG, E0_SIZE) { good = false; }
            if !check_event(&dev, 1, 1, E1_FROM, E1_TO, E1_TAG, E1_SIZE) { good = false; }
            if !check_event(&dev, 2, 2, E2_FROM, E2_TO, E2_TAG, E2_SIZE) { good = false; }
            if good {
                uputs("AUDIT-FRAME-OK\n"); // provenance frame survived a reboot: RAM cleared, disk kept it
            } else {
                uputs("AUDIT-FRAME-MISMATCH\n");
            }
            halt();
        }
        err(e) => {} // fresh/zeroed disk fails the magic check -> first boot, fall through to record+save
    }

    // First boot: record the known provenance events, then drain them into a durable audit frame.
    ipc_trace_init(&g_trace);
    let s0: u64 = ipc_trace_record(&g_trace, E0_FROM, E0_TO, E0_TAG, E0_SIZE);
    let s1: u64 = ipc_trace_record(&g_trace, E1_FROM, E1_TO, E1_TAG, E1_SIZE);
    let s2: u64 = ipc_trace_record(&g_trace, E2_FROM, E2_TO, E2_TAG, E2_SIZE);

    switch block_persistent_audit_capture(&g_trace, &dev, AUDIT_BLOCK, POLICY_VERSION, BOOT_EPOCH) {
        ok(c) => {
            if c == EV_COUNT {
                uputs("AUDIT-FRAME-WROTE\n");
            } else {
                uputs("AUDIT-FRAME-COUNT-FAIL\n");
            }
        }
        err(e) => { uputs("AUDIT-FRAME-SAVE-FAIL\n"); }
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
