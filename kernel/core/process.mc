// kernel/core/process — process lifecycle (spawn / run / exit) on top of the
// context-switch primitive. A process is a saved `Context` plus a lifecycle state
// and a pid. The table round-robins among runnable processes and, on `proc_exit`,
// marks the caller `Dead` and switches to the next runnable one — so a process can
// terminate (unlike a bare scheduler thread that runs forever). Slot 0 is the
// bootstrap (the kernel); when every spawned process has exited, control returns
// there. Cooperative for now (processes yield/exit); preemption is orthogonal.

import "kernel/arch/riscv64/context.mc";
import "kernel/core/ipc.mc";
import "std/math.mc";
import "std/mask.mc";
import "kernel/lib/mailbox.mc";
import "kernel/lib/fdspace.mc";

const MAX_PROCS: usize = 8;
const IPC_SLOTS: usize = 4; // mailbox depth per process

enum ProcState {
    Unused,
    Ready,
    Running,
    BlockedRecv, // blocked in ipc_receive waiting for a message (not runnable)
    Zombie,      // exited, awaiting reap by its parent
    Dead,
}

// Reasons a wait/reap finds nothing.
enum ReapError {
    NoChildren,  // the caller has no children
    NoZombieYet, // children exist but none have exited
}

// The result of reaping a child: its pid and exit code. A named struct (these are in-kernel
// values, no register-ABI constraint) instead of a (pid << 32 | code) packed u64.
struct ReapInfo {
    pid: u32,
    code: u32,
}

// A capability-style reference to a process: the slot plus the *generation* it held when the
// reference was taken. Slots are reused (proc_spawn), so a bare slot/pid can silently refer
// to a different process after reuse; an Endpoint is validated against the live generation,
// so a stale reference fails closed (DeadEndpoint) instead of hitting the wrong process.
struct Endpoint {
    slot: usize,
    gen: u32,
}

enum EpError {
    DeadEndpoint, // the slot is free, or now holds a different generation
}

// Typed outcome of a bounded blocking send: a permission denial, a dead destination, and a
// timeout are distinct failures the caller (or its logs) can act on differently.
enum SendError {
    Denied,     // the sender's allow_mask does not permit this destination
    DeadTarget, // the destination never existed, or has exited/died
    Timeout,    // the destination's mailbox stayed full for the whole yield budget
}

// Block reasons (bits in Process.block_reasons). A process is runnable only when its block
// set is empty — runnable state is *derived* from these flags, not set ad hoc, so a missed
// state transition can't leave a blocked process on the run queue (MINIX RTS_* pattern).
const BLOCK_RECV: u32 = 0; // waiting to receive a message
const BLOCK_SEND: u32 = 1; // waiting for room in a destination mailbox
const BLOCK_WAIT: u32 = 2; // waiting for a child to exit

struct Process {
    context: Context,
    state: ProcState,
    pid: u32,
    gen: u32,       // generation: bumped each time this slot is (re)used, for Endpoint validation
    parent: u32,    // pid of the spawning process (display/debug identity)
    parent_slot: usize, // spawning process slot, paired with parent_gen
    parent_gen: u32,    // spawning process generation; prevents stale-parent reuse
    exit_code: u32, // valid once state == Zombie
    satp: u64,      // this process's address space (Sv39 root); 0 = share the kernel's
    inbox: Mailbox<Message, IPC_SLOTS>, // multi-slot mailbox for kernel-mediated IPC
    block_reasons: Mask32,       // set of BLOCK_* reasons; runnable iff empty (derived state)
    wait_slot: usize,            // the slot this process is blocked receiving-from (for death cleanup)
    wait_gen: u32,               // the generation of wait_slot when it began waiting
    pending_sig: Mask32,         // pending-signal set (a PM server builds on this)
    allow_mask: Mask32,          // least privilege: bit p = may IPC-send to pid p
    kcall_mask: Mask32,          // least privilege: bit op = may invoke kernel call `op`
    priority: u32,               // scheduling priority (policy set externally; higher runs first)
    quantum: u32,                // remaining scheduling quantum in ticks (0 = expired)
    ticks: u32,                  // accounting: total ticks this incarnation has consumed
    sched_endpoint: u32,         // the scheduler service to notify on quantum expiry (0 = none)
    fds: FdSpace,                // open file descriptors; copied to a child on spawn (fork), kept across exec
}

const QUANTUM_DEFAULT: u32 = 10;

struct ProcTable {
    procs: [MAX_PROCS]Process,
    count: usize,   // slots in use (slot 0 = bootstrap)
    current: usize, // running slot
    // The platform's CPU-idle action (e.g. `wfi`), invoked when a process blocks and nothing
    // else is runnable — so the kernel sleeps until an interrupt instead of busy-spinning as a
    // blocked "current" process. Defaults to a no-op (set by the platform via proc_set_idle).
    idle_hook: closure() -> void,
    // Global resource-cleanup hook, invoked with (dead pid, dead gen) when a process dies, so
    // subsystems that hold per-owner resources (grant tables, service registries, …) can revoke
    // everything the dead process owned. The process table stays decoupled from those subsystems:
    // whoever owns them registers a closure via proc_set_death_hook. Defaults to a no-op.
    death_hook: closure(u32, u32) -> void,
    // Monotonic source of correlation ids for synchronous calls (ipc_call / ipc_call_ep), so
    // each outstanding call is distinguishable and its reply can be matched. Never reused.
    next_call_id: u64,
}

// The no-op default idle action (a closure needs a captured env; this one is empty).
struct IdleEnv { unused: u32 }
global g_idle_env: IdleEnv;
fn idle_noop(e: *mut IdleEnv) -> void {}

