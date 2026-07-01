// INSTRUMENTED PROCESS TABLE — ledger + metrics + supervision-tree/leases, end-to-end under QEMU.
//
// This is the ONE integration gate for the three polish items wired onto the shared process core:
//
//   (A) UNIFIED LEDGER  — real hot ops route charges/releases through t.ledger:
//         * IPC send charges IpcMessages (released on receive); an over-limit send is REFUSED
//           cleanly (returns false, no trap) and, after draining, freed headroom lets a send
//           succeed again.
//         * block I/O (proc_blk_read/_write over a RAM-disk BlockDevice) charges BlockIo per op;
//           an over-limit op returns err(.IoError) WITHOUT touching the device (the ledger gates
//           real I/O), never a trap.
//         * DMA (proc_dma_charge) charges DmaBytes at the alloc seam; over-limit returns false.
//     -> prints LEDGER-WIRED-OK
//
//   (B) METRICS         — a single metrics_inc at each hot-path site gives exact counters:
//         ProcSpawn (spawns), IpcSend/IpcRecv (successful sends/receives), BlkRead/BlkWrite
//         (successful block ops), SchedPreempt (a quantum-expiry edge via proc_preempt_tick).
//     -> prints METRICS-WIRED-OK
//
//   (C) SUPERVISION TREE + LEASES — proc_supervisor_scan over a real tree:
//         a crash-looping PARENT that exhausts its restart budget is given up, and the give-up
//         CASCADES to its child and grandchild (multi-level, non-recursive) while an UNRELATED
//         supervised slot survives; and an EXPIRED LEASE drives the same restart action a missed
//         heartbeat would.
//     -> prints SUPTREE-OK
//
// INSTRUMENT-OK is printed only if all three held. No context switches occur (spawned stacks are
// placeholders): the demo drives table state directly, like proc_supervisor_demo / ledger_demo.

import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";
import "kernel/core/proc_blk.mc";
import "kernel/fs/blockdev.mc";
import "std/addr.mc";
import "tests/qemu/lib/test_report.mc";

global g_t: ProcTable;
fn worker() -> void {}

// ----- a RAM-disk BlockDevice (same vtable virtio-blk would supply), for real block I/O -----
const DISK_BLOCKS: u64 = 8; // 8 * 512 = 4096 bytes
struct Disk { base: usize, n: u64 }
global g_disk: [4096]u8;
global g_disk_h: Disk;
global g_src: [512]u8;
global g_dst: [512]u8;

