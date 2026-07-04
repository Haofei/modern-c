// kernel/core/proc_signals — signal delivery: the kernel primitive a Process Manager
// builds POSIX signals on. A signal is an async event delivered to a process; delivery
// sets a pending bit and wakes a blocked process, and the target polls/takes pending
// signals. The process table, endpoints, and the block/unblock mechanism live in
// kernel/core/process.mc and kernel/core/proc_sched.mc. Split out of process.mc (pure move).

import "std/mask.mc";
import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";

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
pub fn proc_kill_ep(t: *mut ProcTable, ep: Endpoint, sig: u32) -> Result<bool, EpError> {
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
