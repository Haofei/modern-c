// Host parity fixture for the agent-facing async API (user/agent_async.mc): exercises the concrete
// `ToolFut` leaf + the shared `ToolPump` (by-id out-of-order completion registry) + the stable
// wrappers (tool_call_async / read_async / sleep_async / net_fetch_async) + an `async fn` awaiting
// them, including a TIMEOUT-then-CANCEL path. Diffing C vs LLVM proves the leaf/pump/wrapper lowering
// — and the `async fn` state machine over them — is byte-identical on both backends.
//
// The syscall Tool ABI is replaced by a SELF-CONTAINED mock broker honoring the exact
// (req_ptr)->id / (events_ptr,max,timeout)->count contract of sys_submit / sys_poll (delay-driven
// reordering, slot reclaim on cancel). `g_inflight` counts live broker slots so a LEAK (cancel not
// reclaiming) or a DOUBLE-free is observable on both backends. This is the host-side stand-in for
// tests/qemu/proc/app_run_demo.mc's broker; the QEMU gate exercises the same leaves for real.

import "user/abi.mc";
import "user/agent_async.mc";
import "std/task.mc";

// ----- a minimal mock broker (mirrors app_run_demo's sys_submit/sys_poll semantics) -------------
const MOCK_SLOTS: usize = 8;
global g_active: [MOCK_SLOTS]bool;
global g_id: [MOCK_SLOTS]u64;
global g_status: [MOCK_SLOTS]i32;
global g_result: [MOCK_SLOTS]i32;
global g_ready: [MOCK_SLOTS]u64;     // virtual tick at which the slot becomes pollable
global g_clock: u64 = 0;
global g_next: u64 = 1;
global g_inflight: i32 = 0;          // live slots; must return to 0 (leak/double-free detector)

fn mock_reset() -> void {
    var i: usize = 0;
    while i < MOCK_SLOTS { g_active[i] = false; i = i + 1; }
    g_clock = 0;
    g_next = 1;
    g_inflight = 0;
}

fn mock_free_slot() -> usize {
    var i: usize = 0;
    while i < MOCK_SLOTS { if !g_active[i] { return i; } i = i + 1; }
    return MOCK_SLOTS;
}

fn mock_slot_by_id(id: u64) -> usize {
    var i: usize = 0;
    while i < MOCK_SLOTS { if g_active[i] && g_id[i] == id { return i; } i = i + 1; }
    return MOCK_SLOTS;
}

// ToolReq / ToolEvent byte offsets (mirror user/abi.mc). The mock reads/writes the structs at the
// `usize` addresses the pump passes via raw.load/raw.store — the same address-as-data idiom the
// kernel uses for MMIO/uaccess, so the host fixture needs no non-null pointer reinterpret cast.
const REQ_OP: usize = 0;       // u32
const REQ_FLAGS: usize = 4;    // u32
const REQ_ARG: usize = 8;      // u64
const REQ_IN_LEN: usize = 24;  // u32
const EV_ID: usize = 0;        // u64
const EV_STATUS: usize = 8;    // i32
const EV_RESULT: usize = 12;   // i32
const EV_OUTLEN: usize = 16;   // u32
const EV_RESERVED: usize = 20; // u32

