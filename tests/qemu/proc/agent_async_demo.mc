// End-to-end QEMU proof of the AGENT-FACING async API (user/agent_async.mc): an `async fn` agent
// does `let a = await read_async(...); let b = await tool_call_async(...)`, plus a sleep_async
// (timeout) and a timeout-then-CANCEL path, driven to completion by `pump_run_to_completion` over
// the `ToolFut`/`ToolPump` leaves — all running on a bare riscv64 kernel under QEMU.
//
// The syscall Tool ABI (sys_submit/sys_poll) is backed here by an IN-KERNEL broker shim with the
// SAME contract as tests/qemu/proc/app_run_demo.mc's mock broker (delay-driven readiness, slot
// reclaim on cancel) — so this is the task's permitted fallback to a full user-process gate: it
// drives the SAME ToolFut leaves against a real broker (await resolves through the ABI, cancel
// reclaims the slot, timeout fires), without standing up an Sv39 user address space + ecall trap.
//
// Output token `ARW` (Agent constructed -> Resolved -> sleW/Wrapped up) + AGENT-ASYNC-API-OK proves
// the awaits resolved and the cancel reclaimed the slot. context_runtime.mc supplies _start/putc_/
// puts_/mc_halt and calls test_main.

import "user/abi.mc";
import "user/agent_async.mc";
import "std/task.mc";

extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;

// ----- the in-kernel broker shim (same (req_ptr)->id / (events_ptr,max,timeout)->count contract
// as app_run_demo's sys_submit/sys_poll). Addresses are kernel-resident here, so the broker reads/
// writes the ToolReq/ToolEvent via raw.load/raw.store (address-as-data), exactly like the host
// fixture — no UserPtr copy path is needed for this kernel-mode proof. -----
const MOCK_SLOTS: usize = 8;
global g_active: [MOCK_SLOTS]bool;
global g_id: [MOCK_SLOTS]u64;
global g_status: [MOCK_SLOTS]i32;
global g_result: [MOCK_SLOTS]i32;
global g_ready: [MOCK_SLOTS]u64;
global g_clock: u64 = 0;
global g_next: u64 = 1;
global g_inflight: i32 = 0;

const REQ_OP: usize = 0;
const REQ_FLAGS: usize = 4;
const REQ_ARG: usize = 8;
const REQ_IN_LEN: usize = 24;
const EV_ID: usize = 0;
const EV_STATUS: usize = 8;
const EV_RESULT: usize = 12;
const EV_OUTLEN: usize = 16;
const EV_RESERVED: usize = 20;

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

export fn k_submit(req_ptr: usize) -> i64 {
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
        g_ready[s] = g_clock;
        return 0;
    }
    let slot: usize = mock_free_slot();
    if slot == MOCK_SLOTS { return E_AGAIN; }
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
        g_result[slot] = in_len as i32;
    } else if op == TOOL_OP_TIMEOUT {
        g_status[slot] = E_TIMEDOUT as i32;
    } else if op == TOOL_OP_FS_READ {
        g_result[slot] = arg as i32;
    } else if op == TOOL_OP_FS_WRITE {
        g_result[slot] = (in_len - (arg as u32)) as i32;
    } else {
        g_active[slot] = false; g_inflight = g_inflight - 1; return E_DENIED;
    }
    return id as i64;
}

export fn k_poll(events_ptr: usize, max: usize, timeout: usize) -> i64 {
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

// ----- the agent: two awaits over the stable wrappers (read then a SUM tool call) -----
fn unwrap(r: Result<i32, i32>) -> i32 {
    switch r { ok(v) => { return v; } err(e) => { return e; } }
}

async fn agent(p: *mut ToolPump) -> i32 {
    // `let a = await read_async(...); let b = await tool_call_async(...);` — the deliverable shape.
    let ra: Result<i32, i32> = await read_async(p, 0, 5, 0, 0, 0);          // FS read -> 5 (path_len)
    let rb: Result<i32, i32> = await tool_call_async(p, TOOL_OP_SUM, 35, 0, 0, 0, 0); // SUM(35) -> 37
    return unwrap(ra) + unwrap(rb);   // 5 + 37 == 42
}

export fn agent_async_demo() -> u32 {
    var pump: ToolPump = uninit;
    tool_pump_init(&pump, k_submit, k_poll);

    // (1) the agent's two awaits resolve through the API over the broker.
    var f: agent__Fut = agent(&pump);
    putc_(65); // 'A' — agent future constructed
    pump_run_to_completion(&pump, &f);
    let got: i32 = agent__Fut_take_result(&f);
    putc_(82); // 'R' — resolved
    if got != 42 { return 0; }
    if g_inflight != 0 { return 0; }   // both slots reclaimed on completion

    // (2) sleep_async completes as err(E_TIMEDOUT) — the "slept" convention.
    var fs: ToolFut = sleep_async(&pump, 2);
    pump_run_to_completion(&pump, &fs);
    var slept: bool = false;
    switch ToolFut_take_result(&fs) {
        ok(v) => {}
        err(e) => { if e == (E_TIMEDOUT as i32) { slept = true; } }
    }
    if !slept { return 0; }
    if g_inflight != 0 { return 0; }

    // (3) timeout-then-CANCEL: a long sleep stays pending; cancel reclaims its broker slot.
    var fc: ToolFut = sleep_async(&pump, 50);
    let pending: bool = ToolFut_poll(&fc);
    if pending { return 0; }            // must be pending (delay 50, clock advanced 1)
    if g_inflight != 1 { return 0; }    // one slot held
    ToolFut_cancel(&fc);                // submit CANCEL for its id
    pump_pump(&pump, 0);                // deliver the -E_CANCELED completion -> free the slot
    if g_inflight != 0 { return 0; }    // cancel reclaimed the would-be-leaked slot
    putc_(87); // 'W' — wrapped up (sleep + cancel paths proven)

    return 42;
}

export fn test_main() -> void {
    puts_("agent-async-api booting\n");
    let r: u32 = agent_async_demo();
    puts_("\nresult=");
    putc_((48 + ((r / 10) % 10)) as u8);
    putc_((48 + (r % 10)) as u8);
    putc_(10);
    if r == 42 {
        puts_("AGENT-ASYNC-API-OK\n");
    } else {
        puts_("AGENT-ASYNC-API-FAIL\n");
    }
    mc_halt();
}
