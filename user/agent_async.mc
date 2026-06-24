// user/agent_async — the STABLE, agent-facing async API: concrete Future leaves and wrappers over
// the syscall Tool ABI (user/abi.mc + user/libc/syscall_user.mc), so an `async fn` agent can write
//
//     let a: Result<i32,i32> = await read_async(&pump, path, plen, 0, dst, n);
//     let b: Result<i32,i32> = await tool_call_async(&pump, TOOL_OP_SUM, 7, 0, 0, 0, 0);
//
// and drive it to completion with cancel + timeout, WITHOUT touching ToolReq marshalling or the
// out-of-order completion drain by hand. Names here are stable; the compiler syntax is boring on
// purpose — the API is the useful part.
//
// THE OUT-OF-ORDER PROBLEM, AND WHY A SHARED PUMP. `sys_poll` is a VECTOR drain: a single poll can
// return completions for ARBITRARY in-flight ids (smallest ready-tick first), not just the one a
// given future is awaiting. If each `ToolFut.poll` called `sys_poll` itself it would DROP the other
// futures' completions on the floor (the kernel frees a slot once it is delivered — a sibling's
// event vanishes). So a single `ToolPump` owns the drain: `pump_pump` calls `sys_poll` once into a
// batch buffer and STASHES every returned ToolEvent into a small by-id registry. Each `ToolFut.poll`
// is then non-blocking and side-effect-free: it only consults the registry for ITS id. One pump
// services all in-flight ToolFuts correctly regardless of completion order — that is the design.
//
// CANCEL RECLAIMS THE SLOT. A ToolFut that loses a race or is dropped while still in flight submits
// a `ToolReq{op: TOOL_OP_CANCEL, arg: self.id}`, which makes the broker complete that id with
// -E_CANCELED and release its MAX_INFLIGHT slot. `_cancel` is idempotent (guarded by `ready`/a
// `cancelled` latch) so a completion-then-drop, or a double cancel, never double-frees.

import "user/abi.mc";
import "std/task.mc";   // the `Future` trait (pure: poll/compose only) + run-to-completion shape

// The submit/poll primitives are injected at pump-init as function pointers. In production the agent
// binds the real syscalls (`tool_pump_init_syscall` below -> sys_submit / sys_poll from
// user/libc/syscall_user.mc); a host test binds a mock broker with the SAME (req_ptr)->id /
// (events_ptr,max,timeout)->count contract. Both exercise byte-identical leaf+pump lowering.
type SubmitFn = fn(usize) -> i64;
type PollFn = fn(usize, usize, usize) -> i64;

// How many completions the pump drains per `sys_poll`. == MAX_INFLIGHT, so one drain can clear every
// outstanding request the agent is allowed to have. Each event is 24 bytes (ToolEvent).
const PUMP_BATCH: usize = 8;          // == MAX_INFLIGHT
const PUMP_STASH: usize = 8;          // registry depth: at most MAX_INFLIGHT completions outstanding

// ----- the shared completion pump ---------------------------------------------------------------
// `ev_buf` is the kernel<->user ToolEvent[] the drain writes into. `stash_*` is the by-id registry
// of completions delivered for ids whose ToolFut has not yet polled them (out-of-order arrivals).
struct ToolPump {
    submit: SubmitFn,
    poll: PollFn,
    ev_buf: [PUMP_BATCH]ToolEvent,    // drain target for sys_poll
    stash_id: [PUMP_STASH]u64,        // completion id
    stash_status: [PUMP_STASH]i32,    // 0 | -errno
    stash_result: [PUMP_STASH]i32,    // scalar result
    stash_outlen: [PUMP_STASH]u32,    // result-payload bytes written to the request's out_ptr
    stash_used: [PUMP_STASH]bool,     // registry entry occupied
}

// Wire the pump to a submit/poll pair (mock or real). Clears the registry.
export fn tool_pump_init(p: *mut ToolPump, submit: SubmitFn, poll: PollFn) -> void {
    p.submit = submit;
    p.poll = poll;
    var i: usize = 0;
    while i < PUMP_STASH {
        p.stash_used[i] = false;
        p.stash_id[i] = 0;
        i = i + 1;
    }
}