// The no-op default death hook (same empty-env pattern as idle).
struct DeathEnv { unused: u32 }
global g_death_env: DeathEnv;
fn death_noop(e: *mut DeathEnv, pid: u32, gen: u32) -> void {}

// Runnable state is DERIVED: a process runs only when it is Ready/Running *and* has no
// outstanding block reasons. Nothing sets a "runnable" bit directly — proc_block/proc_unblock
// own the block set, so a process can never be left wrongly on or off the run queue.
fn is_runnable(t: *mut ProcTable, slot: usize) -> bool {
    let s: ProcState = t.procs[slot].state;
    if s != .Ready {
        if s != .Running {
            return false;
        }
    }
    return mask32_is_empty(&t.procs[slot].block_reasons);
}

// True if `slot` holds a live process that can receive IPC — i.e. not free, exited, or dead.
// A blocked process is still live (it is Ready with block reasons set, and sending wakes it).
fn proc_is_live(t: *mut ProcTable, slot: usize) -> bool {
    if slot >= t.count {
        return false;
    }
    let s: ProcState = t.procs[slot].state;
    if s == .Unused {
        return false;
    }
    if s == .Zombie {
        return false;
    }
    if s == .Dead {
        return false;
    }
    return true;
}

// ----- process introspection (for `ps`/`top`-style tools, via a kernel call) -----

export fn proc_count(t: *mut ProcTable) -> usize {
    return t.count;
}

export fn proc_pid_at(t: *mut ProcTable, idx: usize) -> u32 {
    if idx < t.count {
        return t.procs[idx].pid;
    }
    return 0;
}

// A stable numeric code for a slot's state: 0=Unused 1=Ready 2=Running 3=Blocked 4=Zombie.
export fn proc_state_code(t: *mut ProcTable, idx: usize) -> u32 {
    if idx >= t.count {
        return 0;
    }
    let s: ProcState = t.procs[idx].state;
    let blocked: bool = !mask32_is_empty(&t.procs[idx].block_reasons);
    switch s {
        .Unused => { return 0; }
        .Ready => { if blocked { return 3; } return 1; }   // Ready + block reasons = Blocked
        .Running => { if blocked { return 3; } return 2; } // a blocked process reads as Blocked
        .BlockedRecv => { return 3; }
        .Zombie => { return 4; }
        .Dead => { return 5; }
    }
}

export fn proc_table_init(t: *mut ProcTable) -> void {
    var i: usize = 0;
    while i < MAX_PROCS {
        t.procs[i].state = .Unused;
        t.procs[i].pid = 0;
        t.procs[i].gen = 0;
        t.procs[i].parent = 0;
        t.procs[i].parent_slot = MAX_PROCS;
        t.procs[i].parent_gen = 0;
        t.procs[i].exit_code = 0;
        t.procs[i].satp = 0;
        mailbox_init(Message, IPC_SLOTS, &t.procs[i].inbox);
        t.procs[i].block_reasons = mask32_zero();
        t.procs[i].wait_slot = MAX_PROCS; // no waiter target
        t.procs[i].wait_gen = 0;
        t.procs[i].pending_sig = mask32_zero();
        t.procs[i].allow_mask = mask32_zero();
        t.procs[i].kcall_mask = mask32_zero();
        t.procs[i].priority = 0;
        t.procs[i].quantum = QUANTUM_DEFAULT;
        t.procs[i].ticks = 0;
        t.procs[i].sched_endpoint = 0;
        fd_init(&t.procs[i].fds);
        i = i + 1;
    }
    // Slot 0 is the running bootstrap context (filled on first switch out).
    t.procs[0].state = .Running;
    t.procs[0].allow_mask = mask32_from(0xFFFF_FFFF); // bootstrap can seed policy
    t.procs[0].kcall_mask = mask32_from(0xFFFF_FFFF);
    t.count = 1;
    t.current = 0;
    t.next_call_id = 1; // 0 means "not a call"; real call ids start at 1
    t.idle_hook = bind(&g_idle_env, idle_noop); // platform overrides with wfi via proc_set_idle
    t.death_hook = bind(&g_death_env, death_noop); // subsystems override via proc_set_death_hook
}

// Set the platform's CPU-idle action (e.g. a `wfi` wrapper). Called when the scheduler has
// nothing runnable, so a blocked kernel sleeps instead of spinning. The wfi itself lives in
// arch code (this module stays host-portable); the platform installs it at boot.
export fn proc_set_idle(t: *mut ProcTable, hook: closure() -> void) -> void {
    t.idle_hook = hook;
}

// Run the platform idle action once (sleep until an interrupt, on a real machine).
fn proc_idle(t: *mut ProcTable) -> void {
    let hook: closure() -> void = t.idle_hook;
    hook();
}

// Install the global resource-cleanup hook, run with (pid, gen) on every process death.
// A microkernel installs one closure that revokes the dead pid's grants and unregisters
// its services, so a dead owner's resources can never outlive it. See proc_death_cleanup.
export fn proc_set_death_hook(t: *mut ProcTable, hook: closure(u32, u32) -> void) -> void {
    t.death_hook = hook;
}