impl BlockDevice for Disk {
    fn read(self: *Disk, blk: u64, dst: usize) -> bool {
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

// true iff proc_blk_read succeeded.
fn blk_read_ok(dev: *dyn BlockDevice, blk: u64, dst: usize) -> bool {
    switch proc_blk_read(&g_t, dev, blk, dst) {
        ok(v) => { return true; }
        err(e) => { return false; }
    }
}
// true iff proc_blk_write succeeded.
fn blk_write_ok(dev: *dyn BlockDevice, blk: u64, src: usize) -> bool {
    switch proc_blk_write(&g_t, dev, blk, src) {
        ok(v) => { return true; }
        err(e) => { return false; }
    }
}

// ===== (A) ledger wiring + (B) metrics wiring (share the same run of real ops) =====
// Returns 1 if both the ledger properties and the exact metric counters hold; sets *met to 1 iff
// the metric counters were exact (so the caller can print METRICS-WIRED-OK independently).
fn run_ledger_metrics(met: *mut u32) -> u32 {
    var led: u32 = 1;
    proc_table_init(&g_t);
    let p1: u32 = proc_spawn(&g_t, 0x1000, worker);
    let p2: u32 = proc_spawn(&g_t, 0x2000, worker);
    let p3: u32 = proc_spawn(&g_t, 0x3000, worker);
    if p1 != 1 { led = 0; }
    if p2 != 2 { led = 0; }
    if p3 != 3 { led = 0; }

    // ----- IPC: charge on send, gate at the ceiling, release on receive -----
    ledger_set_limit(&g_t.ledger, .IpcMessages, 2); // ceiling: 2 in-flight IPC messages
    g_t.current = 0; // send as the bootstrap
    if !ipc_send_try(&g_t, 1, 100, 0, 0, 0) { led = 0; } // charge -> used 1
    if !ipc_send_try(&g_t, 1, 101, 0, 0, 0) { led = 0; } // charge -> used 2
    if ledger_used(&g_t.ledger, .IpcMessages) != 2 { led = 0; }
    // 3rd send is OVER the ledger ceiling: refused cleanly (false), used unchanged, NOT trapped.
    if ipc_send_try(&g_t, 1, 102, 0, 0, 0) { led = 0; }  // must fail
    if ledger_used(&g_t.ledger, .IpcMessages) != 2 { led = 0; } // unchanged after refusal

    // Drain p1's inbox: each receive RELEASES one charge (used 2 -> 0).
    var m: Message = .{ .from = 0, .from_gen = 0, .call_id = 0, .tag = 0, .a0 = 0, .a1 = 0, .a2 = 0 };
    g_t.current = 1;
    ipc_receive(&g_t, &m); // release -> used 1
    ipc_receive(&g_t, &m); // release -> used 0
    if ledger_used(&g_t.ledger, .IpcMessages) != 0 { led = 0; }
    // Freed headroom lets a send succeed again (release really returned capacity).
    g_t.current = 0;
    if !ipc_send_try(&g_t, 1, 103, 0, 0, 0) { led = 0; } // charge -> used 1
    if ledger_used(&g_t.ledger, .IpcMessages) != 1 { led = 0; }
    g_t.current = 1;
    ipc_receive(&g_t, &m); // release -> used 0
    if ledger_used(&g_t.ledger, .IpcMessages) != 0 { led = 0; }
    // Totals: 3 successful sends (100/101/103), 3 receives.

    // ----- block I/O: charge per op, gate at the ceiling without touching the device -----
    g_t.current = 0;
    let dev: *dyn BlockDevice = make_dev();
    let src: usize = (&g_src[0]) as usize;
    let dst: usize = (&g_dst[0]) as usize;
    ledger_set_limit(&g_t.ledger, .BlockIo, 3); // ceiling: 3 block ops
    if !blk_write_ok(dev, 0, src) { led = 0; } // BlockIo used 1
    if !blk_write_ok(dev, 1, src) { led = 0; } // BlockIo used 2
    if !blk_read_ok(dev, 0, dst) { led = 0; }  // BlockIo used 3
    if ledger_used(&g_t.ledger, .BlockIo) != 3 { led = 0; }
    // 4th op is OVER the ceiling: err(.IoError), device untouched, used unchanged, NOT trapped.
    if blk_read_ok(dev, 1, dst) { led = 0; }   // must fail
    if ledger_used(&g_t.ledger, .BlockIo) != 3 { led = 0; }
    // Totals: 2 successful writes, 1 successful read.

    // ----- DMA: charge at the alloc seam, gate at the ceiling -----
    ledger_set_limit(&g_t.ledger, .DmaBytes, 4096);
    if !proc_dma_charge(&g_t, 3000) { led = 0; }        // within limit
    if ledger_used(&g_t.ledger, .DmaBytes) != 3000 { led = 0; }
    if proc_dma_charge(&g_t, 2000) { led = 0; }         // 3000+2000 > 4096 -> refused (no trap)
    if ledger_used(&g_t.ledger, .DmaBytes) != 3000 { led = 0; } // unchanged
    proc_dma_release(&g_t, 3000);
    if ledger_used(&g_t.ledger, .DmaBytes) != 0 { led = 0; }

    // ----- SchedPreempt metric: a quantum-expiry edge (no context switch) -----
    g_t.current = 0;
    g_t.procs[0].quantum = 1;
    if !proc_preempt_tick(&g_t) { led = 0; } // 1 -> 0 expiry edge -> SchedPreempt++

    // ----- (B) exact metric counters -----
    var mp: u32 = 1;
    if metrics_get(&g_t.metrics, .ProcSpawn) != 3 { mp = 0; }
    if metrics_get(&g_t.metrics, .IpcSend) != 3 { mp = 0; }
    if metrics_get(&g_t.metrics, .IpcRecv) != 3 { mp = 0; }
    if metrics_get(&g_t.metrics, .BlkWrite) != 2 { mp = 0; }
    if metrics_get(&g_t.metrics, .BlkRead) != 1 { mp = 0; }
    if metrics_get(&g_t.metrics, .SchedPreempt) != 1 { mp = 0; }
    met.* = mp;

    return led;
}

// ===== (C) supervision tree + leases =====
fn run_suptree() -> u32 {
    var sup: u32 = 1;
    let INTERVAL: u64 = 10;
    let MAXR: u32 = 2;
    proc_table_init(&g_t); // fresh table (clears ledger/metrics too — not checked in this section)
    let a1: u32 = proc_spawn(&g_t, 0x1000, worker); // slot 1: crash-looping PARENT
    let a2: u32 = proc_spawn(&g_t, 0x2000, worker); // slot 2: healthy CHILD of 1
    let a3: u32 = proc_spawn(&g_t, 0x3000, worker); // slot 3: healthy GRANDCHILD (child of 2)
    let a4: u32 = proc_spawn(&g_t, 0x4000, worker); // slot 4: UNRELATED healthy supervised slot
    let a5: u32 = proc_spawn(&g_t, 0x5000, worker); // slot 5: LEASE-only supervised slot
    if a1 != 1 { sup = 0; }
    if a5 != 5 { sup = 0; }

    // Enroll heartbeat supervision on 1..4; register the tree links (2<-1, 3<-2). 4 is unlinked.
    proc_supervise(&g_t, 1, 0, INTERVAL);
    proc_supervise(&g_t, 2, 0, INTERVAL);
    proc_supervise(&g_t, 3, 0, INTERVAL);
    proc_supervise(&g_t, 4, 0, INTERVAL);
    proc_supervise_child(&g_t, 2, 1);
    proc_supervise_child(&g_t, 3, 2);
    if proc_supervise_parent(&g_t, 2) != 1 { sup = 0; }
    if proc_supervise_parent(&g_t, 3) != 2 { sup = 0; }
    if proc_supervise_parent(&g_t, 4) != MAX_PROCS { sup = 0; }

    // Scan A @15: parent missed (restart #1); children + unrelated beat -> None.
    proc_heartbeat(&g_t, 2, 15);
    proc_heartbeat(&g_t, 3, 15);
    proc_heartbeat(&g_t, 4, 15);
    let ra: u32 = proc_supervisor_scan(&g_t, 15, MAXR);
    if proc_supervisor_scan_restarts(ra) != 1 { sup = 0; }
    if proc_supervisor_scan_giveups(ra) != 0 { sup = 0; }

    // Scan B @30: parent missed again (restart #2); others healthy.
    proc_heartbeat(&g_t, 2, 30);
    proc_heartbeat(&g_t, 3, 30);
    proc_heartbeat(&g_t, 4, 30);
    let rb: u32 = proc_supervisor_scan(&g_t, 30, MAXR);
    if proc_supervisor_scan_restarts(rb) != 1 { sup = 0; }
    if proc_supervisor_scan_giveups(rb) != 0 { sup = 0; }

    // Scan C @45: parent exceeds budget -> GiveUp, CASCADING to child(2) + grandchild(3), while
    // the unrelated slot(4) survives. Give-ups: parent + child + grandchild = 3.
    proc_heartbeat(&g_t, 2, 45);
    proc_heartbeat(&g_t, 3, 45);
    proc_heartbeat(&g_t, 4, 45);
    let rc: u32 = proc_supervisor_scan(&g_t, 45, MAXR);
    if proc_supervisor_scan_restarts(rc) != 0 { sup = 0; }
    if proc_supervisor_scan_giveups(rc) != 3 { sup = 0; } // 1 + cascaded 2,3
    // child + grandchild are now unsupervised (never flagged again); unrelated slot still is.
    if proc_liveness_expired(&g_t, 2, 100000) { sup = 0; } // 2 unsupervised -> never expired
    if proc_liveness_expired(&g_t, 3, 100000) { sup = 0; } // 3 unsupervised -> never expired
    if !proc_liveness_expired(&g_t, 4, 100000) { sup = 0; } // 4 STILL supervised -> would expire

    // ----- LEASE: slot 5 is lease-only (no heartbeat); an expired lease drives the same action -----
    proc_lease_grant(&g_t, 5, 100, 10); // valid through tick 110
    if !proc_lease_valid(&g_t, 5, 105) { sup = 0; }  // valid before expiry
    if proc_lease_valid(&g_t, 5, 115) { sup = 0; }   // expired after
    // Scan @120: slot 5's lease has expired -> Restart (count 0 < budget); keep slot 4 alive so it
    // stays None and does not perturb the counts.
    proc_heartbeat(&g_t, 4, 120);
    let rd: u32 = proc_supervisor_scan(&g_t, 120, MAXR);
    if proc_supervisor_scan_restarts(rd) != 1 { sup = 0; } // only slot 5 (lease-expiry action)
    if proc_supervisor_scan_giveups(rd) != 0 { sup = 0; }
    // The restart re-armed slot 5's lease (fresh ttl from now) -> valid again.
    if !proc_lease_valid(&g_t, 5, 125) { sup = 0; }

    return sup;
}

export fn instrument_run() -> u32 {
    var pass: u32 = 1;

    var met: u32 = 0;
    let led: u32 = run_ledger_metrics(&met);
    if led == 1 { uputs("LEDGER-WIRED-OK\n"); } else { pass = 0; }
    if met == 1 { uputs("METRICS-WIRED-OK\n"); } else { pass = 0; }

    let sup: u32 = run_suptree();
    if sup == 1 { uputs("SUPTREE-OK\n"); } else { pass = 0; }

    return pass;
}
