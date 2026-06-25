// user/abi — the stable userspace syscall ABI (numbers), shared by the kernel (which
// registers handlers, kernel/arch/riscv64/app_runtime.c) and the user runtime (user/sys.mc,
// which issues the ecalls). Keep these numbers stable; appending is fine, renumbering is not.
//
// This is the SINGLE source of truth for syscall numbers: both the kernel (which registers
// handlers, casting to usize) and the user runtime (which issues the ecalls as u64) consume
// these — neither side hardcodes its own copy, so the ABI cannot drift.

export const SYS_WRITE: u64 = 0; // (fd, buf, len) -> bytes written (>=0) | -errno
export const SYS_READ: u64 = 1; // (buf, max) -> bytes delivered (>=0) | -errno  (§0 agent ingress)
export const SYS_GETPID: u64 = 2; // () -> pid
// SYS_EXIT is 3 to match the shared M-mode trap path (usermode_runtime.c handles a7==3
// specially: it returns control to the kernel rather than back to U-mode).
export const SYS_EXIT: u64 = 3; // (code) -> noreturn
// Async Tool/Net I/O (Phase 7+): SYS_SUBMIT takes a POINTER to a ToolReq struct (copied in and
// validated), starts a non-blocking op, and returns a request id (>=0) or -errno. SYS_POLL is the
// VECTOR completion drain: (events_ptr, max, timeout) fills up to `max` ToolEvent structs at
// events_ptr (the i-th event at offset i*sizeof(ToolEvent)) for ready completions, returning the
// count delivered (0..max) or -E_FAULT (bad pointer). `max` >= 1 (max==0 is treated as 1 for
// back-compat with the single-event form). `timeout` is the number of EXTRA virtual-clock ticks
// the broker may advance while seeking ready completions (timeout==0 advances the clock once).
// The single-event caller passes (event_ptr, 1, 0) and observes the original 1/0/-E_FAULT result.
// The request struct carries variable-length in/out payload buffers, so the real copy-in/copy-out
// + size-validation path is exercised by BOTH the mock smoke ops AND the real capability-checked
// FS ops (below); future compound Tool/Net calls slot straight in.
export const SYS_SUBMIT: u64 = 4; // (req_ptr) -> request id (>=0) | -errno
export const SYS_POLL: u64 = 5; // (events_ptr, max, timeout) -> count delivered (0..max) | -E_FAULT

// Negative-errno results returned through the syscall ABI (Linux-compatible values).
export const E_AGAIN: i64 = -11;     // EAGAIN: no capacity right now (back-pressure, retryable)
export const E_DENIED: i64 = -13;    // EACCES: policy denied this op (not retryable)
export const E_FAULT: i64 = -14;     // EFAULT: a user pointer could not be accessed
export const E_NOCAP: i64 = -105;    // ENOBUFS: request exceeds a hard capacity bound (payload too big)
export const E_TIMEDOUT: i64 = -110; // ETIMEDOUT: the op did not complete within its deadline
export const E_CANCELED: i64 = -125; // ECANCELED: the request was cancelled before completion

// Tool ABI quotas (per agent). Hard bounds on what one agent can have outstanding / move per
// request; the kernel owns buffers of exactly these sizes, so a hostile agent cannot make the
// kernel allocate or copy unbounded data.
export const MAX_INFLIGHT: u32 = 8;    // max concurrent pending requests (== completion queue depth)
export const MAX_REQ_BYTES: u32 = 256; // max request-payload bytes copied IN per request
export const MAX_RES_BYTES: u32 = 256; // max result-payload bytes copied OUT per request