export fn proc_spawn(t: *mut ProcTable, stack_top: usize, entry: fn() -> void) -> u32 {
    // Reuse a reaped (Unused) slot if one exists; otherwise grow the table. Without this,
    // spawn/reap cycles would permanently exhaust the table even with free slots.
    var slot: usize = MAX_PROCS;
    var i: usize = 0;
    var scanning: bool = true;
    while scanning {
        if i >= t.count {
            scanning = false;
        } else {
            if t.procs[i].state == .Unused {
                slot = i;
                scanning = false;
            } else {
                i = i + 1;
            }
        }
    }
    if slot >= MAX_PROCS {
        if t.count >= MAX_PROCS {
            unreachable; // process table full
        }
        slot = t.count;
        t.count = t.count + 1;
    }
    mc_thread_init(&t.procs[slot].context, stack_top, entry);
    t.procs[slot].state = .Ready;
    t.procs[slot].pid = slot as u32;
    t.procs[slot].gen = t.procs[slot].gen + 1; // a new incarnation: invalidates old endpoints
    t.procs[slot].parent = t.procs[t.current].pid; // the spawner is the parent
    t.procs[slot].parent_slot = t.current;
    t.procs[slot].parent_gen = t.procs[t.current].gen;
    t.procs[slot].exit_code = 0;
    // Reset per-process state in case this slot was reaped from an earlier process.
    mailbox_init(Message, IPC_SLOTS, &t.procs[slot].inbox);
    t.procs[slot].block_reasons = mask32_zero();
    t.procs[slot].wait_slot = MAX_PROCS;
    t.procs[slot].wait_gen = 0;
    t.procs[slot].pending_sig = mask32_zero();
    t.procs[slot].allow_mask = mask32_zero();
    t.procs[slot].kcall_mask = mask32_zero();
    t.procs[slot].priority = 0;
    t.procs[slot].quantum = QUANTUM_DEFAULT;
    t.procs[slot].ticks = 0;
    t.procs[slot].sched_endpoint = 0;
    // fork fd semantics: the child inherits a COPY of the spawner's open descriptors at the
    // same fd numbers, sharing the underlying resources. Clear any stale fds from a reaped
    // slot first. (Empty child + equal capacity ⇒ inherit can never overflow.)
    fd_init(&t.procs[slot].fds);
    switch fd_inherit(&t.procs[t.current].fds, &t.procs[slot].fds) {
        ok(n) => {}
        err(e) => {}
    }
    return slot as u32;
}

// A mutable handle to a process's open-file-descriptor space — for the syscall surface and
// fork/exec wiring to populate, inherit, and inspect a process's fds.
export fn proc_fds(t: *mut ProcTable, slot: usize) -> *mut FdSpace {
    return &t.procs[slot].fds;
}

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

