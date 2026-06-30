// kernel/core/process — process lifecycle (spawn / run / exit) on top of the
// context-switch primitive. A process is a saved `Context` plus a lifecycle state
// and a pid. The table round-robins among runnable processes and, on `proc_exit`,
// marks the caller `Dead` and switches to the next runnable one — so a process can
// terminate (unlike a bare scheduler thread that runs forever). Slot 0 is the
// bootstrap (the kernel); when every spawned process has exited, control returns
// there. Cooperative for now (processes yield/exit); preemption is orthogonal.

import "kernel/arch/active/context.mc"; // arch-selection seam (R0b); --arch picks context, default riscv64
import "kernel/core/aspace.mc";
import "kernel/core/ipc.mc";
import "std/math.mc";
import "std/mask.mc";
import "kernel/lib/mailbox.mc";
import "kernel/lib/fdspace.mc";
import "kernel/lib/resacct.mc";
// Re-export the concerns split out of this file. MC imports are textual inclusion deduped
// by path, so every existing `import "kernel/core/process.mc"` consumer transitively gets
// the full process API (scheduling, signals, IPC) without changing any consumer import site.
import "kernel/core/proc_sched.mc";
import "kernel/core/proc_signals.mc";
import "kernel/core/proc_ipc.mc";
import "kernel/core/ipc_trace.mc"; // capability-use audit trace (also pulled transitively via proc_ipc)

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
    aspace: AddressSpace, // this process's address space (opaque arch root); kernel() = share kernel's
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
    throttle: u32,               // fair-share throttle penalty (added to effective ticks; see proc_throttle)
    hb_deadline: u64,            // supervision: max ticks allowed between heartbeats (0 = unsupervised)
    hb_last: u64,                // supervision: tick of the most recent heartbeat
    restart_count: u32,          // supervision: restarts attempted this incarnation (crash-loop guard)
    fds: FdSpace,                // open file descriptors; copied to a child on spawn (fork), kept across exec
    macct: ResourceAccount,      // per-process memory account; reset on spawn (fresh, from zero) and on exit
}

const QUANTUM_DEFAULT: u32 = 10;
// A generous default per-process memory quota. This is bookkeeping only for now; real policy
// (and wiring into the allocator) comes later — see the agent-os memory-accounting backlog.
const MEM_QUOTA_DEFAULT: usize = 0x100000;

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

// How many messages are pending in a process's inbox (introspection: for an info/sched service).
export fn proc_inbox_count(t: *mut ProcTable, pid: u32) -> usize {
    let p: usize = pid as usize;
    if p < t.count {
        return mailbox_count(Message, IPC_SLOTS, &t.procs[p].inbox);
    }
    return 0;
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
        t.procs[i].aspace = AddressSpace.kernel(); // share the kernel map until given one
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
        t.procs[i].throttle = 0;
        t.procs[i].hb_deadline = 0;
        t.procs[i].hb_last = 0;
        t.procs[i].restart_count = 0;
        fd_init(&t.procs[i].fds);
        resacct_init(&t.procs[i].macct, MEM_QUOTA_DEFAULT);
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
    t.procs[slot].throttle = 0;       // a reused slot must not inherit the old process's scheduler state
    t.procs[slot].hb_deadline = 0;    // ... supervision: not supervised until re-enrolled
    t.procs[slot].hb_last = 0;
    t.procs[slot].restart_count = 0;  // ... crash-loop count starts fresh for the new incarnation
    // fork fd semantics: the child inherits a COPY of the spawner's open descriptors at the
    // same fd numbers, sharing the underlying resources. Clear any stale fds from a reaped
    // slot first. (Empty child + equal capacity ⇒ inherit can never overflow.)
    fd_init(&t.procs[slot].fds);
    switch fd_inherit(&t.procs[t.current].fds, &t.procs[slot].fds) {
        ok(n) => {}
        err(e) => {}
    }
    // A fresh process starts at zero memory usage — it does NOT inherit the parent's usage.
    // Re-init in case this slot was reaped from an earlier (possibly heavily-charged) process.
    resacct_init(&t.procs[slot].macct, MEM_QUOTA_DEFAULT);
    return slot as u32;
}

