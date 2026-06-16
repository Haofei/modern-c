// kernel/core/proc_ipc — kernel-mediated IPC, the microkernel backbone. Send/receive
// fixed-size Messages between processes: the kernel is the only path, so senders never
// touch a receiver's memory and the receiver learns the sender's pid from `from` (stamped
// by the kernel, unforgeable). Each process has a multi-slot mailbox; send blocks (yields)
// only when the mailbox is full, then wakes a blocked receiver. Receive can take any
// message or filter by sender. The reserved IPC tags (TAG_DEAD / TAG_QUANTUM) live here.
//
// The process table, endpoints, the block/unblock + yield mechanism, and the pure Message
// data leaf (kernel/core/ipc.mc) live in their own modules. Split out of process.mc (pure move).

import "kernel/core/ipc.mc";
import "std/mask.mc";
import "kernel/lib/mailbox.mc";
import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";

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

// Bounded blocking send with a TYPED outcome — the Result form of ipc_try_send.
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
// (non-blocking) or ipc_send_result (bounded, typed) instead.
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
