// kernel/core/proc_sched — scheduling policy and mechanism on top of the process
// table: run-queue selection (round-robin and priority), the proc_yield* family,
// timer ticks / quantum accounting, block/unblock/park/wake, and schedctl. The
// process table (ProcTable/Process), the shared liveness helpers (is_runnable),
// and the platform idle hook live in kernel/core/process.mc; this module builds
// scheduling on top of them. Split out of process.mc verbatim (pure move).

import "kernel/arch/riscv64/context.mc";
import "std/mask.mc";
import "kernel/core/process.mc";

enum SchedError {
    NoRunnable, // no process other than `from` is runnable
}

// The next runnable slot after `from` (round-robin), or NoRunnable if none other is
// runnable — an explicit result so callers handle "nothing to run" rather than receiving
// `from` back and having to special-case it.
fn next_runnable(t: *mut ProcTable, from: usize) -> Result<usize, SchedError> {
    // Scan the other slots round-robin (i in 1..MAX_PROCS-1, so idx never wraps back to
    // `from`); `from` itself is never returned, so a lone runnable current process yields
    // NoRunnable rather than "switch to yourself".
    var i: usize = 1;
    while i < MAX_PROCS {
        let idx: usize = (from + i) % MAX_PROCS;
        if idx < t.count {
            if is_runnable(t, idx) {
                return ok(idx);
            }
        }
        i = i + 1;
    }
    return err(.NoRunnable);
}

// ----- userspace-set scheduling policy. The kernel keeps the *mechanism* (context
// switch); the *policy* (per-process priority) is set from outside — a scheduler server
// — and the kernel just runs the highest-priority runnable process. -----

// Set a process's scheduling priority (the policy decision; higher runs first).
export fn proc_set_priority(t: *mut ProcTable, pid: u32, prio: u32) -> void {
    let p: usize = pid as usize;
    if p < t.count {
        t.procs[p].priority = prio;
    }
}

// schedctl: the single sanctioned path for setting scheduling policy (priority, quantum, and
// the scheduler endpoint to notify on expiry). The kernel owns the mechanism (run queues,
// context switch); policy is set here by the scheduler service, not poked field-by-field by
// arbitrary code — so accounting and quantum stay consistent.
export fn proc_schedctl(t: *mut ProcTable, pid: u32, prio: u32, quantum: u32, sched_endpoint: u32) -> void {
    let p: usize = pid as usize;
    if p < t.count {
        t.procs[p].priority = prio;
        t.procs[p].quantum = quantum;
        t.procs[p].sched_endpoint = sched_endpoint;
    }
}

// Account one timer tick to the current process; returns true if its quantum just expired
// (the kernel marks it out-of-time and the timer path notifies its scheduler endpoint to
// pick the next process / refresh the quantum — policy stays in the scheduler service).
export fn proc_tick(t: *mut ProcTable) -> bool {
    let cur: usize = t.current;
    t.procs[cur].ticks = t.procs[cur].ticks + 1;
    if t.procs[cur].quantum == 0 {
        return false; // already expired — edge-triggered, so do not re-notify the scheduler
    }
    t.procs[cur].quantum = t.procs[cur].quantum - 1;
    return t.procs[cur].quantum == 0; // true only on the 1 -> 0 transition (quantum just expired)
}

export fn proc_quantum(t: *mut ProcTable, pid: u32) -> u32 {
    let p: usize = pid as usize;
    if p < t.count {
        return t.procs[p].quantum;
    }
    return 0;
}
export fn proc_ticks(t: *mut ProcTable, pid: u32) -> u32 {
    let p: usize = pid as usize;
    if p < t.count {
        return t.procs[p].ticks;
    }
    return 0;
}
export fn proc_sched_endpoint(t: *mut ProcTable, pid: u32) -> u32 {
    let p: usize = pid as usize;
    if p < t.count {
        return t.procs[p].sched_endpoint;
    }
    return 0;
}

// Refresh a process's quantum (the scheduler service's policy action after an expiry).
export fn proc_refresh_quantum(t: *mut ProcTable, pid: u32, quantum: u32) -> void {
    let p: usize = pid as usize;
    if p < t.count {
        t.procs[p].quantum = quantum;
    }
}

// Timer hook: account a tick to the current process and, when its quantum just expired (edge-
// triggered), notify its scheduler service (TAG_QUANTUM, from = the expired process) so the
// scheduler can apply policy — refresh the quantum, demote/boost, reassign CPU. The kernel
// keeps the mechanism (accounting + the edge); the *policy* lives in the scheduler service.
// Returns true on the expiry edge.
export fn proc_tick_notify(t: *mut ProcTable) -> bool {
    let expired: bool = proc_tick(t);
    if expired {
        let sched: u32 = t.procs[t.current].sched_endpoint;
        if sched != 0 { // 0 = no scheduler service assigned
            ipc_notify(t, sched, TAG_QUANTUM); // fire-and-forget expiry notification
        }
    }
    return expired;
}

