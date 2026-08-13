// kernel/core/process — process lifecycle (spawn / run / exit) on top of the
// context-switch primitive. A process is a saved `Context` plus a lifecycle state
// and a pid. The table round-robins among runnable processes and, on `proc_exit`,
// marks the caller `Dead` and switches to the next runnable one — so a process can
// terminate (unlike a bare scheduler thread that runs forever). Slot 0 is the
// bootstrap (the kernel); when every spawned process has exited, control returns
// there. Cooperative for now (processes yield/exit); preemption is orthogonal.

import "kernel/arch/active/context.mc"; // arch-selection seam (R0b); --arch picks context, default riscv64
import "kernel/core/aspace.mc";
import "std/math.mc";
import "std/mask.mc";
import "kernel/lib/resacct.mc";
// Re-export the concerns split out of this file. MC imports are textual inclusion deduped
// by path, so every existing `import "kernel/core/process.mc"` consumer transitively gets
// the full process scheduling API without changing any consumer import site.
import "kernel/core/proc_sched.mc";

const MAX_PROCS: usize = 8;

enum ProcState {
    Unused,
    Ready,
    Running,
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

// Block reasons (bits in Process.block_reasons). A process is runnable only when its block
// set is empty — runnable state is *derived* from these flags, not set ad hoc, so a missed
// state transition can't leave a blocked process on the run queue.
const BLOCK_PARK: u32 = 0; // generic parked process
const BLOCK_WAIT: u32 = 1; // waiting for a child to exit

struct Process {
    context: Context,
    state: ProcState,
    pid: u32,
    gen: u32,       // generation: bumped each time this slot is reused
    parent: u32,    // pid of the spawning process (display/debug identity)
    parent_slot: usize, // spawning process slot, paired with parent_gen
    parent_gen: u32,    // spawning process generation; prevents stale-parent reuse
    exit_code: u32, // valid once state == Zombie
    aspace: AddressSpace, // this process's address space (opaque arch root); kernel() = share kernel's
    block_reasons: Mask32,       // set of BLOCK_* reasons; runnable iff empty (derived state)
    priority: u32,               // scheduling priority (policy set externally; higher runs first)
    quantum: u32,                // remaining scheduling quantum in ticks (0 = expired)
    ticks: u64,                  // saturating long-running accounting; never traps on uptime
    throttle: u32,               // fair-share throttle penalty (added to effective ticks; see proc_throttle)
    macct: ResourceAccount,      // per-process memory account; reset on spawn (fresh, from zero) and on exit
}

const QUANTUM_DEFAULT: u32 = 10;
// A generous default per-process memory quota. This is bookkeeping only for now; real policy
// (and wiring into the allocator) comes later — kept as validation bookkeeping.
const MEM_QUOTA_DEFAULT: usize = 0x100000;

struct ProcTable {
    procs: [MAX_PROCS]Process,
    count: usize,   // slots in use (slot 0 = bootstrap)
    current: usize, // running slot
    // The platform's CPU-idle action (e.g. `wfi`), invoked when a process blocks and nothing
    // else is runnable — so the kernel sleeps until an interrupt instead of busy-spinning as a
    // blocked "current" process. Defaults to a no-op (set by the platform via proc_set_idle).
    idle_hook: fn() -> void,
    // Global resource-cleanup hook, invoked with (dead pid, dead gen) when a process dies, so
    // subsystems that hold per-owner resources (grant tables, service registries, …) can revoke
    // everything the dead process owned. The process table stays decoupled from those subsystems:
    // whoever owns them registers a function pointer via proc_set_death_hook. Defaults to a no-op.
    death_hook: fn(u32, u32) -> void,
}

// The no-op default idle action.
fn idle_noop() -> void {}

// The no-op default death hook.
fn death_noop(pid: u32, gen: u32) -> void {
    let _pid: u32 = pid;
    let _gen: u32 = gen;
}

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
        t.procs[i].aspace = AddressSpace.kernel(); // share the kernel map until given one
        t.procs[i].block_reasons = mask32_zero();
        t.procs[i].priority = 0;
        t.procs[i].quantum = QUANTUM_DEFAULT;
        t.procs[i].ticks = 0;
        t.procs[i].throttle = 0;
        resacct_init(&t.procs[i].macct, MEM_QUOTA_DEFAULT);
        i = i + 1;
    }
    // Slot 0 is the running bootstrap context (filled on first switch out).
    t.procs[0].state = .Running;
    t.count = 1;
    t.current = 0;
    t.idle_hook = idle_noop; // platform overrides with wfi via proc_set_idle
    t.death_hook = death_noop; // subsystems override via proc_set_death_hook
}

