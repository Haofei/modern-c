// kernel/core/proc_sched — scheduling policy and mechanism on top of the process
// table: run-queue selection (round-robin and priority), the proc_yield* family,
// timer ticks / quantum accounting, block/unblock/park/wake, and schedctl. The
// process table (ProcTable/Process), the shared liveness helpers (is_runnable),
// and the platform idle hook live in kernel/core/process.mc; this module builds
// scheduling on top of them. Split out of process.mc verbatim (pure move).

import "kernel/arch/active/context.mc"; // arch-selection seam (R0b); --arch picks context, default riscv64
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
//
// `#[irq_context]`: bounded counter/quantum updates on the current slot, no blocking or context
// switch — so the timer ISR can account a tick directly (see proc_preempt_tick). Callable from
// normal context too (irq_context is a restriction, not a requirement).
#[irq_context]
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

// Per-slot throttle penalty (added to a slot's effective tick count in proc_pick_fair): a
// throttled agent compares as if it had consumed (ticks + penalty) ticks, pushing it to the back
// of the fair queue without being blocked or killed. It lives ON THE Process (t.procs[slot].throttle)
// — NOT a module global — so it is per-table and is cleared by proc_table_init + proc_spawn slot
// reuse (a reaped slot must not inherit the old process's throttle). Same for the supervision/
// restart state below.

// A slot's effective fair-share cost: real ticks consumed plus any throttle penalty, weighted
// down by priority so a higher-priority agent is allowed a larger share before deprioritizing.
// We compare ticks/max(priority,1): with equal priority this is pure least-served-first; a
// priority-2 agent may consume twice the ticks of a priority-1 agent before losing its turn.
// u64 math avoids overflow when penalty is large.
fn fair_cost(t: *mut ProcTable, slot: usize) -> u64 {
    let base: u64 = (t.procs[slot].ticks as u64) + (t.procs[slot].throttle as u64);
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
        let cur: u32 = t.procs[slot].throttle;
        let room: u32 = 0xFFFFFFFF - cur;
        if penalty > room {
            t.procs[slot].throttle = 0xFFFFFFFF; // saturate
        } else {
            t.procs[slot].throttle = cur + penalty;
        }
    }
}