// How many messages are pending in a process's inbox (introspection: for an info/sched service).
export fn proc_inbox_count(t: *mut ProcTable, pid: u32) -> usize {
    let p: usize = pid as usize;
    if p < t.count {
        return mailbox_count(Message, IPC_SLOTS, &t.procs[p].inbox);
    }
    return 0;
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

// The pid of the currently-running process.
export fn proc_self(t: *mut ProcTable) -> u32 {
    return t.procs[t.current].pid;
}

// Wake process `pid`: clear its receive-block so it can run again. No-op otherwise.
export fn proc_wake(t: *mut ProcTable, pid: u32) -> void {
    proc_unblock(t, pid as usize, BLOCK_RECV);
}

// The endpoint (slot + current generation) of process `pid`.
export fn proc_endpoint(t: *mut ProcTable, pid: u32) -> Endpoint {
    let s: usize = pid as usize;
    if s < t.count {
        return .{ .slot = s, .gen = t.procs[s].gen };
    }
    return .{ .slot = MAX_PROCS, .gen = 0 };
}

// The current process's endpoint.
export fn proc_self_endpoint(t: *mut ProcTable) -> Endpoint {
    return proc_endpoint(t, proc_self(t));
}

// Validate an endpoint: returns its slot if it still refers to the same live incarnation,
// else DeadEndpoint (the slot was freed, reused by a newer generation, or has died/exited).
export fn endpoint_slot(t: *mut ProcTable, ep: Endpoint) -> Result<usize, EpError> {
    if ep.slot >= t.count {
        return err(.DeadEndpoint);
    }
    if t.procs[ep.slot].gen != ep.gen {
        return err(.DeadEndpoint);
    }
    let s: ProcState = t.procs[ep.slot].state;
    if s == .Unused {
        return err(.DeadEndpoint);
    }
    if s == .Zombie {
        return err(.DeadEndpoint);
    }
    if s == .Dead {
        return err(.DeadEndpoint);
    }
    return ok(ep.slot);
}

// True if the endpoint still refers to the same live process.
export fn endpoint_live(t: *mut ProcTable, ep: Endpoint) -> bool {
    switch endpoint_slot(t, ep) {
        ok(s) => {
            return true;
        }
        err(e) => {
            return false;
        }
    }
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

// The reserved IPC tag the kernel delivers to a receiver that was blocked on a process which
// then died: the message's `from` is the dead pid and `tag` is TAG_DEAD, so the receiver
// learns the endpoint is gone (a dead-endpoint error) instead of blocking forever.
const TAG_DEAD: u32 = 0xDEAD;

export fn ipc_tag_dead() -> u32 {
    return TAG_DEAD;
}

// The IPC tag the kernel sends to a process's scheduler service when its quantum expires; the
// notification's `from` is the expired process, so the scheduler knows whom to reschedule.
const TAG_QUANTUM: u32 = 0xDEAD + 1;

export fn ipc_tag_quantum() -> u32 {
    return TAG_QUANTUM;
}

// Central process-death cleanup: clear the dying process's IPC state and release everyone
// waiting on it, so no caller is left blocked on a dead endpoint and a reused slot starts
// clean. (MINIX clears IPC references on exit instead of leaving dangling waiters.)
fn proc_death_cleanup(t: *mut ProcTable, dead: usize) -> void {
    let dead_gen: u32 = t.procs[dead].gen;
    let dead_pid: u32 = t.procs[dead].pid;
    // Revoke global resources the dead process owned (grants, registered services, …)
    // through the installed hook, before the slot is reused. Decoupled: the hook is
    // whatever the subsystem owner registered (a no-op if none).
    let death_hook: closure(u32, u32) -> void = t.death_hook;
    death_hook(dead_pid, dead_gen);
    // Drop the dead process's own pending IPC + signals + wait state, and close its open file
    // descriptors — a zombie holds only its exit status, never live resources, so a later
    // spawn that reuses this slot can never inherit a ghost descriptor.
    mailbox_init(Message, IPC_SLOTS, &t.procs[dead].inbox);
    fd_init(&t.procs[dead].fds);
    t.procs[dead].pending_sig = mask32_zero();
    t.procs[dead].wait_slot = MAX_PROCS;
    // Wake anyone blocked receiving-from this exact incarnation. We do NOT post a DEAD message
    // (a full inbox could swallow it); instead the woken receiver re-checks the source's
    // liveness in ipc_receive_from and synthesizes the DEAD result out-of-band — guaranteed.
    var i: usize = 0;
    while i < t.count {
        if i != dead {
            if t.procs[i].wait_slot == dead {
                if t.procs[i].wait_gen == dead_gen {
                    t.procs[i].wait_slot = MAX_PROCS;
                    proc_unblock(t, i, BLOCK_RECV);
                }
            }
        }
        i = i + 1;
    }
}

// Terminate the current process with an exit code and switch to the next runnable
// one. Never returns to the caller (its slot is now a Zombie awaiting reap).
export fn proc_exit(t: *mut ProcTable, code: u32) -> void {
    let from: usize = t.current;
    t.procs[from].exit_code = code;
    proc_death_cleanup(t, from); // release waiters + clear IPC before the slot becomes a zombie
    t.procs[from].state = .Zombie;
    // Wake the parent if it is blocked in proc_wait — this exit is the event it was waiting for.
    let parent_slot: usize = t.procs[from].parent_slot;
    if parent_slot < t.count {
        if t.procs[parent_slot].gen == t.procs[from].parent_gen {
            proc_unblock(t, parent_slot, BLOCK_WAIT);
        }
    }
    var target: usize = from;
    var picking: bool = true;
    while picking {
        switch next_runnable(t, from) {
            ok(n) => {
                target = n;
                picking = false;
            }
            err(e) => {
                // No runnable process: enter the idle/reaper path instead of resurrecting the
                // zombie or panicking. Idle (wfi) until an interrupt wakes a blocked process,
                // then dispatch it. The exiting process never runs again.
                proc_idle(t);
            }
        }
    }
    t.procs[target].state = .Running;
    t.current = target;
    mc_switch_context(&t.procs[from].context, &t.procs[target].context);
}

// Reap one exited child of `parent_pid`: return its `ReapInfo` (pid + exit_code) and free
// the slot. A non-blocking `wait` — errors if the caller has no children, or has children
// but none have exited yet (the caller can yield and retry). Reaping is what turns a Zombie
// back into a free (Unused) slot.
export fn proc_reap(t: *mut ProcTable, parent_pid: u32) -> Result<ReapInfo, ReapError> {
    let parent_slot: usize = parent_pid as usize;
    if parent_slot >= t.count {
        return err(.NoChildren);
    }
    let parent_gen: u32 = t.procs[parent_slot].gen;
    var any_child: bool = false;
    var i: usize = 0;
    while i < t.count {
        let pid: u32 = t.procs[i].pid;
        let par: u32 = t.procs[i].parent;
        if par == parent_pid {
            if t.procs[i].parent_slot != parent_slot {
                i = i + 1;
                continue;
            }
            if t.procs[i].parent_gen != parent_gen {
                i = i + 1;
                continue;
            }
            if pid != parent_pid { // never the parent's own slot
                let st: ProcState = t.procs[i].state;
                if st == .Zombie {
                    let code: u32 = t.procs[i].exit_code;
                    t.procs[i].state = .Unused;
                    t.procs[i].parent_slot = MAX_PROCS;
                    t.procs[i].parent_gen = 0;
                    return ok(.{ .pid = pid, .code = code });
                }
                if st != .Unused {
                    any_child = true; // a still-running child
                }
            }
        }
        i = i + 1;
    }
    if any_child {
        return err(.NoZombieYet);
    }
    return err(.NoChildren);
}

// Block until a child of `parent_pid` exits, then reap it. While no child has
// exited, yield so the runnable children get to run (and eventually exit). Returns
// the reaped child's `ReapInfo`, or `NoChildren` if the caller has none.
export fn proc_wait(t: *mut ProcTable, parent_pid: u32) -> Result<ReapInfo, ReapError> {
    var result: ReapInfo = .{ .pid = 0, .code = 0 };
    var done: bool = false;
    while !done {
        switch proc_reap(t, parent_pid) {
            ok(info) => {
                result = info;
                done = true;
            }
            err(e) => {
                let reason: ReapError = e;
                if reason == .NoChildren {
                    return err(reason); // nothing to wait for
                }
                // NoZombieYet: block on child-exit. A child's proc_exit clears this BLOCK_WAIT,
                // so we sleep (not busy-poll) until a child actually exits, then retry the reap.
                proc_block(t, t.current, BLOCK_WAIT);
                proc_yield_or_idle(t);
            }
        }
    }
    proc_unblock(t, t.current, BLOCK_WAIT); // clear the wait-block on the way out
    return ok(result);
}

// Give process `idx` its own address space (Sv39 satp). A context switch into this
// process loads this value into satp (see the vmspace demo); 0 keeps the kernel map.
export fn proc_set_satp(t: *mut ProcTable, idx: usize, satp: u64) -> void {
    t.procs[idx].satp = satp;
}

export fn proc_satp(t: *mut ProcTable, idx: usize) -> u64 {
    return t.procs[idx].satp;
}

export fn proc_pid(t: *mut ProcTable) -> u32 {
    return t.procs[t.current].pid;
}

// ----- least privilege: per-process IPC allow-list + kernel-call gateway -----

enum KError {
    Denied, // the caller's kcall_mask does not permit this kernel call
}

// Restrict which peers a process may IPC-send to (bit p = may send to pid p).
export fn proc_set_allow_mask(t: *mut ProcTable, pid: u32, mask: u32) -> void {
    let p: usize = pid as usize;
    if p < t.count {
        t.procs[p].allow_mask = mask32_from(mask);
    }
}

// Restrict which kernel calls a process may invoke (bit op = may call `op`).
export fn proc_set_kcall_mask(t: *mut ProcTable, pid: u32, mask: u32) -> void {
    let p: usize = pid as usize;
    if p < t.count {
        t.procs[p].kcall_mask = mask32_from(mask);
    }
}

// Privilege-checked send: deliver only if the caller is allowed to reach `dst_pid`. Returns
// whether the message was permitted *and* delivered. Blocks (yields) while the mailbox is full,
// like `ipc_send`, but reports false — rather than a phantom success — when the destination
// never existed or exits before the message lands, so a dead peer is not mistaken for delivery.
export fn ipc_try_send(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> bool {
    let cur: usize = t.current;
    if !mask32_contains(&t.procs[cur].allow_mask, dst_pid) {
        return false; // not permitted to send to this peer
    }
    let dst: usize = dst_pid as usize;
    var sending: bool = true;
    while sending {
        if !proc_is_live(t, dst) {
            return false; // destination gone (never existed, or exited while we waited) — not sent
        }
        if ipc_send_try(t, dst_pid, tag, a0, a1, a2) {
            return true; // delivered
        }
        proc_yield_or_idle(t); // mailbox full -- let the receiver drain it, or idle if none runnable
    }
    return false;
}

// Kernel-call gateway: a server requests a privileged op through one checked entry
// point. Denied unless the caller's kcall_mask permits `op`. (The op itself is a
// stand-in here; a real kernel would map/grant/program IRQs behind this gate.)
export fn kcall(t: *mut ProcTable, op: u32, arg: u64) -> Result<u64, KError> {
    let cur: usize = t.current;
    if !mask32_contains(&t.procs[cur].kcall_mask, op) {
        return err(.Denied);
    }
    return ok(arg); // performed (stand-in for the privileged operation's result)
}

// ----- signals: async events delivered to a process (the kernel primitive a Process
// Manager builds POSIX signals on). `sig` is 0..31; delivery sets a pending bit and
// wakes a blocked process; the target polls/takes pending signals. -----

// Deliver signal `sig` to `target_pid` (sets the pending bit, wakes a blocked target).
// Raw-pid signal delivery: a non-capability path. It validates that the slot holds a *live*
// process (not free/exited/dead), but a bare pid can still refer to a different incarnation
// after slot reuse — prefer proc_kill_ep, which checks the endpoint generation.
export fn proc_kill(t: *mut ProcTable, target_pid: u32, sig: u32) -> void {
    let target: usize = target_pid as usize;
    if !proc_is_live(t, target) {
        return; // out of range, or a free/exited/dead slot — never signal it
    }
    mask32_set(&t.procs[target].pending_sig, sig);
    proc_unblock(t, target, BLOCK_RECV); // a pending signal wakes a blocked receiver
}

// Endpoint-validated signal delivery: rejects a stale endpoint (slot reused by a new
// generation, or freed/dead) with DeadEndpoint before signaling, so a signal can never be
// delivered to a different incarnation than the one the caller named.
export fn proc_kill_ep(t: *mut ProcTable, ep: Endpoint, sig: u32) -> Result<bool, EpError> {
    switch endpoint_slot(t, ep) {
        ok(target) => {
            mask32_set(&t.procs[target].pending_sig, sig);
            proc_unblock(t, target, BLOCK_RECV);
            return ok(true);
        }
        err(e) => {
            return err(.DeadEndpoint);
        }
    }
}

// The current process's pending-signal bitmask.
export fn proc_sigpending(t: *mut ProcTable) -> u32 {
    return mask32_raw(&t.procs[t.current].pending_sig);
}

// Take (clear + return) the lowest pending signal of the current process, or 32 if none.
export fn proc_sigtake(t: *mut ProcTable) -> u32 {
    return mask32_take_first(&t.procs[t.current].pending_sig);
}

// ----- kernel-mediated IPC (the microkernel backbone) -----
//
// Send/receive fixed-size Messages between processes. The kernel is the only path:
// senders never touch a receiver's memory, and the receiver learns the sender's pid
// from `from` (stamped by the kernel — unforgeable). Each process has a multi-slot
// mailbox; send blocks (yields) only when the mailbox is full, then wakes a blocked
// receiver. Receive can take any message or filter by sender.

fn wake_if_blocked(t: *mut ProcTable, dst: usize) -> void {
    proc_unblock(t, dst, BLOCK_RECV); // wake a receiver blocked on its inbox
}

// Non-blocking send: deliver if the mailbox has room, else false (the caller decides
// whether to retry, drop, or block). This is the primitive both send policies build on,
// so a caller never has to spin against a full mailbox unless it explicitly chooses to.
// Build a message stamped with the current process's endpoint identity (slot + generation)
// and a correlation id (0 for a non-call send). The kernel stamps `from`/`from_gen`, so the
// receiver can trust the sender identity across slot reuse, and a synchronous caller can
// match the reply to its request.
fn proc_make_msg(t: *mut ProcTable, tag: u32, a0: u64, a1: u64, a2: u64, call_id: u64) -> Message {
    return .{
        .from = t.procs[t.current].pid,
        .from_gen = t.procs[t.current].gen,
        .call_id = call_id,
        .tag = tag,
        .a0 = a0,
        .a1 = a1,
        .a2 = a2,
    };
}

// Try-post a message carrying an explicit correlation id (0 = not a call).
fn ipc_send_try_id(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64, call_id: u64) -> bool {
    let dst: usize = dst_pid as usize;
    if !proc_is_live(t, dst) {
        return false; // no such process, or it has exited/died — never post into a dead slot
    }
    let msg: Message = proc_make_msg(t, tag, a0, a1, a2, call_id);
    if mailbox_post(Message, IPC_SLOTS, &t.procs[dst].inbox, msg, t.procs[t.current].pid) {
        wake_if_blocked(t, dst);
        return true;
    }
    return false; // mailbox full
}

export fn ipc_send_try(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> bool {
    return ipc_send_try_id(t, dst_pid, tag, a0, a1, a2, 0);
}

// Endpoint-validated send: the hardened path. Rejects a stale endpoint (slot reused by a new
// generation, or freed/dead) with DeadEndpoint before touching any mailbox. `ok(false)` means
// the destination's mailbox was full.
// Endpoint-validated send carrying an explicit correlation id (0 = not a call).
fn ipc_send_ep_id(t: *mut ProcTable, ep: Endpoint, tag: u32, a0: u64, a1: u64, a2: u64, call_id: u64) -> Result<bool, EpError> {
    switch endpoint_slot(t, ep) {
        ok(dst) => {
            let msg: Message = proc_make_msg(t, tag, a0, a1, a2, call_id);
            if mailbox_post(Message, IPC_SLOTS, &t.procs[dst].inbox, msg, t.procs[t.current].pid) {
                wake_if_blocked(t, dst);
                return ok(true);
            }
            return ok(false); // mailbox full
        }
        err(e) => {
            return err(.DeadEndpoint);
        }
    }
}

export fn ipc_send_ep(t: *mut ProcTable, ep: Endpoint, tag: u32, a0: u64, a1: u64, a2: u64) -> Result<bool, EpError> {
    return ipc_send_ep_id(t, ep, tag, a0, a1, a2, 0);
}

// Bounded blocking send: retry up to `max_yields` times (yielding so the receiver can
// drain), returning false on timeout instead of spinning forever. Symmetric with
// ipc_receive_timeout — the timeout variant the blocking policy is layered over.
export fn ipc_send_timeout(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64, max_yields: u32) -> bool {
    var tries: u32 = 0;
    while tries <= max_yields {
        if ipc_send_try(t, dst_pid, tag, a0, a1, a2) {
            return true;
        }
        if tries == max_yields {
            return false; // timed out: mailbox stayed full
        }
        proc_yield(t);
        tries = tries + 1;
    }
    return false;
}

// Bounded blocking send with a TYPED outcome — the Result form of ipc_try_send/ipc_send_timeout.
// It distinguishes the three failure modes the bool variants conflate: a permission denial
// (allow_mask), a dead destination (never existed / exited), and a timeout (mailbox stayed full
// for the whole `max_yields` budget). `ok(true)` means delivered.
export fn ipc_send_result(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64, max_yields: u32) -> Result<bool, SendError> {
    let cur: usize = t.current;
    if !mask32_contains(&t.procs[cur].allow_mask, dst_pid) {
        return err(.Denied);
    }
    let dst: usize = dst_pid as usize;
    var tries: u32 = 0;
    while tries <= max_yields {
        if !proc_is_live(t, dst) {
            return err(.DeadTarget); // re-checked each attempt: the slot can die while we wait
        }
        if ipc_send_try(t, dst_pid, tag, a0, a1, a2) {
            return ok(true);
        }
        if tries == max_yields {
            return err(.Timeout);
        }
        proc_yield(t);
        tries = tries + 1;
    }
    return err(.Timeout);
}

// Send `tag`/payload to `dst_pid`. Blocks (yields) only while the mailbox is full. This is
// the unbounded blocking *policy*; callers that must not spin forever use ipc_send_try
// (non-blocking) or ipc_send_timeout (bounded) instead.
export fn ipc_send(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> void {
    let dst: usize = dst_pid as usize;
    var sending: bool = true;
    while sending {
        // Re-check liveness every iteration: a destination that never existed, or that exits
        // while we wait for mailbox room, must end the loop — otherwise ipc_send_try returns
        // false forever and we spin yielding against a dead slot.
        if !proc_is_live(t, dst) {
            return; // destination gone — give up rather than spin
        }
        if ipc_send_try(t, dst_pid, tag, a0, a1, a2) {
            return; // delivered
        }
        proc_yield_or_idle(t); // mailbox full -- let the receiver drain it, or idle if none runnable
    }
}

// Asynchronous notification: deliver if there is room, else drop (non-blocking). Like
// MINIX `notify` -- fire-and-forget, never blocks the sender.
export fn ipc_notify(t: *mut ProcTable, dst_pid: u32, tag: u32) -> bool {
    let dst: usize = dst_pid as usize;
    if !proc_is_live(t, dst) {
        return false; // never notify a free/exited/dead slot
    }
    let msg: Message = proc_make_msg(t, tag, 0, 0, 0, 0);
    if mailbox_post(Message, IPC_SLOTS, &t.procs[dst].inbox, msg, t.procs[t.current].pid) {
        wake_if_blocked(t, dst);
        return true;
    }
    return false; // mailbox full -- notification dropped
}

// Endpoint-validated notify: rejects a stale endpoint with DeadEndpoint; ok(false) = dropped
// because the mailbox was full.
export fn ipc_notify_ep(t: *mut ProcTable, ep: Endpoint, tag: u32) -> Result<bool, EpError> {
    switch endpoint_slot(t, ep) {
        ok(dst) => {
            let msg: Message = proc_make_msg(t, tag, 0, 0, 0, 0);
            if mailbox_post(Message, IPC_SLOTS, &t.procs[dst].inbox, msg, t.procs[t.current].pid) {
                wake_if_blocked(t, dst);
                return ok(true);
            }
            return ok(false);
        }
        err(e) => {
            return err(.DeadEndpoint);
        }
    }
}

// Blocking send carrying an explicit correlation id (0 = not a call). Blocks only while the
// destination mailbox is full; gives up if the destination is gone.
fn ipc_send_id(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64, call_id: u64) -> void {
    let dst: usize = dst_pid as usize;
    var sending: bool = true;
    while sending {
        if !proc_is_live(t, dst) {
            return; // destination gone — give up rather than spin
        }
        if ipc_send_try_id(t, dst_pid, tag, a0, a1, a2, call_id) {
            return;
        }
        proc_yield_or_idle(t);
    }
}

// Reply to a received request, echoing its correlation id so the original caller's
// ipc_call / ipc_call_ep matches this as *its* reply (and not an unrelated queued message).
// Servers should use this instead of a bare `ipc_send` back to `req.from`.
//
// The reply is delivered to the requester's *endpoint* — its slot AND the generation it held
// when it sent the request — not a bare pid. So if the requester exited and its slot was
// reused, the endpoint no longer validates and the reply is dropped rather than delivered to
// the new occupant of the slot.
export fn ipc_reply(t: *mut ProcTable, req: *Message, tag: u32, a0: u64, a1: u64, a2: u64) -> void {
    let ep: Endpoint = .{ .slot = req.from as usize, .gen = req.from_gen };
    var sending: bool = true;
    while sending {
        switch ipc_send_ep_id(t, ep, tag, a0, a1, a2, req.call_id) {
            ok(delivered) => {
                if delivered {
                    sending = false; // landed in the requester's still-valid mailbox
                } else {
                    proc_yield_or_idle(t); // mailbox full -- retry, re-validating the endpoint
                }
            }
            err(e) => {
                return; // the requesting incarnation is gone -- drop the reply
            }
        }
    }
}

// Match the reply to a synchronous call: it must come from the awaited endpoint (source slot
// AND the generation we called) and carry the request's correlation id.
struct ReplyMatch {
    src_pid: u32,
    gen: u32,
    call_id: u64,
}
fn reply_matches(e: *ReplyMatch, msg: *Message) -> bool {
    if msg.from != e.src_pid {
        return false;
    }
    if msg.from_gen != e.gen {
        return false;
    }
    if msg.call_id != e.call_id {
        return false;
    }
    return true;
}

// Receive the reply to a synchronous call. Only the matching reply is taken (via a content
// predicate); any other queued message — an unrelated notification, a second conversation from
// the same server, or a message from a stale incarnation — is LEFT in the mailbox rather than
// dropped, so a pending call never silently loses unrelated IPC. If the endpoint dies first, a
// DEAD result is synthesized out-of-band.
fn ipc_receive_reply(t: *mut ProcTable, ep: Endpoint, expected_call_id: u64, out: *mut Message) -> void {
    let src_pid: u32 = ep.slot as u32;
    var menv: ReplyMatch = .{ .src_pid = src_pid, .gen = ep.gen, .call_id = expected_call_id };
    let pred: closure(*Message) -> bool = bind(&menv, reply_matches);
    var got: bool = false;
    while !got {
        if mailbox_take_if(Message, IPC_SLOTS, &t.procs[t.current].inbox, pred, out) {
            got = true; // only the matching reply is ever taken; everything else stays queued
        } else {
            if !endpoint_live(t, ep) {
                let dead_msg: Message = .{ .from = src_pid, .from_gen = ep.gen, .call_id = expected_call_id, .tag = TAG_DEAD, .a0 = 0, .a1 = 0, .a2 = 0 };
                out.* = dead_msg;
                got = true;
            } else {
                t.procs[t.current].wait_slot = ep.slot;
                t.procs[t.current].wait_gen = ep.gen;
                proc_block(t, t.current, BLOCK_RECV);
                proc_yield_or_idle(t);
            }
        }
    }
    t.procs[t.current].wait_slot = MAX_PROCS;
    proc_unblock(t, t.current, BLOCK_RECV);
}

// sendrec: send a request to `dst_pid` and block for its reply, as one primitive. The reply
// is correlated by source endpoint (slot + generation) and call id, so a stale or unrelated
// queued message is never mistaken for the reply.
export fn ipc_call(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64, out: *mut Message) -> void {
    let dst: usize = dst_pid as usize;
    var dst_gen: u32 = 0;
    if dst < t.count {
        dst_gen = t.procs[dst].gen;
    }
    let ep: Endpoint = .{ .slot = dst, .gen = dst_gen };
    let call_id: u64 = t.next_call_id;
    t.next_call_id = t.next_call_id + 1;
    ipc_send_id(t, dst_pid, tag, a0, a1, a2, call_id);
    ipc_receive_reply(t, ep, call_id, out);
}

// Endpoint-validated sendrec — the recommended hardened call path. Rejects a stale endpoint
// up front (DeadEndpoint) rather than sending to whoever now occupies the slot. ipc_send_ep /
// ipc_notify_ep / ipc_call_ep are the primary IPC API; the raw-pid forms remain for callers
// that hold a pid directly (and self-validate via proc_is_live on every send).
export fn ipc_call_ep(t: *mut ProcTable, ep: Endpoint, tag: u32, a0: u64, a1: u64, a2: u64, out: *mut Message) -> Result<bool, EpError> {
    // Re-validate the endpoint on *every* delivery attempt via ipc_send_ep, not just once up
    // front. The blocking raw-pid path captured a pid and could deliver to a new incarnation if
    // the slot died and was reused while we waited for mailbox room; here, if the endpoint dies
    // before the message lands, the next ipc_send_ep fails DeadEndpoint instead of misdelivering.
    // A fresh correlation id for this call, stamped into the request so the reply can be
    // matched to it (and not to some unrelated queued message from the same server).
    let call_id: u64 = t.next_call_id;
    t.next_call_id = t.next_call_id + 1;
    var sending: bool = true;
    while sending {
        switch ipc_send_ep_id(t, ep, tag, a0, a1, a2, call_id) {
            ok(delivered) => {
                if delivered {
                    sending = false; // landed in the (still-valid) endpoint's mailbox
                } else {
                    proc_yield_or_idle(t); // mailbox full -- retry, re-validating the endpoint
                }
            }
            err(e) => {
                return err(.DeadEndpoint); // endpoint died/reused before delivery
            }
        }
    }
    // Receive only the reply to *this* call: from the exact endpoint incarnation we called
    // (slot + generation) and carrying this call's id. A plain receive would accept an
    // unrelated queued message; matching source generation rules out a reused slot, and
    // matching the call id rules out a stale/extra message from the live server.
    ipc_receive_reply(t, ep, call_id, out);
    return ok(true);
}

// Receive any message into `out`, blocking (yielding as BlockedRecv) until one arrives.
export fn ipc_receive(t: *mut ProcTable, out: *mut Message) -> void {
    var got: bool = false;
    while !got {
        got = mailbox_take(Message, IPC_SLOTS, &t.procs[t.current].inbox, out);
        if !got {
            proc_block(t, t.current, BLOCK_RECV);
            proc_yield_or_idle(t);
        }
    }
    proc_unblock(t, t.current, BLOCK_RECV); // clear the receive-block on the way out
}

// Receive with a timeout: poll the mailbox, yielding up to `max_yields` times. Returns
// true if a message was taken, false if it timed out (no infinite block). Polls as Ready
// (not BlockedRecv) so the scheduler keeps returning here to time out.
export fn ipc_receive_timeout(t: *mut ProcTable, out: *mut Message, max_yields: u32) -> bool {
    var tries: u32 = 0;
    while tries <= max_yields {
        if mailbox_take(Message, IPC_SLOTS, &t.procs[t.current].inbox, out) {
            return true;
        }
        if tries == max_yields {
            return false; // timed out
        }
        proc_yield(t);
        tries = tries + 1;
    }
    return false;
}

// Match a message to a specific source endpoint: the same slot AND the generation captured
// when the receive began. `mailbox_take_from` filters by slot only, so it would also accept a
// message left queued by an *older* incarnation of a since-reused slot; matching `from_gen`
// rejects that stale message, keeping the raw-pid receive capability-safe.
struct SourceMatch {
    src_pid: u32,
    gen: u32,
}
fn source_matches(e: *SourceMatch, msg: *Message) -> bool {
    if msg.from != e.src_pid {
        return false;
    }
    if msg.from_gen != e.gen {
        return false;
    }
    return true;
}

// Receive only a message from `src_pid`'s current incarnation, blocking until one arrives
// (source + generation filtering). A message from a stale incarnation of a reused slot is left
// in the mailbox, not delivered as if it were the awaited source.
export fn ipc_receive_from(t: *mut ProcTable, src_pid: u32, out: *mut Message) -> void {
    let src: usize = src_pid as usize;
    // Capture the awaited source's generation up front; if that exact incarnation dies, the
    // endpoint stops validating and we synthesize a DEAD result rather than blocking forever.
    var src_gen: u32 = 0;
    if src < t.count {
        src_gen = t.procs[src].gen;
    }
    let src_ep: Endpoint = .{ .slot = src, .gen = src_gen };
    var menv: SourceMatch = .{ .src_pid = src_pid, .gen = src_gen };
    let pred: closure(*Message) -> bool = bind(&menv, source_matches);
    var got: bool = false;
    while !got {
        // Match both source slot and the captured generation, so a stale message from an older
        // incarnation is not mistaken for the awaited source (and is left queued, not dropped).
        got = mailbox_take_if(Message, IPC_SLOTS, &t.procs[t.current].inbox, pred, out);
        if !got {
            // The awaited source died: stop waiting and report DEAD out-of-band (not via the
            // mailbox, which could be full) — guaranteed delivery of the dead-endpoint result.
            if !endpoint_live(t, src_ep) {
                let dead_msg: Message = .{ .from = src_pid, .from_gen = src_gen, .call_id = 0, .tag = TAG_DEAD, .a0 = 0, .a1 = 0, .a2 = 0 };
                out.* = dead_msg;
                got = true;
            } else {
                t.procs[t.current].wait_slot = src;
                t.procs[t.current].wait_gen = src_gen;
                proc_block(t, t.current, BLOCK_RECV);
                proc_yield_or_idle(t);
            }
        }
    }
    t.procs[t.current].wait_slot = MAX_PROCS;
    proc_unblock(t, t.current, BLOCK_RECV);
}
