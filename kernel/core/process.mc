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
import "std/mailbox.mc";

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

struct Process {
    context: Context,
    state: ProcState,
    pid: u32,
    parent: u32,    // pid of the spawning process
    exit_code: u32, // valid once state == Zombie
    satp: u64,      // this process's address space (Sv39 root); 0 = share the kernel's
    inbox: Mailbox<Message, IPC_SLOTS>, // multi-slot mailbox for kernel-mediated IPC
    pending_sig: Mask32,         // pending-signal set (a PM server builds on this)
    allow_mask: Mask32,          // least privilege: bit p = may IPC-send to pid p
    kcall_mask: Mask32,          // least privilege: bit op = may invoke kernel call `op`
    priority: u32,               // scheduling priority (policy set externally; higher runs first)
}

struct ProcTable {
    procs: [MAX_PROCS]Process,
    count: usize,   // slots in use (slot 0 = bootstrap)
    current: usize, // running slot
}

fn is_runnable(s: ProcState) -> bool {
    return s == .Ready || s == .Running;
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
    switch s {
        .Unused => { return 0; }
        .Ready => { return 1; }
        .Running => { return 2; }
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
        t.procs[i].parent = 0;
        t.procs[i].exit_code = 0;
        t.procs[i].satp = 0;
        mailbox_init(Message, IPC_SLOTS, &t.procs[i].inbox);
        t.procs[i].pending_sig = mask32_zero();
        t.procs[i].allow_mask = mask32_from(0xFFFF_FFFF); // permissive by default; restrict per server
        t.procs[i].kcall_mask = mask32_from(0xFFFF_FFFF);
        t.procs[i].priority = 0;
        i = i + 1;
    }
    // Slot 0 is the running bootstrap context (filled on first switch out).
    t.procs[0].state = .Running;
    t.count = 1;
    t.current = 0;
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
    t.procs[slot].parent = t.procs[t.current].pid; // the spawner is the parent
    t.procs[slot].exit_code = 0;
    // Reset per-process state in case this slot was reaped from an earlier process.
    mailbox_init(Message, IPC_SLOTS, &t.procs[slot].inbox);
    t.procs[slot].pending_sig = mask32_zero();
    t.procs[slot].allow_mask = mask32_from(0xFFFF_FFFF);
    t.procs[slot].kcall_mask = mask32_from(0xFFFF_FFFF);
    t.procs[slot].priority = 0;
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

// Policy: the highest-priority runnable process other than `from` (ties: lowest pid),
// or `from` if no other is runnable.
fn sched_next_priority(t: *mut ProcTable, from: usize) -> usize {
    var best: usize = from;
    var best_prio: u32 = 0;
    var found: bool = false;
    var i: usize = 0;
    while i < t.count {
        if i != from {
            let s: ProcState = t.procs[i].state;
            if is_runnable(s) {
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

// Park the current process: make it non-runnable so the scheduler won't pick it again
// (until something wakes it). Used by a process that has finished its turn of work.
export fn proc_park(t: *mut ProcTable) -> void {
    t.procs[t.current].state = .BlockedRecv;
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

// Halt the machine (no return). Used when the scheduler has nothing left to run.
extern fn mc_halt() -> void;

// Terminate the current process with an exit code and switch to the next runnable
// one. Never returns to the caller (its slot is now a Zombie awaiting reap).
export fn proc_exit(t: *mut ProcTable, code: u32) -> void {
    let from: usize = t.current;
    t.procs[from].exit_code = code;
    t.procs[from].state = .Zombie;
    let to: usize = next_runnable(t, from);
    if to == from {
        // No other runnable process: the table holds only this (now Zombie) slot plus
        // non-runnable ones. Do NOT set the zombie Running again (that would resurrect a
        // dead process and switch into itself) — there is simply nothing left to run.
        mc_halt();
        return;
    }
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

// Privilege-checked send: deliver only if the caller is allowed to reach `dst_pid`.
// Returns whether it was permitted (and sent).
export fn ipc_try_send(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> bool {
    let cur: usize = t.current;
    if !mask32_contains(&t.procs[cur].allow_mask, dst_pid) {
        return false; // not permitted to send to this peer
    }
    ipc_send(t, dst_pid, tag, a0, a1, a2);
    return true;
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
export fn proc_kill(t: *mut ProcTable, target_pid: u32, sig: u32) -> void {
    let target: usize = target_pid as usize;
    if target >= t.count {
        return;
    }
    mask32_set(&t.procs[target].pending_sig, sig);
    let st: ProcState = t.procs[target].state;
    if st == .BlockedRecv {
        t.procs[target].state = .Ready;
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
    if t.procs[dst].state == .BlockedRecv {
        t.procs[dst].state = .Ready; // wake the blocked receiver
    }
}

// Send `tag`/payload to `dst_pid`. Blocks (yields) only while the mailbox is full.
export fn ipc_send(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> void {
    let dst: usize = dst_pid as usize;
    if dst >= t.count {
        return; // no such process; a real kernel would return an error
    }
    let me: u32 = t.procs[t.current].pid;
    let msg: Message = .{ .from = me, .tag = tag, .a0 = a0, .a1 = a1, .a2 = a2 };
    var delivered: bool = false;
    while !delivered {
        delivered = mailbox_post(Message, IPC_SLOTS, &t.procs[dst].inbox, msg, me);
        if !delivered {
            proc_yield(t); // mailbox full -- let the receiver drain it
        }
    }
    wake_if_blocked(t, dst);
}

// Asynchronous notification: deliver if there is room, else drop (non-blocking). Like
// MINIX `notify` -- fire-and-forget, never blocks the sender.
export fn ipc_notify(t: *mut ProcTable, dst_pid: u32, tag: u32) -> bool {
    let dst: usize = dst_pid as usize;
    if dst >= t.count {
        return false;
    }
    let me: u32 = t.procs[t.current].pid;
    let msg: Message = .{ .from = me, .tag = tag, .a0 = 0, .a1 = 0, .a2 = 0 };
    if mailbox_post(Message, IPC_SLOTS, &t.procs[dst].inbox, msg, me) {
        wake_if_blocked(t, dst);
        return true;
    }
    return false; // mailbox full -- notification dropped
}

// sendrec: send a request to `dst_pid` and block for the reply, as one primitive.
export fn ipc_call(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64, out: *mut Message) -> void {
    ipc_send(t, dst_pid, tag, a0, a1, a2);
    ipc_receive(t, out);
}

// Receive any message into `out`, blocking (yielding as BlockedRecv) until one arrives.
export fn ipc_receive(t: *mut ProcTable, out: *mut Message) -> void {
    var got: bool = false;
    while !got {
        got = mailbox_take(Message, IPC_SLOTS, &t.procs[t.current].inbox, out);
        if !got {
            t.procs[t.current].state = .BlockedRecv;
            proc_yield(t);
        }
    }
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

// Receive only a message from `src_pid`, blocking until one arrives (source filtering).
export fn ipc_receive_from(t: *mut ProcTable, src_pid: u32, out: *mut Message) -> void {
    var got: bool = false;
    while !got {
        got = mailbox_take_from(Message, IPC_SLOTS, &t.procs[t.current].inbox, src_pid, out);
        if !got {
            t.procs[t.current].state = .BlockedRecv;
            proc_yield(t);
        }
    }
}