// Stash one delivered completion by id (first free registry slot). If the registry is full the
// completion is dropped — but the registry depth == MAX_INFLIGHT, and an agent can have at most
// MAX_INFLIGHT requests in flight, so a delivered completion always has a home.
fn pump_stash(p: *mut ToolPump, id: u64, status: i32, result: i32, outlen: u32) -> void {
    var i: usize = 0;
    while i < PUMP_STASH {
        if !p.stash_used[i] {
            p.stash_used[i] = true;
            p.stash_id[i] = id;
            p.stash_status[i] = status;
            p.stash_result[i] = result;
            p.stash_outlen[i] = outlen;
            return;
        }
        i = i + 1;
    }
}

// Drain the broker ONCE: advance the clock by `timeout` extra ticks, deliver up to PUMP_BATCH ready
// completions, and stash each by id. Returns the number drained (0 = nothing was ready). A ToolFut's
// `poll` calls this (with timeout 0) only when its own id is not already stashed, so the single
// `sys_poll` site lives here and every delivered event is captured for whichever future owns it.
export fn pump_pump(p: *mut ToolPump, timeout: usize) -> usize {
    let base: usize = (&p.ev_buf[0]) as usize;
    let n: i64 = (p.poll)(base, PUMP_BATCH, timeout);
    if n <= 0 {
        return 0;   // 0 = nothing ready; negative = -E_FAULT (treated as no progress)
    }
    var i: usize = 0;
    let cnt: usize = n as usize;
    while i < cnt {
        let e: *ToolEvent = &p.ev_buf[i];
        pump_stash(p, e.id, e.status, e.result, e.out_len);
        i = i + 1;
    }
    return cnt;
}

// Look up + CONSUME a stashed completion for `id`. Returns the registry index (< PUMP_STASH) and
// fills *status/*result/*outlen, or PUMP_STASH if `id` is not (yet) stashed. Consuming frees the
// entry. `outlen` is the result-payload byte count (read_async / echo) — propagated so the leaf can
// surface it via ToolFut_out_len (else read_async would always report 0 bytes).
fn pump_take(p: *mut ToolPump, id: u64, status: *mut i32, result: *mut i32, outlen: *mut u32) -> usize {
    var i: usize = 0;
    while i < PUMP_STASH {
        if p.stash_used[i] && p.stash_id[i] == id {
            *status = p.stash_status[i];
            *result = p.stash_result[i];
            *outlen = p.stash_outlen[i];
            p.stash_used[i] = false;   // consume
            return i;
        }
        i = i + 1;
    }
    return PUMP_STASH;
}

// ----- the concrete Future leaf over the syscall Tool ABI ---------------------------------------
// One in-flight request, presented as a `Future` satisfying the compiler's leaf ABI (poll /
// _take_result / _cancel). `poll` is non-blocking: it consults the pump's registry for its id,
// driving one `pump_pump` drain only when its id is not yet present. `ready` latches so poll is
// idempotent and the result survives the slot's release. `cancelled` makes `_cancel` idempotent.
struct ToolFut {
    p: *mut ToolPump,
    id: u64,            // the request id (or a bitcast -errno if submit failed)
    submit_err: i32,    // 0, or the negative errno from a failed submit (resolves immediately as err)
    ready: bool,        // result latched
    cancelled: bool,    // cancel already issued (idempotent)
    status: i32,        // 0 | -errno of the completion
    result: i32,        // scalar result
    out_len: u32,       // result-payload bytes written to the request's out_ptr
}

impl Future for ToolFut {
    fn poll(self: *mut ToolFut) -> bool {
        if self.ready {
            return true;
        }
        // A failed submit (negative id) resolves immediately as an error — no broker slot exists.
        if self.submit_err != 0 {
            self.status = self.submit_err;
            self.result = 0;
            self.ready = true;
            return true;
        }
        // Is my completion already stashed (delivered earlier, possibly out of order)?
        var st: i32 = 0;
        var rs: i32 = 0;
        var ol: u32 = 0;
        let idx: usize = pump_take(self.p, self.id, &st, &rs, &ol);
        if idx < PUMP_STASH {
            self.status = st;
            self.result = rs;
            self.out_len = ol;
            self.ready = true;
            return true;
        }
        // Not yet — drain the broker once (timeout 0: advance the clock a single tick), which stashes
        // any newly-ready completions (mine AND siblings'), then re-check just mine.
        pump_pump(self.p, 0);
        let idx2: usize = pump_take(self.p, self.id, &st, &rs, &ol);
        if idx2 < PUMP_STASH {
            self.status = st;
            self.result = rs;
            self.out_len = ol;
            self.ready = true;
            return true;
        }
        return false;
    }
}