// Attenuated spawn: like proc_spawn, but the child is granted a SUBSET of the spawning
// process's authority — never more. proc_spawn gives a child empty masks (least privilege);
// this variant instead sets the child's masks to the intersection of the parent's authority
// (t.current, the spawner) and the requested subset. A bit the parent lacks can never appear
// in the child even if `*_subset` requests it (intersection is monotone-decreasing). Mask32
// has no intersect op, so we AND the raw bits via mask32_raw and rebuild with mask32_from.
export fn proc_spawn_attenuated(t: *mut ProcTable, stack_top: usize, entry: fn() -> void, allow_subset: Mask32, kcall_subset: Mask32) -> u32 {
    let pid: u32 = proc_spawn(t, stack_top, entry); // spawns with empty masks; parent = t.current
    let slot: usize = pid as usize;
    var parent_allow: Mask32 = t.procs[t.current].allow_mask;
    var parent_kcall: Mask32 = t.procs[t.current].kcall_mask;
    var allow_sub: Mask32 = allow_subset;
    var kcall_sub: Mask32 = kcall_subset;
    let allow_bits: u32 = mask32_raw(&parent_allow) & mask32_raw(&allow_sub);
    let kcall_bits: u32 = mask32_raw(&parent_kcall) & mask32_raw(&kcall_sub);
    t.procs[slot].allow_mask = mask32_from(allow_bits);
    t.procs[slot].kcall_mask = mask32_from(kcall_bits);
    return pid;
}

// Read a process's IPC allow-mask / kernel-call mask (introspection, e.g. for tests and a
// policy server). Returned by value — Mask32 is a single-field struct, trivially copyable.
export fn proc_allow_mask(t: *mut ProcTable, slot: usize) -> Mask32 {
    return t.procs[slot].allow_mask;
}

export fn proc_kcall_mask(t: *mut ProcTable, slot: usize) -> Mask32 {
    return t.procs[slot].kcall_mask;
}

// A mutable handle to a process's open-file-descriptor space — for the syscall surface and
// fork/exec wiring to populate, inherit, and inspect a process's fds.
export fn proc_fds(t: *mut ProcTable, slot: usize) -> *mut FdSpace {
    return &t.procs[slot].fds;
}

// A mutable handle to a process's memory ResourceAccount — for the allocator to charge/uncharge
// against, and for policy/introspection to read. Released (reset to zero) when the process exits.
export fn proc_macct(t: *mut ProcTable, slot: usize) -> *mut ResourceAccount {
    return &t.procs[slot].macct;
}

// ----- P0.4: per-process allocation accounting (the allocator's charge hook) -----
//
// The allocator path consults these on every grow/shrink of a process's memory footprint, so a
// process can never reserve more than its quota. Both delegate to the process's ResourceAccount.

// Charge `n` units against process `slot`'s memory quota. All-or-nothing (fail closed): on
// success returns the new used total; on failure returns err(.OverQuota) and reserves nothing,
// so the allocator can treat an over-quota charge as a clean no-op and refuse the allocation.
export fn proc_charge_mem(t: *mut ProcTable, slot: usize, n: usize) -> Result<usize, MemError> {
    return resacct_charge(proc_macct(t, slot), n);
}

// Release `n` units previously charged to process `slot` (on free). Saturates at zero.
export fn proc_uncharge_mem(t: *mut ProcTable, slot: usize, n: usize) -> void {
    resacct_uncharge(proc_macct(t, slot), n);
}

// ----- P0.5: LIVE reclaim — OOM-kill a runaway that won't exit (the safety keystone) -----
//
// A cooperative process exits via proc_exit and releases its resources. A *runaway* agent never
// does: it allocates without bound and stays LIVE, so its memory account and fds are never
// released. Without an external reclaim mechanism such a process can OOM the host — defeating the
// whole agent-OS isolation thesis. These three functions are that mechanism: select the worst
// live offender, forcibly terminate it (reusing the exact death-cleanup path proc_exit runs), and
// reclaim its resources, while every other agent survives untouched. The heap/allocator calls
// proc_oom_reclaim when it hits exhaustion (wiring that single call site into heap.mc is a
// follow-up); the selection + kill + reclaim mechanism is delivered and tested here.

enum OomError {
    NoVictim, // no live, non-bootstrap process exists to reclaim — nothing to kill
}

// A sentinel exit code marking a process that was OOM-killed (vs. a clean self-exit). A parent
// reaping the zombie sees this code and can distinguish a forced reclaim from a normal exit.
const OOM_KILLED_CODE: u32 = 0xDEAD_00F0;

