// Host parity fixture for the NEGATIVE cancellation edges of the agent-facing async API
// (user/agent_async.mc), at the AGENT-API layer over the SAME mock broker contract as
// fuzz_agent_async_api.mc. In a tiny system a leaked broker slot is fatal, so each edge here proves
// a degenerate cancel is HARMLESS — it reclaims nothing it shouldn't and never double-frees:
//
//   (a) cancel AFTER completion -> a `ready` ToolFut holds no slot; ToolFut_cancel does nothing
//       (no CANCEL submit, no slot churn). g_inflight already 0, stays 0.
//   (b) DOUBLE cancel is harmless -> a second ToolFut_cancel after the first is a no-op (no double
//       submit, no double-free); g_inflight still reaches/stays 0.
//   (c) FAILED-submit cancel targets no stale id -> a ToolFut created in submit_err state (the
//       broker back-pressured the submit) holds no slot; cancel is a no-op and g_inflight stays 0.
//   (e) out_len is NONZERO for a read/echo payload -> after a net_fetch_async (ECHO) / read_async
//       that produced bytes, ToolFut_out_len > 0 (proves the out_len propagation through the pump).
//
// Diffing C vs LLVM proves this edge handling lowers byte-identically on both backends. The mock
// broker mirrors app_run_demo's sys_submit/sys_poll, INCLUDING staging out_len for ECHO/FS_READ so
// edge (e) is observable here (the original fuzz_agent_async_api broker reported out_len 0).

import "user/abi.mc";
import "user/agent_async.mc";
import "std/task.mc";

// ----- a minimal mock broker (mirrors app_run_demo's sys_submit/sys_poll semantics) -------------
const MOCK_SLOTS: usize = 8;
global g_active: [MOCK_SLOTS]bool;
global g_id: [MOCK_SLOTS]u64;
global g_status: [MOCK_SLOTS]i32;
global g_result: [MOCK_SLOTS]i32;
global g_outlen: [MOCK_SLOTS]u32;   // result-payload bytes staged (ECHO/FS_READ) — drives out_len
global g_ready: [MOCK_SLOTS]u64;
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