// Free-function poll (the leaf ABI's `poll`), so callers in other modules can drive a bare ToolFut
// without relying on cross-module trait-method UFCS. Same semantics as the `impl Future` poll.
export fn ToolFut_poll(self: *mut ToolFut) -> bool {
    return ToolFut.poll(self);
}

// The awaited result: ok(result) on success, err(status) on a broker error (-E_TIMEDOUT, -E_CANCELED,
// -E_DENIED, a failed submit, ...). The agent matches on it after the await.
export fn ToolFut_take_result(self: *mut ToolFut) -> Result<i32, i32> {
    if self.status == 0 {
        return ok(self.result);
    }
    return err(self.status);
}

// Drop / lost-race cleanup: submit a CANCEL for this id so the broker completes it with -E_CANCELED
// and RELEASES its MAX_INFLIGHT slot. Idempotent: a future that already latched its result (`ready`)
// or already cancelled holds no slot, so it does nothing — no double cancel, no slot churn. A failed
// original submit (submit_err) also holds no slot.
export fn ToolFut_cancel(self: *mut ToolFut) -> void {
    if self.ready || self.cancelled || self.submit_err != 0 {
        self.cancelled = true;
        return;
    }
    self.cancelled = true;
    var req: ToolReq = uninit;
    req.op = TOOL_OP_CANCEL;
    req.flags = 0;
    req.arg = self.id;       // target the in-flight id
    req.in_ptr = 0;
    req.in_len = 0;
    req.out_cap = 0;
    req.out_ptr = 0;
    (self.p.submit)((&req) as usize);
}

// Number of result-payload bytes the completion wrote to the request's out_ptr (valid after the
// future is ready). For read_async / echo this is how many bytes landed in the agent's dst buffer.
export fn ToolFut_out_len(self: *mut ToolFut) -> u32 {
    return self.out_len;
}

// ----- the marshalling core: build a ToolReq, submit it, return a leaf over the id ---------------
// Every wrapper funnels through here. On a failed submit (negative id) the leaf is created in the
// submit_err state so the first poll resolves it as err(errno) — no slot was reserved, so cancel is
// a no-op. `flags` carries the broker delay (TOOL_OP_TIMEOUT) or 0.
fn tool_begin(p: *mut ToolPump, op: u32, flags: u32, arg: u64,
              in_ptr: usize, in_len: u32, out_ptr: usize, out_cap: u32) -> ToolFut {
    var f: ToolFut = uninit;
    f.p = p;
    f.ready = false;
    f.cancelled = false;
    f.status = 0;
    f.result = 0;
    f.out_len = 0;
    f.submit_err = 0;
    f.id = 0;

    var req: ToolReq = uninit;
    req.op = op;
    req.flags = flags;
    req.arg = arg;
    req.in_ptr = in_ptr as u64;
    req.in_len = in_len;
    req.out_cap = out_cap;
    req.out_ptr = out_ptr as u64;

    let r: i64 = (p.submit)((&req) as usize);
    if r < 0 {
        f.submit_err = r as i32;   // resolve as err(errno) on first poll; holds no slot
    } else {
        f.id = r as u64;
    }
    return f;
}

// ----- the STABLE agent-facing wrappers ---------------------------------------------------------
// Each marshals a ToolReq and returns a concrete ToolFut leaf you `await`. Op mapping is documented
// per-wrapper; names are stable.

// The general form: any op + arg + in/out payload buffers. Use this for ops without a named wrapper.
//   op       -> ToolReq.op (a TOOL_OP_* selector)
//   arg      -> ToolReq.arg (scalar)
//   in_ptr/in_len  -> request payload (copied IN by the kernel, <= MAX_REQ_BYTES)
//   out_ptr/out_cap-> where the result payload is staged OUT on poll (<= MAX_RES_BYTES)
export fn tool_call_async(p: *mut ToolPump, op: u32, arg: u64,
                          in_ptr: usize, in_len: u32, out_ptr: usize, out_cap: u32) -> ToolFut {
    return tool_begin(p, op, 0, arg, in_ptr, in_len, out_ptr, out_cap);
}

