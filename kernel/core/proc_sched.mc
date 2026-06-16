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

// ----- fair-share scheduling + throttle (alternative pick; purely additive) -----
// Round-robin + static priority let a heavy agent monopolize the CPU. Fair-share picks the
// *least-served* runnable slot — fewest ticks consumed this incarnation — so no agent runs
// again until others catch up, bounding CPU per agent. The per-slot `ticks` accumulator and
// `priority` already live on Process; the only extra state fair-share needs is a per-slot
// throttle penalty. To stay disjoint from process.mc (no new Process fields), that penalty
// lives in a module-global array here, indexed by slot, and is folded into the comparison.
const NO_SLOT: usize = MAX_PROCS; // sentinel: "no candidate found yet"

// Per-slot throttle penalty, added to a slot's effective tick count in proc_pick_fair. A
// throttled agent compares as if it had consumed (ticks + penalty) ticks, so it is pushed to
// the back of the fair queue without being blocked or killed. Zero-initialized (bss); reset by
// proc_throttle_clear. Indexed by slot in 0..MAX_PROCS.
global g_throttle: [MAX_PROCS]u32;

// A slot's effective fair-share cost: real ticks consumed plus any throttle penalty, weighted
// down by priority so a higher-priority agent is allowed a larger share before deprioritizing.
// We compare ticks/max(priority,1): with equal priority this is pure least-served-first; a
// priority-2 agent may consume twice the ticks of a priority-1 agent before losing its turn.
// u64 math avoids overflow when penalty is large.
fn fair_cost(t: *mut ProcTable, slot: usize) -> u64 {
    let base: u64 = (t.procs[slot].ticks as u64) + (g_throttle[slot] as u64);
    var w: u32 = t.procs[slot].priority;
    if w == 0 {
        w = 1; // priority 0 (default/unset) weights as 1, never divides by zero
    }
    return base / (w as u64);
}

// Fair-share pick: among the RUNNABLE slots, the one with the fewest effective ticks consumed
// (least-served-first), weighted by priority and offset by any throttle penalty. Ties break to
// the lower slot index. NoRunnable if nothing is runnable. Unlike next_runnable this is an
// absolute pick (it may return the current slot) — it is an alternative selection policy, not a
// round-robin successor, and leaves next_runnable / proc_yield untouched.
export fn proc_pick_fair(t: *mut ProcTable) -> Result<usize, SchedError> {
    var best: usize = NO_SLOT;
    var best_cost: u64 = 0;
    var i: usize = 0;
    while i < t.count {
        if is_runnable(t, i) {
            let cost: u64 = fair_cost(t, i);
            if best == NO_SLOT {
                best = i;
                best_cost = cost;
            } else {
                if cost < best_cost { // strict <: first (lowest) slot wins ties
                    best = i;
                    best_cost = cost;
                }
            }
        }
        i = i + 1;
    }
    if best == NO_SLOT {
        return err(.NoRunnable);
    }
    return ok(best);
}

// Throttle a slot: add `penalty` to its effective tick count so fair-share pushes it to the
// back of the queue. Saturates at u32 max rather than wrapping, so a heavy penalty cannot fold
// a misbehaving agent back to the front. The agent stays runnable (not killed/blocked) — this
// is a deprioritization knob, not a kill.
export fn proc_throttle(t: *mut ProcTable, slot: usize, penalty: u32) -> void {
    if slot < MAX_PROCS {
        let cur: u32 = g_throttle[slot];
        let room: u32 = 0xFFFFFFFF - cur;
        if penalty > room {
            g_throttle[slot] = 0xFFFFFFFF; // saturate
        } else {
            g_throttle[slot] = cur + penalty;
        }
    }
}

// Clear a slot's throttle penalty: it returns to competing on its real tick count.
export fn proc_throttle_clear(t: *mut ProcTable, slot: usize) -> void {
    if slot < MAX_PROCS {
        g_throttle[slot] = 0;
    }
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

// ----- pause / resume (freeze/thaw a process's scheduling) -----
// Runnability is DERIVED from the block-reason set: a process runs only when Ready/Running and
// its block set is empty. Pausing sets a dedicated reason bit so the process becomes
// non-runnable but stays alive (still Ready, just blocked); resuming clears that bit. We define
// the reason here rather than in process.mc to keep this purely additive and disjoint from the
// process table module. BLOCK_PAUSED must not collide with process.mc's BLOCK_RECV/SEND/WAIT
// (bits 0/1/2), so it is bit 3.
const BLOCK_PAUSED: u32 = 3;

// Freeze a process: it becomes non-runnable (the scheduler skips it) but is not killed — it
// stays Ready with the PAUSED block reason set, ready to thaw exactly where it left off.
export fn proc_pause(t: *mut ProcTable, slot: usize) -> void {
    proc_block(t, slot, BLOCK_PAUSED);
}

// Thaw a paused process: clear the PAUSED reason; it is runnable again once no reasons remain.
export fn proc_resume(t: *mut ProcTable, slot: usize) -> void {
    proc_unblock(t, slot, BLOCK_PAUSED);
}

// True iff `slot` is currently paused (has the PAUSED block reason set).
export fn proc_is_paused(t: *mut ProcTable, slot: usize) -> bool {
    if slot < t.count {
        return mask32_contains(&t.procs[slot].block_reasons, BLOCK_PAUSED);
    }
    return false;
}

// Exported runnability reader (is_runnable in process.mc is module-private): true iff the
// scheduler would consider `slot` for dispatch. Lets tests/callers observe derived runnability
// without reaching into the process table internals.
export fn proc_is_runnable_slot(t: *mut ProcTable, slot: usize) -> bool {
    if slot < t.count {
        return is_runnable(t, slot);
    }
    return false;
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
