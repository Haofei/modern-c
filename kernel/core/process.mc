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
    mailbox: [IPC_SLOTS]Message, // multi-slot mailbox for kernel-mediated IPC
    mbox_valid: [IPC_SLOTS]bool, // which mailbox slots hold a pending message
    mbox_count: usize,           // number of pending messages
    pending_sig: u32,            // bitmask of pending signals (a PM server builds on this)
    allow_mask: u32,             // least privilege: bit p = may IPC-send to pid p
    kcall_mask: u32,             // least privilege: bit op = may invoke kernel call `op`
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

export fn proc_table_init(t: *mut ProcTable) -> void {
    var i: usize = 0;
    while i < MAX_PROCS {
        t.procs[i].state = .Unused;
        t.procs[i].pid = 0;
        t.procs[i].parent = 0;
        t.procs[i].exit_code = 0;
        t.procs[i].satp = 0;
        t.procs[i].mbox_count = 0;
        t.procs[i].pending_sig = 0;
        t.procs[i].allow_mask = 0xFFFF_FFFF; // permissive by default; restrict per server
        t.procs[i].kcall_mask = 0xFFFF_FFFF;
        t.procs[i].priority = 0;
        var s: usize = 0;
        while s < IPC_SLOTS {
            t.procs[i].mbox_valid[s] = false;
            s = s + 1;
        }
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

// ----- least privilege: per-process IPC allow-list + kernel-call gateway -----

enum KError {
    Denied, // the caller's kcall_mask does not permit this kernel call
}

// Restrict which peers a process may IPC-send to (bit p = may send to pid p).
export fn proc_set_allow_mask(t: *mut ProcTable, pid: u32, mask: u32) -> void {
    let p: usize = pid as usize;
    if p < t.count {
        t.procs[p].allow_mask = mask;
    }
}

// Restrict which kernel calls a process may invoke (bit op = may call `op`).
export fn proc_set_kcall_mask(t: *mut ProcTable, pid: u32, mask: u32) -> void {
    let p: usize = pid as usize;
    if p < t.count {
        t.procs[p].kcall_mask = mask;
    }
}

// Privilege-checked send: deliver only if the caller is allowed to reach `dst_pid`.
// Returns whether it was permitted (and sent).
export fn ipc_try_send(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> bool {
    let cur: usize = t.current;
    let bit: u32 = wrapping_shl_u32(1, dst_pid);
    if (t.procs[cur].allow_mask & bit) == 0 {
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
    let bit: u32 = wrapping_shl_u32(1, op);
    if (t.procs[cur].kcall_mask & bit) == 0 {
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
    let bit: u32 = wrapping_shl_u32(1, sig);
    t.procs[target].pending_sig = t.procs[target].pending_sig | bit;
    let st: ProcState = t.procs[target].state;
    if st == .BlockedRecv {
        t.procs[target].state = .Ready;
    }
}

// The current process's pending-signal bitmask.
export fn proc_sigpending(t: *mut ProcTable) -> u32 {
    return t.procs[t.current].pending_sig;
}

// Take (clear + return) the lowest pending signal of the current process, or 32 if none.
export fn proc_sigtake(t: *mut ProcTable) -> u32 {
    let cur: usize = t.current;
    let pending: u32 = t.procs[cur].pending_sig;
    var sig: u32 = 0;
    while sig < 32 {
        let bit: u32 = wrapping_shl_u32(1, sig);
        if (pending & bit) != 0 {
            t.procs[cur].pending_sig = pending & (~bit);
            return sig;
        }
        sig = sig + 1;
    }
    return 32; // none pending
}

// ----- kernel-mediated IPC (the microkernel backbone) -----
//
// Send/receive fixed-size Messages between processes. The kernel is the only path:
// senders never touch a receiver's memory, and the receiver learns the sender's pid
// from `from` (stamped by the kernel — unforgeable). Each process has a multi-slot
// mailbox; send blocks (yields) only when the mailbox is full, then wakes a blocked
// receiver. Receive can take any message or filter by sender.

// Index of a free mailbox slot in process `p`, or IPC_SLOTS if full.
fn mbox_free_slot(t: *mut ProcTable, p: usize) -> usize {
    var s: usize = 0;
    while s < IPC_SLOTS {
        if !t.procs[p].mbox_valid[s] {
            return s;
        }
        s = s + 1;
    }
    return IPC_SLOTS;
}

fn mbox_deliver(t: *mut ProcTable, dst: usize, slot: usize, from: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> void {
    t.procs[dst].mailbox[slot].from = from;
    t.procs[dst].mailbox[slot].tag = tag;
    t.procs[dst].mailbox[slot].a0 = a0;
    t.procs[dst].mailbox[slot].a1 = a1;
    t.procs[dst].mailbox[slot].a2 = a2;
    t.procs[dst].mbox_valid[slot] = true;
    t.procs[dst].mbox_count = t.procs[dst].mbox_count + 1;
    let dstate: ProcState = t.procs[dst].state;
    if dstate == .BlockedRecv {
        t.procs[dst].state = .Ready; // wake the blocked receiver
    }
}

// Send `tag`/payload to `dst_pid`. Blocks (yields) only while the mailbox is full.
export fn ipc_send(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64) -> void {
    let dst: usize = dst_pid as usize;
    if dst >= t.count {
        return; // no such process; a real kernel would return an error
    }
    var slot: usize = mbox_free_slot(t, dst);
    while slot >= IPC_SLOTS {
        proc_yield(t); // mailbox full — let the receiver drain it
        slot = mbox_free_slot(t, dst);
    }
    let me: u32 = t.procs[t.current].pid;
    mbox_deliver(t, dst, slot, me, tag, a0, a1, a2);
}

// Asynchronous notification: deliver if there is room, else drop (non-blocking). Like
// MINIX `notify` — fire-and-forget, never blocks the sender.
export fn ipc_notify(t: *mut ProcTable, dst_pid: u32, tag: u32) -> bool {
    let dst: usize = dst_pid as usize;
    if dst >= t.count {
        return false;
    }
    let slot: usize = mbox_free_slot(t, dst);
    if slot >= IPC_SLOTS {
        return false; // mailbox full — notification dropped (caller may retry)
    }
    let me: u32 = t.procs[t.current].pid;
    mbox_deliver(t, dst, slot, me, tag, 0, 0, 0);
    return true;
}

// sendrec: send a request to `dst_pid` and block for the reply (the common client
// pattern — request then wait — as one primitive, like MINIX's `sendrec`).
export fn ipc_call(t: *mut ProcTable, dst_pid: u32, tag: u32, a0: u64, a1: u64, a2: u64, out: *mut Message) -> void {
    ipc_send(t, dst_pid, tag, a0, a1, a2);
    ipc_receive(t, out);
}

fn mbox_take(t: *mut ProcTable, cur: usize, slot: usize, out: *mut Message) -> void {
    out.from = t.procs[cur].mailbox[slot].from;
    out.tag = t.procs[cur].mailbox[slot].tag;
    out.a0 = t.procs[cur].mailbox[slot].a0;
    out.a1 = t.procs[cur].mailbox[slot].a1;
    out.a2 = t.procs[cur].mailbox[slot].a2;
    t.procs[cur].mbox_valid[slot] = false;
    t.procs[cur].mbox_count = t.procs[cur].mbox_count - 1;
}

// Receive any message into `out`, blocking (yielding as BlockedRecv) until one arrives.
export fn ipc_receive(t: *mut ProcTable, out: *mut Message) -> void {
    var got: bool = false;
    while !got {
        let cur: usize = t.current;
        var slot: usize = 0;
        var found: usize = IPC_SLOTS;
        while slot < IPC_SLOTS {
            if t.procs[cur].mbox_valid[slot] {
                found = slot;
                slot = IPC_SLOTS; // stop at the first pending slot
            } else {
                slot = slot + 1;
            }
        }
        if found < IPC_SLOTS {
            mbox_take(t, cur, found, out);
            got = true;
        } else {
            t.procs[cur].state = .BlockedRecv;
            proc_yield(t);
        }
    }
}

// Receive with a timeout: poll the mailbox, yielding up to `max_yields` times. Returns
// true if a message was taken into `out`, false if it timed out (no infinite block).
// Polls as Ready (not BlockedRecv) so the scheduler keeps returning here to time out.
export fn ipc_receive_timeout(t: *mut ProcTable, out: *mut Message, max_yields: u32) -> bool {
    var tries: u32 = 0;
    while tries <= max_yields {
        let cur: usize = t.current;
        var slot: usize = 0;
        var found: usize = IPC_SLOTS;
        while slot < IPC_SLOTS {
            if t.procs[cur].mbox_valid[slot] {
                found = slot;
                slot = IPC_SLOTS;
            } else {
                slot = slot + 1;
            }
        }
        if found < IPC_SLOTS {
            mbox_take(t, cur, found, out);
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
        let cur: usize = t.current;
        var slot: usize = 0;
        var found: usize = IPC_SLOTS;
        while slot < IPC_SLOTS {
            if t.procs[cur].mbox_valid[slot] {
                if t.procs[cur].mailbox[slot].from == src_pid {
                    found = slot;
                    slot = IPC_SLOTS;
                } else {
                    slot = slot + 1;
                }
            } else {
                slot = slot + 1;
            }
        }
        if found < IPC_SLOTS {
            mbox_take(t, cur, found, out);
            got = true;
        } else {
            t.procs[cur].state = .BlockedRecv;
            proc_yield(t);
        }
    }
}