// Tool op selectors. Three families exist today: the MOCK smoke ops (1..5, below), the REAL
// capability-checked FS ops (6..8, further below), and the brokered network op (9). The
// mock broker reads req.flags as a DELAY in virtual ticks, so completions can become ready out of
// submit order (a small delay finishes before a large one submitted earlier) — exercising the
// event loop's real out-of-order/overlap behavior, not just immediately-queued completions.
export const TOOL_OP_SUM: u32 = 1;     // result scalar = arg + 2 (deterministic smoke op)
export const TOOL_OP_ECHO: u32 = 2;    // result payload = the in-payload, echoed back (bounded by out_cap)
export const TOOL_OP_CANCEL: u32 = 3;  // complete the in-flight request whose id == arg with -E_CANCELED
export const TOOL_OP_TIMEOUT: u32 = 4; // completes (after its delay) with status -E_TIMEDOUT
export const TOOL_OP_SPURIOUS: u32 = 5; // TEST-ONLY: completes carrying a BOGUS id (exercises the host's
                                        // fatal "unknown completion id" path); submit still returns the real id

// REAL, capability-checked FS tool ops (M5b.2). Unlike the mock ops above, these dispatch through
// the kernel's capability front door (agent_fs_call -> fs_toolserver: allowlist -> budget ->
// path-cap), proving allow/deny/audit end-to-end from pure JS. They complete READY IMMEDIATELY
// (no delay), so the first SYS_POLL delivers them. Op -> tool_id: FS_WRITE->0, FS_READ->1,
// FS_MKDIR->2 (the agent_fs.mc TOOL_FS_* catalog). Request-payload convention (in_ptr/in_len):
//   arg (u64)          = path length in bytes
//   in_payload[0..arg] = the path bytes (a KERNEL-resident copy is made before dispatch)
//   in_payload[arg..in_len] = the data bytes (FS_WRITE only; FS_READ/FS_MKDIR have in_len == arg)
// Result: ToolEvent.status = 0 on success or -errno; ToolEvent.result = bytes written/read (or the
// directory count). For FS_READ the file bytes are staged into the request's out_ptr (<= out_cap)
// with out_len set, so the host resolves the read with the returned string.
export const TOOL_OP_FS_WRITE: u32 = 6; // write data to a path under the agent's workspace cap
export const TOOL_OP_FS_READ: u32 = 7;  // read a path's bytes back (staged to out_ptr)
export const TOOL_OP_FS_MKDIR: u32 = 8; // create a directory (DENIED unless allowlisted)

// Brokered network fetch. The production agent runtime exposes this as a first-class JS tool op.
// arg = endpoint id; flags = request token/audit size. The current S-mode QuickJS runtime dispatches
// through the shared network broker policy + mock endpoint transport (`net_fetch`) because that image
// has no NIC yet; `net_fetch_tcp` is the real transport sibling for NIC-backed runtimes.
export const TOOL_OP_NET_FETCH: u32 = 9;

// ToolReq: a tool/net request, copied IN from user memory on SYS_SUBMIT (single snapshot, so it
// is TOCTOU-safe). `in_ptr`/`in_len` point at a request payload (validated <= MAX_REQ_BYTES);
// `out_ptr`/`out_cap` reserve where the result payload is copied OUT on poll (<= MAX_RES_BYTES).
// Field order/sizes are mirrored byte-for-byte by the C host (examples/apps/qjs_host.c).
struct ToolReq {
    op: u32,      // +0  one of TOOL_OP_*
    flags: u32,   // +4  reserved (0)
    arg: u64,     // +8  scalar argument (and the target id for TOOL_OP_CANCEL)
    in_ptr: u64,  // +16 user pointer to the request payload (may be 0 if in_len == 0)
    in_len: u32,  // +24 request payload length
    out_cap: u32, // +28 capacity reserved for the result payload
    out_ptr: u64, // +32 user pointer to where the result payload is written on poll
}

// ToolEvent: one completion, copied OUT to user memory on SYS_POLL. `status` is 0 on success or
// a negative errno; `result` is the scalar result; `out_len` is how many payload bytes were
// written to the originating request's out_ptr.
struct ToolEvent {
    id: u64,       // +0  the request id this completes
    status: i32,   // +8  0 | -errno
    result: i32,   // +12 scalar result
    out_len: u32,  // +16 result-payload bytes written to out_ptr
    reserved: u32, // +20 reserved (0)
}

// Standard descriptors (a minimal, fixed set for the console channel).
export const FD_STDOUT: u64 = 1;