// ToolReq / ToolEvent byte offsets (mirror user/abi.mc).
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
        g_outlen[s] = 0;
        g_ready[s] = g_clock;
        return 0;
    }

    let slot: usize = mock_free_slot();
    if slot == MOCK_SLOTS { return E_AGAIN; }   // back-pressure (drives edge (c)'s submit_err)
    let id: u64 = g_next;
    g_next = g_next + 1;
    g_active[slot] = true;
    g_id[slot] = id;
    g_status[slot] = 0;
    g_result[slot] = 0;
    g_outlen[slot] = 0;
    g_ready[slot] = g_clock + (flags as u64);
    g_inflight = g_inflight + 1;

    if op == TOOL_OP_SUM {
        g_result[slot] = ((arg & 0x7FFF_FFFF) as i32) + 2;
    } else if op == TOOL_OP_ECHO {
        g_result[slot] = in_len as i32;           // bytes "echoed"
        g_outlen[slot] = in_len;                  // staged payload bytes -> drives ToolFut_out_len
    } else if op == TOOL_OP_TIMEOUT {
        g_status[slot] = E_TIMEDOUT as i32;
    } else if op == TOOL_OP_FS_READ {
        g_result[slot] = arg as i32;              // pretend we read `path_len` bytes
        g_outlen[slot] = arg as u32;              // staged read bytes -> drives ToolFut_out_len
    } else if op == TOOL_OP_FS_WRITE {
        g_result[slot] = (in_len - (arg as u32)) as i32;
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
                raw.store<u32>(phys(evp + EV_OUTLEN), g_outlen[best]);
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

fn result_or_err(r: Result<i32, i32>) -> i32 {
    switch r {
        ok(v) => { return v; }
        err(e) => { return e; }
    }
}

export fn async_cancel_edges_run() -> u32 {
    var acc: u32 = 0;
    var pump: ToolPump = uninit;

    // ---- (a) cancel AFTER completion is a no-op (the ready future holds no slot) ----
    // A SUM call completes; its ToolFut latches `ready`. Cancelling a ready future must NOT submit a
    // CANCEL and must NOT touch the (already-zero) inflight count — no double-free path.
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fa: ToolFut = tool_call_async(&pump, TOOL_OP_SUM, 5, 0, 0, 0, 0);
    pump_run_to_completion(&pump, &fa);                    // completes -> ready latched, slot freed
    if g_inflight == 0 { acc = acc ^ 0x1; }               // slot reclaimed by normal completion
    if result_or_err(ToolFut_take_result(&fa)) == 7 { acc = acc ^ 0x2; }  // 5+2
    ToolFut_cancel(&fa);                                  // cancel AFTER completion: must be a no-op
    if g_inflight == 0 { acc = acc ^ 0x4; }               // no spurious slot created/freed

    // ---- (b) DOUBLE cancel of a still-pending future is harmless ----
    // A long-delay future stays pending; cancel it (reclaims its slot), drain the -E_CANCELED, then
    // cancel AGAIN. The second cancel must be a no-op: no second CANCEL submit, no double-free.
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fb: ToolFut = sleep_async(&pump, 50);             // stays pending
    let pb: bool = ToolFut_poll(&fb);
    if !pb && g_inflight == 1 { acc = acc ^ 0x8; }        // exactly one slot held
    ToolFut_cancel(&fb);                                  // first cancel: submit CANCEL
    pump_pump(&pump, 0);                                  // deliver -E_CANCELED -> free the slot
    if g_inflight == 0 { acc = acc ^ 0x10; }              // first cancel reclaimed the slot
    ToolFut_cancel(&fb);                                  // DOUBLE cancel: idempotent no-op
    if g_inflight == 0 { acc = acc ^ 0x20; }              // no double-free, still 0
    ToolFut_cancel(&fb);                                  // triple, for good measure
    if g_inflight == 0 { acc = acc ^ 0x40; }

    // ---- (c) FAILED-submit cancel targets no stale id ----
    // Saturate the broker (8 slots), then a 9th submit is back-pressured (-E_AGAIN), so its ToolFut
    // is born in submit_err state holding NO slot. Cancelling it must be a no-op (no CANCEL submit,
    // no slot churn) — it never reserved anything to free.
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var held: [MOCK_SLOTS]ToolFut = uninit;
    var k: usize = 0;
    while k < MOCK_SLOTS {                                 // fill all 8 slots with long-delay sleeps
        held[k] = sleep_async(&pump, 50);
        k = k + 1;
    }
    if g_inflight == (MOCK_SLOTS as i32) { acc = acc ^ 0x80; }   // broker saturated
    var fc: ToolFut = tool_call_async(&pump, TOOL_OP_SUM, 1, 0, 0, 0, 0); // 9th -> submit_err(-E_AGAIN)
    if !ToolFut_poll(&fc) { } else { acc = acc ^ 0x100; }  // submit_err resolves on first poll
    switch ToolFut_take_result(&fc) {
        ok(v) => {}
        err(e) => { if e == (E_AGAIN as i32) { acc = acc ^ 0x200; } }   // resolved as the submit errno
    }
    let inflight_before: i32 = g_inflight;
    ToolFut_cancel(&fc);                                  // failed-submit cancel: must touch nothing
    if g_inflight == inflight_before { acc = acc ^ 0x400; }  // no stale id targeted, no slot churn
    // Clean up the 8 held slots so the leak detector ends at 0 (cancel each, drain).
    var j: usize = 0;
    while j < MOCK_SLOTS { ToolFut_cancel(&held[j]); j = j + 1; }
    pump_pump(&pump, 0);
    if g_inflight == 0 { acc = acc ^ 0x800; }             // all reclaimed, no leak

    // ---- (e) out_len is NONZERO for a read/echo payload ----
    // net_fetch_async rides TOOL_OP_ECHO; the broker stages `req_len` payload bytes, so after the
    // future is ready ToolFut_out_len must be that count (proves out_len propagation through the
    // pump's stash -> ToolFut). Also covered for read_async (FS_READ stages `path_len` bytes).
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fe: ToolFut = net_fetch_async(&pump, 0, 0, 7, 0, 64);   // req_len 7 -> echoed, out_len 7
    pump_run_to_completion(&pump, &fe);
    if ToolFut_out_len(&fe) == 7 { acc = acc ^ 0x1000; }       // out_len propagated, nonzero
    if g_inflight == 0 { acc = acc ^ 0x2000; }
    mock_reset();
    tool_pump_init(&pump, mock_submit, mock_poll);
    var fr: ToolFut = read_async(&pump, 0, 4, 0, 0, 64);       // path_len 4 -> read 4 bytes
    pump_run_to_completion(&pump, &fr);
    if ToolFut_out_len(&fr) == 4 { acc = acc ^ 0x4000; }       // FS_READ out_len nonzero too
    if g_inflight == 0 { acc = acc ^ 0x8000; }

    // entry-mode contract: 1 = pass, 0 = fail.
    if acc != 0xFFFF { return 0; }
    return 1;
}