// Select the OOM-kill victim: the live (proc_is_live), non-bootstrap (slot 0 is the kernel
// bootstrap and is never a victim) process with the HIGHEST current memory usage — the worst
// offender, the most likely runaway. Returns its slot, or err(.NoVictim) if no eligible process
// exists. Pure selection: makes no state changes.
export fn proc_oom_victim(t: *mut ProcTable) -> Result<usize, OomError> {
    var best: usize = MAX_PROCS; // sentinel: no victim found yet
    var best_used: usize = 0;
    var found: bool = false;
    var i: usize = 1; // skip slot 0 (bootstrap)
    while i < t.count {
        if proc_is_live(t, i) {
            let used: usize = resacct_used(proc_macct(t, i));
            if !found {
                best = i;
                best_used = used;
                found = true;
            } else {
                if used > best_used {
                    best = i;
                    best_used = used;
                }
            }
        }
        i = i + 1;
    }
    if !found {
        return err(.NoVictim);
    }
    return ok(best);
}

// Forcibly terminate a LIVE process (the runaway) that is NOT the current process — the victim
// is not running, so we never context-switch. Runs the same proc_death_cleanup that proc_exit
// runs (releasing fds, resetting the memory account, clearing IPC, waking blocked waiters), then
// marks the slot a Zombie with the OOM sentinel exit code and wakes its parent (mirroring
// proc_exit's parent-wake) so the death can be reaped like any other. Idempotent guard: a no-op
// if the slot isn't a live, non-current victim, so a double-kill or a bad slot can't corrupt
// state. After this the killed agent's memory and fds are reclaimed; the slot is later reaped
// like any zombie.
export fn proc_oom_kill(t: *mut ProcTable, slot: usize) -> void {
    if slot == t.current {
        return; // never kill the running process via this path (it isn't the runaway)
    }
    if !proc_is_live(t, slot) {
        return; // already dead/zombie/free — nothing to reclaim
    }
    t.procs[slot].exit_code = OOM_KILLED_CODE; // recognizable: OOM-killed, not a clean exit
    proc_death_cleanup(t, slot); // SAME path as proc_exit: fds + macct + IPC + waiters released
    t.procs[slot].state = .Zombie; // a parent can still reap its death
    // Wake the parent if it is blocked in proc_wait — this forced exit is the event it awaits.
    let parent_slot: usize = t.procs[slot].parent_slot;
    if parent_slot < t.count {
        if t.procs[parent_slot].gen == t.procs[slot].parent_gen {
            proc_unblock(t, parent_slot, BLOCK_WAIT);
        }
    }
    // Deliberately NO context switch: the victim is not the running process.
}

// The memory-pressure entry point: pick the worst live offender (proc_oom_victim) and OOM-kill
// it (proc_oom_kill), returning the reclaimed slot. err(.NoVictim) if there is nothing to kill.
// The heap/allocator calls this on allocation exhaustion to reclaim memory from a runaway agent.
export fn proc_oom_reclaim(t: *mut ProcTable) -> Result<usize, OomError> {
    switch proc_oom_victim(t) {
        ok(slot) => {
            proc_oom_kill(t, slot);
            return ok(slot);
        }
        err(e) => {
            return err(e);
        }
    }
}

// ----- F1: fault isolation — contain a recoverable agent fault (kill+reclaim, kernel survives) --
//
// The OOM keystone above kills a NON-current runaway (it never context-switches). A FAULT is the
// dual case: the faulting agent IS the one executing when the trap fires, so the kill path must be
// allowed to terminate `t.current` and the trap handler resumes the KERNEL afterwards (the dead
// agent never runs again). To classify a trap, the kernel marks which agent owns the CPU before
// handing it control (its "fault domain"); the trap handler reads that marker to decide whether a
// synchronous fault is recoverable-in-agent (an agent was running -> contain) or fatal-kernel
// (no agent was running, i.e. the fault is the kernel's own -> panic + halt).

// Sentinel exit code for an agent terminated by a contained fault (vs OOM_KILLED_CODE / a clean
// exit). A parent reaping the zombie can tell a fault-kill apart from an OOM-kill or normal exit.
const FAULT_KILLED_CODE: u32 = 0xDEAD_00F1;

// No agent currently owns the CPU (the kernel itself is running): a synchronous fault here is the
// kernel's own and must stay fatal. MAX_PROCS is never a valid slot, so it is the "no domain" mark.
global g_fault_domain: usize = MAX_PROCS;