// Clear a slot's throttle penalty: it returns to competing on its real tick count.
export fn proc_throttle_clear(t: *mut ProcTable, slot: usize) -> void {
    if slot < MAX_PROCS {
        t.procs[slot].throttle = 0;
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
// `#[irq_context]`: a single bounded bit-clear (mask32_clear), no blocking/indirect calls — it is
// the wake primitive an ISR completion path reaches (wq_wake_one <- async_complete).
#[irq_context]
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

// True if the CURRENT process is blocked (non-runnable). An interrupts-off wait loop polls
// this to decide whether to keep idling: once a wake (e.g. from an ISR) clears the current
// process's block reasons, it returns false so the loop stops idling and re-checks its
// condition — closing the "wake delivered while about to idle" race.
export fn proc_current_blocked(t: *mut ProcTable) -> bool {
    return !proc_is_runnable_slot(t, t.current);
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
    // The address space is threaded as the opaque AddressSpace and unwrapped exactly once,
    // here at the context-switch FFI: mc_switch_context_vm takes the raw satp word (the arch
    // ABI), so we pass AddressSpace.raw — the same bits the field holds, no encoding in core.
    let to_aspace: AddressSpace = t.procs[to].aspace;
    mc_switch_context_vm(&t.procs[from].context, &t.procs[to].context, AddressSpace.raw(to_aspace));
}

// ----- timer-driven preemption (decision layer) -----
// The scheduler is otherwise cooperative (the proc_yield* family switches only at explicit points).
// Preemption adds a timer-driven RESCHEDULE REQUEST: the timer ISR accounts a tick and, when the
// current process's quantum expires, raises `need_resched`. The actual context switch is NOT done
// in the ISR — switching is a may-sleep op, and doing it from an `#[irq_context]` path is
// "scheduling while atomic" (a compile error here). Instead the kernel consumes the flag at a safe
// PREEMPTION POINT (proc_preempt_point) in normal context — e.g. on syscall/trap return — where
// switching is legal. This is the voluntary-preemption-point model (set-flag-in-ISR,
// switch-at-safe-point); a fully-asynchronous switch from the interrupted trap frame (saving the
// full register frame in the asm vector and mret-ing into another process) is the follow-on step.
//
// `need_resched` is written by the timer ISR and read from normal kernel context, so it is an
// explicit interrupt-shared atomic cell (release on set/clear, acquire on read) — exactly like
// trap.mc's tick counter.
global g_need_resched: atomic<u32> = atomic.init(0);

// Timer ISR hook: account one tick to the current process and, on the quantum-expiry edge, raise
// need_resched so the next preemption point reschedules. `#[irq_context]`: only bounded tick
// accounting plus an atomic flag store — no context switch, no blocking. Returns the expiry edge.
#[irq_context]
export fn proc_preempt_tick(t: *mut ProcTable) -> bool {
    let expired: bool = proc_tick(t);
    if expired {
        g_need_resched.store(1, .release);
    }
    return expired;
}

// True iff a reschedule has been requested (the current process's quantum expired since the last
// preemption point). Polled at safe points to decide whether to switch.
export fn proc_preempt_pending() -> bool {
    return g_need_resched.load(.acquire) != 0;
}

// Clear the reschedule request WITHOUT switching — e.g. the scheduler refreshed the quantum and
// chose to keep running the current process.
export fn proc_preempt_clear() -> void {
    g_need_resched.store(0, .release);
}

// Safe PREEMPTION POINT: if a reschedule was requested, clear it and switch to the highest-priority
// runnable process. Call from NORMAL kernel context only (it may switch contexts) — never from an
// `#[irq_context]` path. No-op when no reschedule is pending or nothing else is runnable.
export fn proc_preempt_point(t: *mut ProcTable) -> void {
    if proc_preempt_pending() {
        proc_preempt_clear();
        proc_yield_priority(t);
    }
}

// ----- supervision: heartbeat liveness (production-readiness §3.1 #12) -----
// The lifecycle primitives (spawn/exit/kill/reap) exist; supervision is the missing layer that
// DETECTS a stuck/dead long-running agent so a supervisor can restart or kill it. This adds the
// detection mechanism: a per-slot heartbeat deadline + last-beat timestamp (in timer ticks). An
// agent (or the kernel on its behalf) calls proc_heartbeat each time it makes progress; a
// supervisor periodically asks proc_liveness_expired which slots missed their deadline and applies
// policy (proc_kill / respawn / crash-loop backoff — policy lives in the supervisor, not here).
// The state lives ON THE Process (t.procs[slot].hb_deadline/hb_last) — NOT module globals — so it
// is per-table (two ProcTables don't share supervision) and is cleared by proc_table_init +
// proc_spawn slot reuse (a reincarnated process is unsupervised until re-enrolled). deadline 0 = off.

// Enroll `slot` under supervision: it must beat at least every `deadline` ticks, starting from
// `now`. deadline 0 disables supervision for the slot.
export fn proc_supervise(t: *mut ProcTable, slot: usize, now: u64, deadline: u64) -> void {
    if slot < MAX_PROCS {
        t.procs[slot].hb_deadline = deadline;
        t.procs[slot].hb_last = now;
    }
}

// Stop supervising `slot` (e.g. on a clean exit/reap): it can no longer be flagged expired.
export fn proc_unsupervise(t: *mut ProcTable, slot: usize) -> void {
    if slot < MAX_PROCS {
        t.procs[slot].hb_deadline = 0;
    }
}

// Record a heartbeat for `slot` at tick `now` (the agent made progress). No-op if unsupervised.
export fn proc_heartbeat(t: *mut ProcTable, slot: usize, now: u64) -> void {
    if slot < MAX_PROCS {
        if t.procs[slot].hb_deadline != 0 {
            t.procs[slot].hb_last = now;
        }
    }
}

// True iff `slot` is supervised and has missed its heartbeat deadline as of `now` — i.e. more than
// `deadline` ticks elapsed since its last beat. Overflow-safe (subtraction only when now >= last).
// A supervisor calls this to decide whether to restart/kill the slot.
export fn proc_liveness_expired(t: *mut ProcTable, slot: usize, now: u64) -> bool {
    if slot >= MAX_PROCS {
        return false;
    }
    let deadline: u64 = t.procs[slot].hb_deadline;
    if deadline == 0 {
        return false; // not supervised
    }
    let last: u64 = t.procs[slot].hb_last;
    if now <= last {
        return false; // no time elapsed (or clock not advanced) — not expired
    }
    return (now - last) > deadline;
}

// ----- supervision: restart / crash-loop policy (production-readiness §3.1 #12) -----
// Once liveness detection (above) flags a dead/stuck slot, the supervisor decides whether to RESTART
// it — but blindly restarting a slot that keeps dying is a crash loop (CPU-burning thrash). This
// adds the crash-loop guard: a per-process restart counter (t.procs[slot].restart_count, cleared on
// table init + slot reuse) the supervisor bumps on each restart and checks against a budget; once
// the budget is exhausted the slot is declared crash-looping and the supervisor gives up instead of
// restarting forever. A clean run resets the counter. Mechanism only — the budget + give-up policy
// are the supervisor's.

// Record that the supervisor is (re)starting `slot`; returns the new restart count. SATURATES at
// u32 max so a very long crash loop cannot wrap the counter back to 0 and re-permit restarts.
export fn proc_restart_record(t: *mut ProcTable, slot: usize) -> u32 {
    if slot < MAX_PROCS {
        let cur: u32 = t.procs[slot].restart_count;
        if cur < 0xFFFFFFFF {
            t.procs[slot].restart_count = cur + 1;
        }
        return t.procs[slot].restart_count;
    }
    return 0;
}

// True iff another restart is within budget (restart count < max_restarts). When false the slot is
// crash-looping and the supervisor should stop restarting it.
export fn proc_restart_allowed(t: *mut ProcTable, slot: usize, max_restarts: u32) -> bool {
    if slot >= MAX_PROCS {
        return false;
    }
    return t.procs[slot].restart_count < max_restarts;
}

// Reset a slot's restart counter (a clean/healthy run — it is no longer crash-looping).
export fn proc_restart_reset(t: *mut ProcTable, slot: usize) -> void {
    if slot < MAX_PROCS {
        t.procs[slot].restart_count = 0;
    }
}

// The supervisor's per-slot verdict, combining liveness + restart budget.
enum SupervisorAction {
    None,    // the slot is alive (or unsupervised) — nothing to do
    Restart, // the slot missed its heartbeat and is still within the restart budget — respawn it
    GiveUp,  // the slot is dead AND out of restart budget (crash-looping) — stop restarting it
}

// One supervisor step over `slot`: fold the heartbeat-liveness check and the crash-loop budget into
// a single verdict the caller actuates. This is the loop primitive a supervisor runs over its
// children each tick — `for slot in children: switch proc_supervise_step(t, slot, now, max) { ... }`
// — keeping the mechanism here and the actuation (respawn via proc_spawn / kill via proc_kill, and
// proc_restart_record on an actual restart / proc_restart_reset on a clean recovery) in the caller.
export fn proc_supervise_step(t: *mut ProcTable, slot: usize, now: u64, max_restarts: u32) -> SupervisorAction {
    if !proc_liveness_expired(t, slot, now) {
        return .None;
    }
    if proc_restart_allowed(t, slot, max_restarts) {
        return .Restart;
    }
    return .GiveUp;
}