// The sys_submit contract: read the ToolReq fields, arm a slot ready at now+flags(delay), return the
// id (>=0) or -errno. CANCEL completes the target id with -E_CANCELED ready-now (no new slot).
fn mock_submit(req_ptr: usize) -> i64 {
    var op: u32 = 0;
    var flags: u32 = 0;
    var arg: u64 = 0;
    var in_len: u32 = 0;
    unsafe {
        op = raw.load<u32>(phys(req_ptr + REQ_OP));
        flags = raw.load<u32>(phys(req_ptr + REQ_FLAGS));
        arg = raw.load<u64>(phys(req_ptr + REQ_ARG));
        in_len = raw.load<u32>(phys(req_ptr + REQ_IN_LEN));
    }

    if op == TOOL_OP_CANCEL {
        let s: usize = mock_slot_by_id(arg);
        if s == MOCK_SLOTS { return E_DENIED; }
        g_status[s] = E_CANCELED as i32;
        g_result[s] = 0;
        g_ready[s] = g_clock;     // observed promptly
        return 0;
    }

    let slot: usize = mock_free_slot();
    if slot == MOCK_SLOTS { return E_AGAIN; }   // back-pressure
    let id: u64 = g_next;
    g_next = g_next + 1;
    g_active[slot] = true;
    g_id[slot] = id;
    g_status[slot] = 0;
    g_result[slot] = 0;
    g_ready[slot] = g_clock + (flags as u64);
    g_inflight = g_inflight + 1;

    if op == TOOL_OP_SUM {
        g_result[slot] = ((arg & 0x7FFF_FFFF) as i32) + 2;
    } else if op == TOOL_OP_ECHO {
        g_result[slot] = in_len as i32;           // bytes "echoed"
    } else if op == TOOL_OP_TIMEOUT {
        g_status[slot] = E_TIMEDOUT as i32;       // completes as a timeout
    } else if op == TOOL_OP_FS_READ {
        g_result[slot] = arg as i32;              // pretend we read `path_len` bytes
    } else if op == TOOL_OP_FS_WRITE {
        g_result[slot] = (in_len - (arg as u32)) as i32; // bytes written (in_len - path_len)
    } else {
        g_active[slot] = false; g_inflight = g_inflight - 1; return E_DENIED;
    }
    return id as i64;
}

// The sys_poll contract: advance the clock up to (1+timeout) times, deliver up to `max` ready slots
// (smallest ready tick first), each as a ToolEvent at events_ptr + i*sizeof(ToolEvent). Returns the
// count delivered. Frees each delivered slot (so cancel/complete reclaims g_inflight).
fn mock_poll(events_ptr: usize, max: usize, timeout: usize) -> i64 {
    var want: usize = max;
    if want == 0 { want = 1; }
    var count: usize = 0;
    var steps: u64 = 0;
    let max_steps: u64 = 1 + (timeout as u64);
    while steps < max_steps {
        steps = steps + 1;
        g_clock = g_clock + 1;
        while count < want {
            var best: usize = MOCK_SLOTS;
            var i: usize = 0;
            while i < MOCK_SLOTS {
                if g_active[i] && g_ready[i] <= g_clock {
                    if best == MOCK_SLOTS || g_ready[i] < g_ready[best] || (g_ready[i] == g_ready[best] && g_id[i] < g_id[best]) {
                        best = i;
                    }
                }
                i = i + 1;
            }
            if best == MOCK_SLOTS { break; }
            let evp: usize = events_ptr + count * sizeof(ToolEvent);
            unsafe {
                raw.store<u64>(phys(evp + EV_ID), g_id[best]);
                raw.store<i32>(phys(evp + EV_STATUS), g_status[best]);
                raw.store<i32>(phys(evp + EV_RESULT), g_result[best]);
                raw.store<u32>(phys(evp + EV_OUTLEN), 0);
                raw.store<u32>(phys(evp + EV_RESERVED), 0);
            }
            g_active[best] = false;
            g_inflight = g_inflight - 1;
            count = count + 1;
        }
        if count == want { break; }
    }
    return count as i64;
}

// Unwrap a Result<i32,i32> to a plain i32 (ok value, or the error code on err) — keeps the call
// sites in the async tail straight-line (a single `return expr;`, no switch in the tail).
fn result_or_err(r: Result<i32, i32>) -> i32 {
    switch r {
        ok(v) => { return v; }
        err(e) => { return e; }
    }
}

// ----- the agent's async fn, awaiting the stable wrappers ---------------------------------------
// Two dependent awaits over the API: a SUM tool call, then an FS read whose path length is derived
// from the first result — proving overlap/sequencing and that ToolFut satisfies the leaf ABI the
// transform lowers to. Returns the sum of the two results.
async fn flow(p: *mut ToolPump) -> i32 {
    // A leading await-run (two awaits back-to-back), then a straight-line tail: the two tool calls
    // overlap in flight and the pump matches each completion to its future by id.
    let ra: Result<i32, i32> = await tool_call_async(p, TOOL_OP_SUM, 40, 0, 0, 0, 0);
    let rb: Result<i32, i32> = await read_async(p, 0, 2, 0, 0, 0);  // FS read; result mocked to path_len
    return result_or_err(ra) + result_or_err(rb);   // (40+2) + 2 == 44
}

