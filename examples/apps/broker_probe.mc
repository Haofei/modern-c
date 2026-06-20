// examples/apps/broker_probe — a confined U-mode MC app that proves the mock broker's CANCELLATION
// and TIMEOUT paths at the ABI level (no JS), under QEMU:
//   - cancellation: submit a delayed request, CANCEL it, and observe its completion carry
//     status -E_CANCELED;
//   - timeout: submit a TIMEOUT op and observe its completion carry status -E_TIMEDOUT.
// Prints BROKER-PROBE: PASS only if both completions carried the expected id and status.

import "user/sys.mc";
import "user/abi.mc";

global g_ev: ToolEvent; // kernel fills this on each poll (copied out through the page table)

fn puts(s: *const u8, len: usize) -> void {
    let ignored: i64 = write(FD_STDOUT, s as usize, len);
}

// Poll until one completion is delivered into g_ev. Each poll advances the broker's virtual clock,
// so a delayed completion eventually becomes ready. Returns 1 if delivered, else 0 (gave up).
fn poll_one() -> i64 {
    var tries: u32 = 0;
    while tries < 500 {
        let p: i64 = poll((&g_ev) as usize);
        if p == 1 {
            return 1;
        }
        if p < 0 {
            return p;
        }
        tries = tries + 1;
    }
    return 0;
}

export fn main() -> i32 {
    puts("BROKER-PROBE: start\n", 20);
    var passed: bool = true;

    // (1) CANCELLATION: a delayed SUM, then cancel it -> its completion carries -E_CANCELED.
    var r: ToolReq = uninit;
    r.op = TOOL_OP_SUM;
    r.flags = 10; // 10-tick delay, so it is still in flight when we cancel
    r.arg = 5;
    r.in_ptr = 0;
    r.in_len = 0;
    r.out_cap = 0;
    r.out_ptr = 0;
    let id: i64 = submit((&r) as usize);
    if id < 0 {
        passed = false;
    }

    var rcancel: ToolReq = uninit;
    rcancel.op = TOOL_OP_CANCEL;
    rcancel.flags = 0;
    rcancel.arg = id as u64;
    rcancel.in_ptr = 0;
    rcancel.in_len = 0;
    rcancel.out_cap = 0;
    rcancel.out_ptr = 0;
    if submit((&rcancel) as usize) != 0 { // CANCEL returns 0 (accepted)
        passed = false;
    }

    if poll_one() != 1 {
        passed = false;
    }
    if g_ev.id != (id as u64) {
        passed = false;
    }
    if (g_ev.status as i64) != E_CANCELED {
        passed = false;
    }

    // (2) TIMEOUT: a TIMEOUT op completes (after its delay) with -E_TIMEDOUT.
    var rt: ToolReq = uninit;
    rt.op = TOOL_OP_TIMEOUT;
    rt.flags = 2;
    rt.arg = 0;
    rt.in_ptr = 0;
    rt.in_len = 0;
    rt.out_cap = 0;
    rt.out_ptr = 0;
    let tid: i64 = submit((&rt) as usize);
    if tid < 0 {
        passed = false;
    }
    if poll_one() != 1 {
        passed = false;
    }
    if g_ev.id != (tid as u64) {
        passed = false;
    }
    if (g_ev.status as i64) != E_TIMEDOUT {
        passed = false;
    }

    if passed {
        puts("BROKER-PROBE: PASS\n", 19);
    } else {
        puts("BROKER-PROBE: FAIL\n", 19);
    }
    return 0;
}