// Policy: the highest-priority runnable process other than `from` (ties: lowest pid),
// or `from` if no other is runnable.
fn sched_next_priority(t: *mut ProcTable, from: usize) -> usize {
    var best: usize = from;
    var best_prio: u32 = 0;
    var found: bool = false;
    var i: usize = 0;
    while i < t.count {
        if i != from {
            if is_runnable(t, i) {
                let p: u32 = t.procs[i].priority;
                if !found {
                    best = i;
                    best_prio = p;
                    found = true;
                } else {
                    if p > best_prio {
                        best = i;
                        best_prio = p;
                    }
                }
            }
        }
        i = i + 1;
    }
    return best;
}

// Add a block reason: the process becomes non-runnable until every reason clears. The single
// owner of "stop running this process" — the scheduler derives runnability, so no caller
// hand-edits a state field and risks leaving the process wrongly (un)scheduled.
export fn proc_block(t: *mut ProcTable, slot: usize, reason: u32) -> void {
    if slot < t.count {
        mask32_set(&t.procs[slot].block_reasons, reason);
    }
}

// Clear a block reason; the process is runnable again once no reasons remain.
export fn proc_unblock(t: *mut ProcTable, slot: usize, reason: u32) -> void {
    if slot < t.count {
        mask32_clear(&t.procs[slot].block_reasons, reason);
    }
}

// Park the current process (generic block): non-runnable until woken.
export fn proc_park(t: *mut ProcTable) -> void {
    proc_block(t, t.current, BLOCK_RECV);
}

// Wake process `pid`: clear its receive-block so it can run again. No-op otherwise.
export fn proc_wake(t: *mut ProcTable, pid: u32) -> void {
    proc_unblock(t, pid as usize, BLOCK_RECV);
}

// Yield, choosing the next process by the priority policy instead of round-robin.
export fn proc_yield_priority(t: *mut ProcTable) -> void {
    let from: usize = t.current;
    let to: usize = sched_next_priority(t, from);
    if to == from {
        return;
    }
    let from_state: ProcState = t.procs[from].state;
    if from_state == .Running {
        t.procs[from].state = .Ready;
    }
    t.procs[to].state = .Running;
    t.current = to;
    mc_switch_context(&t.procs[from].context, &t.procs[to].context);
}

// Cooperatively yield to the next runnable process. No-op if none other is ready.
export fn proc_yield(t: *mut ProcTable) -> void {
    let from: usize = t.current;
    var to: usize = from;
    switch next_runnable(t, from) {
        ok(n) => { to = n; }
        err(e) => { return; } // nothing else runnable
    }
    let from_state: ProcState = t.procs[from].state;
    if from_state == .Running {
        t.procs[from].state = .Ready;
    }
    t.procs[to].state = .Running;
    t.current = to;
    mc_switch_context(&t.procs[from].context, &t.procs[to].context);
}

// Yield for a *blocked* process: switch to the next runnable one, or — if nothing else is
// runnable — run the platform idle action (wfi) instead of returning to spin in the caller's
// block loop. This is the path the IPC/wait blocking loops use, so a blocked kernel sleeps
// until an interrupt rather than burning the CPU as a "blocked current process".
export fn proc_yield_or_idle(t: *mut ProcTable) -> void {
    let from: usize = t.current;
    switch next_runnable(t, from) {
        ok(to) => {
            let from_state: ProcState = t.procs[from].state;
            if from_state == .Running {
                t.procs[from].state = .Ready;
            }
            t.procs[to].state = .Running;
            t.current = to;
            mc_switch_context(&t.procs[from].context, &t.procs[to].context);
        }
        err(e) => {
            proc_idle(t); // nothing else runnable: sleep until an interrupt, do not busy-spin
        }
    }
}

// Cooperatively yield, switching the address space too: the next process's page
// table (its `satp`) is loaded as part of the context switch, so each process runs in
// its own address space. Requires paging (S-mode). No-op if none other is ready.
export fn proc_yield_vm(t: *mut ProcTable) -> void {
    let from: usize = t.current;
    var to: usize = from;
    switch next_runnable(t, from) {
        ok(n) => { to = n; }
        err(e) => { return; } // nothing else runnable
    }
    let from_state: ProcState = t.procs[from].state;
    if from_state == .Running {
        t.procs[from].state = .Ready;
    }
    t.procs[to].state = .Running;
    t.current = to;
    let to_satp: u64 = t.procs[to].satp;
    mc_switch_context_vm(&t.procs[from].context, &t.procs[to].context, to_satp);
}