// Set the platform's CPU-idle action (e.g. a `wfi` wrapper). Called when the scheduler has
// nothing runnable, so a blocked kernel sleeps instead of spinning. The wfi itself lives in
// arch code (this module stays host-portable); the platform installs it at boot.
#[mc_abi]
export fn proc_set_idle(t: *mut ProcTable, hook: fn() -> void) -> void {
    t.idle_hook = hook;
}

// Run the platform idle action once (sleep until an interrupt, on a real machine).
fn proc_idle(t: *mut ProcTable) -> void {
    let hook: fn() -> void = t.idle_hook;
    hook();
}

// Install the global resource-cleanup hook, run with (pid, gen) on every process death.
// Validation fixtures can use this to release resources owned by the dead process.
#[mc_abi]
export fn proc_set_death_hook(t: *mut ProcTable, hook: fn(u32, u32) -> void) -> void {
    t.death_hook = hook;
}

#[mc_abi]
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
    t.procs[slot].gen = t.procs[slot].gen + 1; // a new incarnation
    t.procs[slot].parent = t.procs[t.current].pid; // the spawner is the parent
    t.procs[slot].parent_slot = t.current;
    t.procs[slot].parent_gen = t.procs[t.current].gen;
    t.procs[slot].exit_code = 0;
    // Reset per-process state in case this slot was reaped from an earlier process.
    t.procs[slot].block_reasons = mask32_zero();
    t.procs[slot].priority = 0;
    t.procs[slot].quantum = QUANTUM_DEFAULT;
    t.procs[slot].ticks = 0;
        t.procs[slot].throttle = 0;       // a reused slot must not inherit the old process's scheduler state
    // A fresh process starts at zero memory usage — it does NOT inherit the parent's usage.
    // Re-init in case this slot was reaped from an earlier (possibly heavily-charged) process.
    resacct_init(&t.procs[slot].macct, MEM_QUOTA_DEFAULT);
    return slot as u32;
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
#[mc_abi]
export fn proc_charge_mem(t: *mut ProcTable, slot: usize, n: usize) -> Result<usize, MemError> {
    return resacct_charge(proc_macct(t, slot), n);
}

// Release `n` units previously charged to process `slot` (on free). Saturates at zero.
export fn proc_uncharge_mem(t: *mut ProcTable, slot: usize, n: usize) -> void {
    resacct_uncharge(proc_macct(t, slot), n);
}

// Replace a process's executable image in place. The saved context is reset to start `entry`
// on a fresh stack, but the process keeps its identity (same pid and generation, so existing
// endpoints stay valid). Run accounting is reset for the new image; privileges and scheduling
// policy are kept.
// The slot must hold a live (non-Unused) process. In the integrated boot path `entry` is the
// ELF entry point from elf_parse_header (kernel/core/elf) once its LOAD segments are mapped.
#[mc_abi]
export fn proc_exec(t: *mut ProcTable, slot: usize, stack_top: usize, entry: fn() -> void) -> void {
    mc_thread_init(&t.procs[slot].context, stack_top, entry);
    t.procs[slot].exit_code = 0;
    t.procs[slot].ticks = 0;
    t.procs[slot].quantum = QUANTUM_DEFAULT;
}

// The pid of the currently-running process.
export fn proc_self(t: *mut ProcTable) -> u32 {
    return t.procs[t.current].pid;
}

// Central process-death cleanup: release retained per-process accounting through one hook.
fn proc_death_cleanup(t: *mut ProcTable, dead: usize) -> void {
    let dead_gen: u32 = t.procs[dead].gen;
    let dead_pid: u32 = t.procs[dead].pid;
    // Revoke resources the dead process owned through the installed hook.
    // through the installed hook, before the slot is reused. Decoupled: the hook is
    // whatever the subsystem owner registered (a no-op if none).
    let death_hook: fn(u32, u32) -> void = t.death_hook;
    death_hook(dead_pid, dead_gen);
    resacct_reset(&t.procs[dead].macct); // a zombie holds no charged memory — release the account
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
#[mc_abi]
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
#[mc_abi]
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

// Give process `idx` its own address space. 0 keeps the kernel map. The stored handle is
// the opaque AddressSpace, while the accessor accepts the raw arch root word at the FFI
// boundary and wraps it immediately.
export fn proc_set_satp(t: *mut ProcTable, idx: usize, satp: u64) -> void {
    t.procs[idx].aspace = AddressSpace.from_root(satp);
}

export fn proc_satp(t: *mut ProcTable, idx: usize) -> u64 {
    return AddressSpace.raw(t.procs[idx].aspace);
}

export fn proc_pid(t: *mut ProcTable) -> u32 {
    return t.procs[t.current].pid;
}
