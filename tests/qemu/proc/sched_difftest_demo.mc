// Differential scheduler gate (Phase 2.2 re-land condition). Drives a ProcTable through many
// randomized-but-deterministic runnability transitions and, after EACH transition, asserts that
// the scheduler's round-robin pick (proc_next_runnable_probe -> next_runnable) equals an
// INDEPENDENT authoritative round-robin scan recomputed from the public proc_state_code.
//
// This is the test that must exist for the O(children) supervisor-cascade re-land: an earlier
// attempt (reverted commit 0c5df7f) cached runnability in a `run_mask` bit-set that went STALE on
// transitions not routed through its refresh hook — most notably the DIRECT `state = .Zombie` /
// `state = .Unused` pokes that endpoint_demo performs (mirrored here as ops 3 and 7) and the
// death-cleanup-with-blocked-waiter shape (op 6). next_runnable then picked a slot the mask said
// was runnable but the authoritative state said was not. This gate reproduces exactly that class:
// it FAILS against the stale-cache version and PASSES against the authoritative scan.
//
// No context switch is exercised (proc_exit/proc_yield are avoided): every op mutates only the
// runnability state (block reasons / process state), and the pick is compared, never taken.

import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";

global g_t: ProcTable;
fn worker() -> void {}

// Deterministic LCG (Numerical Recipes constants), computed in u64 then truncated so the checked
// 32-bit overflow trap never fires — this is a PRNG where wraparound is intended.
fn lcg(s: u32) -> u32 {
    let m: u64 = (((s as u64) * 1664525) + 1013904223) & 0x0000_0000_FFFF_FFFF;
    return m as u32;
}

// INDEPENDENT reimplementation of the round-robin pick, derived purely from the PUBLIC
// proc_state_code (0=Unused 1=Ready 2=Running 3=Blocked 4=Zombie 5=Dead). Runnable == Ready or
// Running with no block reasons == code 1 or 2. Returns MAX_PROCS for "nothing runnable". This
// shares NO state with next_runnable's internals, so agreement is a real cross-check.
fn indep_pick(t: *mut ProcTable, from: usize) -> usize {
    var i: usize = 1;
    while i < MAX_PROCS {
        let idx: usize = (from + i) % MAX_PROCS;
        if idx < proc_count(t) {
            let sc: u32 = proc_state_code(t, idx);
            if sc == 1 {
                return idx;
            }
            if sc == 2 {
                return idx;
            }
        }
        i = i + 1;
    }
    return MAX_PROCS;
}

// After every transition, the scheduler pick must equal the independent scan for EVERY `from`.
// Returns true on full agreement.
fn check_all(t: *mut ProcTable) -> bool {
    var from: usize = 0;
    while from < MAX_PROCS {
        if proc_next_runnable_probe(t, from) != indep_pick(t, from) {
            return false;
        }
        from = from + 1;
    }
    return true;
}

// A live, non-bootstrap slot in 1..MAX_PROCS-1 selected from the RNG, or MAX_PROCS if none.
fn pick_live(t: *mut ProcTable, r: u32) -> usize {
    var off: usize = 0;
    while off < MAX_PROCS {
        let slot: usize = 1 + (((r as usize) + off) % (MAX_PROCS - 1));
        if slot < proc_count(t) {
            let sc: u32 = proc_state_code(t, slot);
            if sc != 0 { // not Unused
                if sc != 4 { // not Zombie
                    return slot;
                }
            }
        }
        off = off + 1;
    }
    return MAX_PROCS;
}

// A Zombie slot in 1..MAX_PROCS-1, or MAX_PROCS if none.
fn pick_zombie(t: *mut ProcTable, r: u32) -> usize {
    var off: usize = 0;
    while off < MAX_PROCS {
        let slot: usize = 1 + (((r as usize) + off) % (MAX_PROCS - 1));
        if slot < proc_count(t) {
            if proc_state_code(t, slot) == 4 {
                return slot;
            }
        }
        off = off + 1;
    }
    return MAX_PROCS;
}

