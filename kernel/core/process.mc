// kernel/core/process — process lifecycle (spawn / run / exit) on top of the
// context-switch primitive. A process is a saved `Context` plus a lifecycle state
// and a pid. The table round-robins among runnable processes and, on `proc_exit`,
// marks the caller `Dead` and switches to the next runnable one — so a process can
// terminate (unlike a bare scheduler thread that runs forever). Slot 0 is the
// bootstrap (the kernel); when every spawned process has exited, control returns
// there. Cooperative for now (processes yield/exit); preemption is orthogonal.

import "kernel/arch/riscv64/context.mc";

const MAX_PROCS: usize = 8;

enum ProcState {
    Unused,
    Ready,
    Running,
    Zombie, // exited, awaiting reap by its parent
    Dead,
}

// Reasons a wait/reap finds nothing.
enum ReapError {
    NoChildren,  // the caller has no children
    NoZombieYet, // children exist but none have exited
}

struct Process {
    context: Context,
    state: ProcState,
    pid: u32,
    parent: u32,    // pid of the spawning process
    exit_code: u32, // valid once state == Zombie
    satp: u64,      // this process's address space (Sv39 root); 0 = share the kernel's
}

struct ProcTable {
    procs: [MAX_PROCS]Process,
    count: usize,   // slots in use (slot 0 = bootstrap)
    current: usize, // running slot
}

fn is_runnable(s: ProcState) -> bool {
    return s == .Ready || s == .Running;
}

export fn proc_table_init(t: *mut ProcTable) -> void {
    var i: usize = 0;
    while i < MAX_PROCS {
        t.procs[i].state = .Unused;
        t.procs[i].pid = 0;
        t.procs[i].parent = 0;
        t.procs[i].exit_code = 0;
        t.procs[i].satp = 0;
        i = i + 1;
    }
    // Slot 0 is the running bootstrap context (filled on first switch out).
    t.procs[0].state = .Running;
    t.count = 1;
    t.current = 0;
}

export fn proc_spawn(t: *mut ProcTable, stack_top: usize, entry: fn() -> void) -> u32 {
    let slot: usize = t.count;
    if slot >= MAX_PROCS {
        unreachable; // process table full
    }
    mc_thread_init(&t.procs[slot].context, stack_top, entry);
    t.procs[slot].state = .Ready;
    t.procs[slot].pid = slot as u32;
    t.procs[slot].parent = t.procs[t.current].pid; // the spawner is the parent
    t.procs[slot].exit_code = 0;
    t.count = t.count + 1;
    return slot as u32;
}

// The next runnable slot after `from` (round-robin), or `from` if none other.
fn next_runnable(t: *mut ProcTable, from: usize) -> usize {
    var i: usize = 1;
    while i <= MAX_PROCS {
        let idx: usize = (from + i) % MAX_PROCS;
        if idx < t.count {
            let s: ProcState = t.procs[idx].state;
            if is_runnable(s) {
                return idx;
            }
        }
        i = i + 1;
    }
    return from;
}

// Cooperatively yield to the next runnable process. No-op if none other is ready.
export fn proc_yield(t: *mut ProcTable) -> void {
    let from: usize = t.current;
    let to: usize = next_runnable(t, from);
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

// Cooperatively yield, switching the address space too: the next process's page
// table (its `satp`) is loaded as part of the context switch, so each process runs in
// its own address space. Requires paging (S-mode). No-op if none other is ready.
export fn proc_yield_vm(t: *mut ProcTable) -> void {
    let from: usize = t.current;
    let to: usize = next_runnable(t, from);
    if to == from {
        return;
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

// Terminate the current process with an exit code and switch to the next runnable
// one. Never returns to the caller (its slot is now a Zombie awaiting reap).
export fn proc_exit(t: *mut ProcTable, code: u32) -> void {
    let from: usize = t.current;
    t.procs[from].exit_code = code;
    t.procs[from].state = .Zombie;
    let to: usize = next_runnable(t, from);
    t.procs[to].state = .Running;
    t.current = to;
    mc_switch_context(&t.procs[from].context, &t.procs[to].context);
}

// Reap one exited child of `parent_pid`: return its (pid, exit_code) packed as
// (pid << 32 | code) and free the slot. A non-blocking `wait` — errors if the caller
// has no children, or has children but none have exited yet (the caller can yield
// and retry). Reaping is what turns a Zombie back into a free (Unused) slot.
export fn proc_reap(t: *mut ProcTable, parent_pid: u32) -> Result<u64, ReapError> {
    var any_child: bool = false;
    var i: usize = 0;
    while i < t.count {
        let pid: u32 = t.procs[i].pid;
        let par: u32 = t.procs[i].parent;
        if par == parent_pid {
            if pid != parent_pid { // never the parent's own slot
                let st: ProcState = t.procs[i].state;
                if st == .Zombie {
                    let code: u32 = t.procs[i].exit_code;
                    t.procs[i].state = .Unused;
                    return ok(((pid as u64) << 32) | (code as u64));
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
// the reaped child's (pid << 32 | code), or `NoChildren` if the caller has none.
export fn proc_wait(t: *mut ProcTable, parent_pid: u32) -> Result<u64, ReapError> {
    var result: u64 = 0;
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
                proc_yield(t); // NoZombieYet: run the children, then retry
            }
        }
    }
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