export fn agent_async_api_run() -> u32 {
    var acc: u32 = 0;
    var pump: ToolPump = uninit;

    // Each case is an INDEPENDENT session: reset the broker AND re-init the pump (a fresh pump
    // clears the by-id stash). The mock broker reuses ids across cases (mock_reset rewinds the id
    // counter), which a long-lived pump would alias — re-init mirrors a real per-session pump.

    // ---- (1) the async fn drives two awaits through the API to completion ----
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var f: flow__Fut = flow(&pump);
    pump_run_to_completion(&pump, &f);
    if flow__Fut_take_result(&f) == 44 { acc = acc ^ 0x1; }    // (40+2)+2
    if g_inflight == 0 { acc = acc ^ 0x2; }                    // both slots consumed (no leak)

    // ---- (2) OVERLAPPING tool calls matched BY ID. Two SUM calls are in flight at once; a single
    // `sys_poll` drain can deliver BOTH events in one batch (arbitrary order). The shared pump
    // stashes each by id, so when we drive fb to completion the pump may have ALREADY stashed fa's
    // event (or vice versa) — each future must pick out ITS own result by id, never a sibling's. ----
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fa: ToolFut = tool_call_async(&pump, TOOL_OP_SUM, 10, 0, 0, 0, 0); // id 1 -> 12
    var fb: ToolFut = tool_call_async(&pump, TOOL_OP_SUM, 20, 0, 0, 0, 0); // id 2 -> 22 (both inflight)
    pump_run_to_completion(&pump, &fb);  // drives the batch; fa's event gets stashed too
    pump_run_to_completion(&pump, &fa);  // fa resolves from the stash by its id
    let ra: i32 = result_or_err(ToolFut_take_result(&fa));
    let rb: i32 = result_or_err(ToolFut_take_result(&fb));
    if ra == 12 && rb == 22 { acc = acc ^ 0x4; }               // each future got ITS own result by id
    if g_inflight == 0 { acc = acc ^ 0x8; }                    // both reclaimed

    // ---- (3) sleep_async completes as err(E_TIMEDOUT) — the "slept" convention ----
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fs: ToolFut = sleep_async(&pump, 2);
    pump_run_to_completion(&pump, &fs);
    switch ToolFut_take_result(&fs) {
        ok(v) => {}
        err(e) => { if e == (E_TIMEDOUT as i32) { acc = acc ^ 0x10; } }   // slept (timed out) normally
    }
    if g_inflight == 0 { acc = acc ^ 0x20; }

    // ---- (4) CANCEL reclaims the slot: a still-pending future dropped/cancelled releases its slot
    // via a TOOL_OP_CANCEL submit, then a drain delivers the -E_CANCELED completion. ----
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fc: ToolFut = sleep_async(&pump, 50);   // long delay: stays pending
    let p0: bool = ToolFut_poll(&fc);           // pending (clock advanced 1, not ready)
    if !p0 && g_inflight == 1 { acc = acc ^ 0x40; }   // exactly one slot held
    ToolFut_cancel(&fc);                        // submit CANCEL for its id
    pump_pump(&pump, 0);    // deliver the -E_CANCELED completion -> free the slot
    if g_inflight == 0 { acc = acc ^ 0x80; }    // cancel reclaimed the would-be-leaked slot
    ToolFut_cancel(&fc);                        // idempotent: no double-free, no extra submit
    if g_inflight == 0 { acc = acc ^ 0x100; }

    // ---- (5) net_fetch_async (ECHO stand-in transport) returns the request byte count ----
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fnet: ToolFut = net_fetch_async(&pump, 0, 0, 7, 0, 64);   // req_len 7 -> echoed count 7
    pump_run_to_completion(&pump, &fnet);
    if result_or_err(ToolFut_take_result(&fnet)) == 7 { acc = acc ^ 0x200; }
    if g_inflight == 0 { acc = acc ^ 0x400; }

    // entry-mode contract: 1 = pass, 0 = fail.
    if acc != 0x7FF { return 0; }
    return 1;
}