// Enter an agent's fault domain: record that `slot` owns the CPU, so a trap that fires now is
// attributable to that agent. Call immediately before transferring control into agent code.
// Mirrors setting `t.current`, but is the authority the *trap handler* consults (it runs in an
// arbitrary context and must not guess). A bad/non-live slot leaves the domain cleared (fail-safe:
// an unattributable fault then classifies as fatal-kernel rather than killing an innocent agent).
export fn proc_enter_agent(t: *mut ProcTable, slot: usize) -> void {
    if proc_is_live(t, slot) {
        t.current = slot;
        g_fault_domain = slot;
    } else {
        g_fault_domain = MAX_PROCS;
    }
}

// Leave the current fault domain (the agent returned cleanly): subsequent faults are the kernel's
// until the next proc_enter_agent. Idempotent.
export fn proc_leave_agent(t: *mut ProcTable) -> void {
    g_fault_domain = MAX_PROCS;
}

// The slot of the agent that currently owns the CPU, or err(.NoVictim) if the kernel itself is
// running (no fault domain marked). This is the trap handler's classifier: ok => a fault is a
// recoverable agent fault; err => a fault is fatal-kernel.
export fn proc_fault_domain(t: *mut ProcTable) -> Result<usize, OomError> {
    if g_fault_domain == MAX_PROCS {
        return err(.NoVictim);
    }
    if !proc_is_live(t, g_fault_domain) {
        return err(.NoVictim); // domain marks a non-live slot — treat as unattributable
    }
    return ok(g_fault_domain);
}

// Contain a recoverable agent fault: forcibly terminate the FAULTING agent `slot` (which is the
// one that owned the CPU, == g_fault_domain) and reclaim its resources through the SAME death path
// the OOM-kill and proc_exit use (fds + memory account + IPC + waiters released), mark it a Zombie
// with the fault sentinel, and wake its parent so the death reaps like any other. Unlike
// proc_oom_kill this is ALLOWED to kill the current slot (the fault victim is, by definition, the
// running agent); it then clears the fault domain so the kernel — which the trap handler resumes
// next — runs outside any agent. Idempotent guard: a no-op on a non-live or out-of-range slot.
// Deliberately performs NO context switch: the trap handler advances past the faulting instruction
// and `mret`s back into the kernel; the dead agent's saved context is simply never scheduled again.
export fn proc_fault_kill(t: *mut ProcTable, slot: usize) -> void {
    if slot >= t.count {
        return;
    }
    if !proc_is_live(t, slot) {
        return; // already dead/zombie/free — nothing to reclaim
    }
    t.procs[slot].exit_code = FAULT_KILLED_CODE; // recognizable: contained-fault kill
    proc_death_cleanup(t, slot); // SAME path as proc_exit/proc_oom_kill: fds + macct + IPC + waiters
    t.procs[slot].state = .Zombie; // a parent can still reap its death
    let parent_slot: usize = t.procs[slot].parent_slot;
    if parent_slot < t.count {
        if t.procs[parent_slot].gen == t.procs[slot].parent_gen {
            proc_unblock(t, parent_slot, BLOCK_WAIT);
        }
    }
    if g_fault_domain == slot {
        g_fault_domain = MAX_PROCS; // the faulting agent is gone; the kernel runs next
    }
}

// The fault-path entry point the trap handler calls: classify (is a fault attributable to a live
// agent?) and, if so, contain it (kill+reclaim the faulting agent) — returning ok(slot) of the
// reclaimed agent. err(.NoVictim) means the fault is NOT attributable to any agent (the kernel's
// own fault), so the handler must keep it fatal (panic + halt) instead of recovering.
export fn proc_fault_contain(t: *mut ProcTable) -> Result<usize, OomError> {
    switch proc_fault_domain(t) {
        ok(slot) => {
            proc_fault_kill(t, slot);
            return ok(slot);
        }
        err(e) => {
            return err(e);
        }
    }
}

// Replace a process's executable image in place — exec() semantics. The saved context is reset
// to start `entry` on a fresh stack, but the process KEEPS its identity (same pid and
// generation, so existing endpoints stay valid) and, crucially, its open file descriptors:
// fork COPIES a process's fds to the child (proc_spawn), exec PRESERVES them across the image
// swap. Run accounting is reset for the new image; privileges and scheduling policy are kept.
// The slot must hold a live (non-Unused) process. In the integrated boot path `entry` is the
// ELF entry point from elf_parse_header (kernel/core/elf) once its LOAD segments are mapped.
export fn proc_exec(t: *mut ProcTable, slot: usize, stack_top: usize, entry: fn() -> void) -> void {
    mc_thread_init(&t.procs[slot].context, stack_top, entry);
    t.procs[slot].exit_code = 0;
    t.procs[slot].ticks = 0;
    t.procs[slot].quantum = QUANTUM_DEFAULT;
    // fds are deliberately untouched — preserved across exec (the fork/exec distinction).
}