// read_async: read `n` bytes of `path` into `dst` (TOOL_OP_FS_READ). The FS ABI carries the path in
// the request payload with arg = path length; FS_READ has no data tail (in_len == path_len). The
// read bytes are staged to `dst` (out_ptr) up to `n` (out_cap); the count read is the ok() result.
// NOTE: `offset` is accepted for a stable signature but the current mock FS server reads from 0; it
// is forwarded as ToolReq.flags so a future seekable server can honor it without an ABI change.
export fn read_async(p: *mut ToolPump, path_ptr: usize, path_len: u32,
                     offset: u32, dst: usize, n: u32) -> ToolFut {
    return tool_begin(p, TOOL_OP_FS_READ, offset, path_len as u64,
                      path_ptr, path_len, dst, n);
}

// write_async: write `n` bytes at `src` to `path` (TOOL_OP_FS_WRITE). The FS ABI packs the request
// payload as path[0..path_len] then data[path_len..path_len+n], with arg = path_len. This wrapper
// requires the caller to have pre-packed that layout at `pack_ptr` (path followed by data), since the
// kernel copies one contiguous in-payload; `pack_len` = path_len + n. ok() result = bytes written.
export fn write_async(p: *mut ToolPump, path_len: u32, pack_ptr: usize, pack_len: u32) -> ToolFut {
    return tool_begin(p, TOOL_OP_FS_WRITE, 0, path_len as u64,
                      pack_ptr, pack_len, 0, 0);
}

// sleep_async: complete after `delay_ticks` broker ticks (TOOL_OP_TIMEOUT). CONVENTION: the timeout
// op completes with status -E_TIMEDOUT, which IS the "slept" signal — so the await yields
// err(E_TIMEDOUT) as the NORMAL result of a successful sleep. An agent treats err(E_TIMEDOUT) from
// sleep_async as "the timer fired" (not a failure). The delay rides ToolReq.flags (clamped to
// DELAY_MAX by the broker), so a later short-delay op can finish first — the pump handles that.
export fn sleep_async(p: *mut ToolPump, delay_ticks: u32) -> ToolFut {
    return tool_begin(p, TOOL_OP_TIMEOUT, delay_ticks, 0, 0, 0, 0, 0);
}

// net_fetch_async: send a request payload to a remote endpoint and stage the response. PLACEHOLDER
// TRANSPORT: there is no net op selector in the ABI yet, so this rides TOOL_OP_ECHO as a stand-in —
// the "response" is the request echoed back (bounded by resp_cap). When a real TOOL_OP_NET_* lands,
// only this body changes; the signature and the agent code stay the same. ok() result = response
// bytes; the bytes themselves land at resp_ptr (read ToolFut_out_len for the count).
//   endpoint_id -> ToolReq.arg (which remote; ignored by the ECHO stand-in)
export fn net_fetch_async(p: *mut ToolPump, endpoint_id: u64,
                          req_ptr: usize, req_len: u32, resp_ptr: usize, resp_cap: u32) -> ToolFut {
    return tool_begin(p, TOOL_OP_ECHO, 0, endpoint_id, req_ptr, req_len, resp_ptr, resp_cap);
}

// ----- the executor -----------------------------------------------------------------------------
// Drive ONE top-level future (the agent's `async fn`, or any ToolFut) to completion over the pump:
// poll it; while pending, drain the broker (advancing its clock) so the next poll sees progress.
// Returns the number of pump cycles (idle iterations) it took. A single pump services every in-flight
// ToolFut the future holds — siblings' completions are stashed and matched by id, so overlapping tool
// calls all make progress under this one loop. The `f` here is a `*mut dyn Future`, so it drives the
// generated `async fn` future as well as a bare ToolFut.
export fn pump_run_to_completion(p: *mut ToolPump, f: *mut dyn Future) -> u64 {
    var cycles: u64 = 0;
    while !f.poll() {
        // Pending: advance the broker so an awaited completion becomes ready, then re-poll. Each
        // ToolFut.poll already drains with timeout 0; this extra drain advances the clock for
        // delay-bearing ops (timeouts) that are not yet ready, guaranteeing forward progress.
        pump_pump(p, 0);
        cycles = cycles + 1;
        if cycles > 4096 {
            break;   // defensive bound: never spin forever on a wedged broker
        }
    }
    return cycles;
}