export fn sched_difftest_run() -> u32 {
    proc_table_init(&g_t);
    g_t.current = 0; // bootstrap owns the CPU; kept runnable throughout so a pick always exists

    // Seed the table with a few workers (children of slot 0).
    var w: u32 = 0;
    while w < 4 {
        proc_spawn(&g_t, 0x1000, worker);
        w = w + 1;
    }
    if !check_all(&g_t) {
        return 0;
    }

    var seed: u32 = 0x1234_5678;
    var iter: u32 = 0;
    while iter < 4000 {
        seed = lcg(seed);
        let op: u32 = seed % 8;
        seed = lcg(seed);
        let r: u32 = seed;

        if op == 0 {
            // spawn: reuse an Unused slot or grow (children of the bootstrap, slot 0). Guard the
            // grow so proc_spawn never hits its table-full `unreachable`.
            var can_spawn: bool = proc_count(&g_t) < MAX_PROCS;
            if !can_spawn {
                var s: usize = 1;
                while s < proc_count(&g_t) {
                    if proc_state_code(&g_t, s) == 0 { // an Unused slot is reusable
                        can_spawn = true;
                    }
                    s = s + 1;
                }
            }
            if can_spawn {
                proc_spawn(&g_t, 0x1000, worker);
            }
        } else if op == 1 {
            let slot: usize = pick_live(&g_t, r);
            if slot < MAX_PROCS {
                proc_block(&g_t, slot, BLOCK_RECV); // may become non-runnable
            }
        } else if op == 2 {
            let slot: usize = pick_live(&g_t, r);
            if slot < MAX_PROCS {
                proc_unblock(&g_t, slot, BLOCK_RECV); // may become runnable again
            }
        } else if op == 3 {
            // DIRECT state poke to Zombie (bypasses every setter) — the endpoint_demo shape that
            // made the reverted run_mask cache go stale.
            let slot: usize = pick_live(&g_t, r);
            if slot < MAX_PROCS {
                g_t.procs[slot].state = .Zombie;
            }
        } else if op == 4 {
            // reap a zombie child of the bootstrap: Zombie -> Unused.
            switch proc_reap(&g_t, 0) {
                ok(info) => {}
                err(e) => {}
            }
        } else if op == 5 {
            // fault-kill a live slot: death cleanup + Zombie (an instrumented transition).
            let slot: usize = pick_live(&g_t, r);
            if slot < MAX_PROCS {
                proc_fault_kill(&g_t, slot);
            }
        } else if op == 6 {
            // death-cleanup-with-blocked-waiter: waiter A blocks receiving-from victim B, then B is
            // fault-killed; death cleanup must wake A (clearing its BLOCK_RECV) so the pick sees A
            // runnable again. The exact endpoint-test failure shape.
            let a: usize = pick_live(&g_t, r);
            let b: usize = pick_live(&g_t, lcg(r));
            if a < MAX_PROCS {
                if b < MAX_PROCS {
                    if a != b {
                        g_t.procs[a].wait_slot = b;
                        g_t.procs[a].wait_gen = g_t.procs[b].gen;
                        proc_block(&g_t, a, BLOCK_RECV);
                        if !check_all(&g_t) {
                            return 0;
                        }
                        proc_fault_kill(&g_t, b);
                    }
                }
            }
        } else {
            // DIRECT Zombie -> Unused poke (bypasses proc_reap) — endpoint_demo line 67 shape.
            let slot: usize = pick_zombie(&g_t, r);
            if slot < MAX_PROCS {
                g_t.procs[slot].state = .Unused;
            }
        }

        if !check_all(&g_t) {
            return 0;
        }
        iter = iter + 1;
    }
    return 1; // every transition kept the pick in agreement with the authoritative scan
}