// The pid of the currently-running process.
export fn proc_self(t: *mut ProcTable) -> u32 {
    return t.procs[t.current].pid;
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

// IRQ-safe endpoint validation: the same generation/state check as `endpoint_slot`, but it
// returns the slot index on success or `sentinel` on a stale/dead endpoint — NO `Result`. The
// `Result`-constructing `endpoint_slot` cannot be `#[irq_context]` (each `ok(..)`/`err(..)` lowers
// to a call-like instruction the MIR irq-context verifier rejects); this sentinel form is what the
// ISR wake path (`wq_wake_one` <- `async_complete`) calls. Pass `t.count` as the sentinel (no live
// slot equals it) and check `< t.count`.
#[irq_context]
export fn endpoint_slot_or(t: *mut ProcTable, ep: Endpoint, sentinel: usize) -> usize {
    if ep.slot >= t.count {
        return sentinel;
    }
    if t.procs[ep.slot].gen != ep.gen {
        return sentinel;
    }
    let s: ProcState = t.procs[ep.slot].state;
    if s == .Unused {
        return sentinel;
    }
    if s == .Zombie {
        return sentinel;
    }
    if s == .Dead {
        return sentinel;
    }
    return ep.slot;
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
    resacct_reset(&t.procs[dead].macct); // a zombie holds no charged memory — release the account
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

// Give process `idx` its own address space. A context switch into this process loads it
// (see the vmspace demo); 0 keeps the kernel map. The stored handle is the opaque
// AddressSpace, but the accessor keeps a raw `u64` because C runtimes (vmspace/vmctx) call
// it: the raw satp word is wrapped on the way in and unwrapped on the way out, so the
// arch-encoded value crosses the FFI unchanged while core stores it opaquely.
export fn proc_set_satp(t: *mut ProcTable, idx: usize, satp: u64) -> void {
    t.procs[idx].aspace = AddressSpace.from_root(satp);
}

export fn proc_satp(t: *mut ProcTable, idx: usize) -> u64 {
    return AddressSpace.raw(t.procs[idx].aspace);
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

// ----- capability-use audit (P1.3): observe-only trace of kcall invocations -----
//
// A DEDICATED provenance ring, disjoint from proc_ipc's `g_ipc_trace`. Where the IPC
// trace records *messages* (who sent what to whom), this records *authority use*: each
// time a process exercises its `kcall_mask` to invoke a kernel op, we append one event
// (from=caller pid, tag=op). The audit is pure observation — it never changes kcall's
// permission decision or its return value. Off the critical path by construction
// (`ipc_trace_record` is O(1), non-blocking, overwrite-oldest on overflow).
global g_cap_trace: IpcTrace;
global g_cap_audit_enabled: bool = true; // default enabled; opt out via cap_audit_set_enabled

// Reset the cap-audit ring to empty. Call after proc_table_init in any context that
// wants a clean audit history.
export fn cap_audit_init() -> void {
    ipc_trace_init(&g_cap_trace);
}

// The dedicated cap-use trace, for a drainer to read back recorded authority use.
export fn cap_audit() -> *mut IpcTrace {
    return &g_cap_trace;
}

// Toggle cap-use recording. When off, kcall behaves identically but emits no events.
export fn cap_audit_set_enabled(on: bool) -> void {
    g_cap_audit_enabled = on;
}

// Kernel-call gateway: a server requests a privileged op through one checked entry
// point. Denied unless the caller's kcall_mask permits `op`. (The op itself is a
// stand-in here; a real kernel would map/grant/program IRQs behind this gate.)
export fn kcall(t: *mut ProcTable, op: u32, arg: u64) -> Result<u64, KError> {
    let cur: usize = t.current;
    // Capability-use audit: record the invocation BEFORE the permission decision, so the
    // trace covers every attempt to exercise authority (allowed or denied), not just the
    // ops that happened to pass the mask check. Observe-only — does not affect the result.
    if g_cap_audit_enabled {
        let caller_pid: u32 = t.procs[cur].pid;
        ipc_trace_record(&g_cap_trace, caller_pid, 0, op, 0);
    }
    if !mask32_contains(&t.procs[cur].kcall_mask, op) {
        return err(.Denied);
    }
    return ok(arg); // performed (stand-in for the privileged operation's result)
}
