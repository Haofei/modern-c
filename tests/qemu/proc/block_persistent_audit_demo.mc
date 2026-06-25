import "kernel/core/block_persistent_audit.mc";
import "kernel/core/ipc_trace.mc";
import "kernel/fs/blockdev.mc";
import "std/addr.mc";

const DISK_BLOCKS: u64 = 8;
const POLICY_BLOCK: u64 = 1;
const AUDIT_BLOCK_A: u64 = 2;
const AUDIT_BLOCK_B: u64 = 3;

struct Disk { base: usize, n: u64 }

global g_disk: [4096]u8;
global g_disk_h: Disk;
global g_trace: IpcTrace;

impl BlockDevice for Disk {
    fn read(self: *Disk, blk: u64, dst: usize) -> bool {
        if blk >= self.n {
            return false;
        }
        let base: usize = self.base + (blk as usize) * 512;
        var i: usize = 0;
        while i < 512 {
            unsafe {
                let v: u8 = raw.load<u8>(phys(base + i));
                raw.store<u8>(phys(dst + i), v);
            }
            i = i + 1;
        }
        return true;
    }

    fn write(self: *Disk, blk: u64, src: usize) -> bool {
        if blk >= self.n {
            return false;
        }
        let base: usize = self.base + (blk as usize) * 512;
        var i: usize = 0;
        while i < 512 {
            unsafe {
                let v: u8 = raw.load<u8>(phys(src + i));
                raw.store<u8>(phys(base + i), v);
            }
            i = i + 1;
        }
        return true;
    }

    fn blocks(self: *Disk) -> u64 {
        return self.n;
    }
}

fn make_dev() -> *dyn BlockDevice {
    g_disk_h.base = (&g_disk[0]) as usize;
    g_disk_h.n = DISK_BLOCKS;
    return &g_disk_h;
}

export fn block_persistent_audit_run() -> u32 {
    var pass: u32 = 1;
    var dev: *dyn BlockDevice = make_dev();

    switch block_persistent_policy_save(dev, POLICY_BLOCK, 41, 2, 4, 6, 9) {
        ok(v) => {}
        err(e) => { pass = 0; }
    }

    // Remount/reboot simulation: rebuild the trait object over the same disk bytes.
    dev = make_dev();
    switch block_persistent_policy_load(dev, POLICY_BLOCK) {
        ok(p) => {
            if p.policy_version != 41 { pass = 0; }
            if p.throttle_at != 2 { pass = 0; }
            if p.revoke_at != 4 { pass = 0; }
            if p.kill_at != 6 { pass = 0; }
            if p.revocation_epoch != 9 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }

    ipc_trace_init(&g_trace);
    if ipc_trace_record(&g_trace, 7, 1, 0x10, 64) != 0 { pass = 0; }
    if ipc_trace_record(&g_trace, 7, 0, 0x11, 65) != 1 { pass = 0; }
    if ipc_trace_record(&g_trace, 8, 1, 0x12, 66) != 2 { pass = 0; }

    switch block_persistent_audit_capture(&g_trace, dev, AUDIT_BLOCK_A, 41, 1) {
        ok(n) => { if n != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if ipc_trace_len(&g_trace) != 0 { pass = 0; }

    dev = make_dev();
    switch block_persistent_audit_count(dev, AUDIT_BLOCK_A) {
        ok(n) => { if n != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch block_persistent_audit_policy_version(dev, AUDIT_BLOCK_A) {
        ok(v) => { if v != 41 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch block_persistent_audit_boot_epoch(dev, AUDIT_BLOCK_A) {
        ok(v) => { if v != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch block_persistent_audit_trace_dropped(dev, AUDIT_BLOCK_A) {
        ok(v) => { if v != 0 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch block_persistent_audit_get(dev, AUDIT_BLOCK_A, 1) {
        ok(ev) => {
            if ev.seq != 1 { pass = 0; }
            if ev.from != 7 { pass = 0; }
            if ev.to != 0 { pass = 0; }
            if ev.tag != 0x11 { pass = 0; }
            if ev.size != 65 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }

    ipc_trace_init(&g_trace);
    if ipc_trace_record(&g_trace, 9, 0, 0x20, 32) != 0 { pass = 0; }
    switch block_persistent_audit_capture(&g_trace, dev, AUDIT_BLOCK_B, 42, 2) {
        ok(n) => { if n != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }

    dev = make_dev();
    switch block_persistent_policy_load(dev, POLICY_BLOCK) {
        ok(p) => { if p.policy_version != 41 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch block_persistent_audit_boot_epoch(dev, AUDIT_BLOCK_B) {
        ok(v) => { if v != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch block_persistent_audit_get(dev, AUDIT_BLOCK_B, 0) {
        ok(ev) => {
            if ev.from != 9 { pass = 0; }
            if ev.tag != 0x20 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }
    switch block_persistent_audit_get(dev, AUDIT_BLOCK_B, 1) {
        ok(ev) => { pass = 0; }
        err(e) => {
            switch e {
                .OutOfRange => {}
                _ => { pass = 0; }
            }
        }
    }

    // The policy block was written to the raw backing store, not just to an in-memory index.
    if g_disk[(POLICY_BLOCK as usize) * 512] == 0 { pass = 0; }
    if g_disk[(AUDIT_BLOCK_A as usize) * 512] == 0 { pass = 0; }
    return pass;
}
