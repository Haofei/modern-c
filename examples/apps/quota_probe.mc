// examples/apps/quota_probe — a confined U-mode MC app that proves the kernel enforces the tool
// ABI quotas with the SPECIFIC errno for each class, at runtime under QEMU:
//   - a request payload over MAX_REQ_BYTES          -> -E_NOCAP  (hard capacity, not retryable)
//   - a result capacity over MAX_RES_BYTES          -> -E_NOCAP
//   - an unknown op selector                        -> -E_DENIED (policy)
//   - more in-flight requests than MAX_INFLIGHT     -> -E_AGAIN  (back-pressure, retryable)
// Prints QUOTA-PROBE: PASS only if every submission returned exactly its expected code.

import "user/sys.mc";
import "user/abi.mc";

fn puts(s: *const u8, len: usize) -> void {
    let ignored: i64 = write(FD_STDOUT, s as usize, len);
}

export fn main() -> i32 {
    puts("QUOTA-PROBE: start\n", 19);
    var passed: bool = true;

    // (1) request payload over the hard request-byte quota -> E_NOCAP (checked before in_ptr is
    //     dereferenced, so in_ptr=0 is fine).
    var r1: ToolReq = uninit;
    r1.op = TOOL_OP_SUM;
    r1.flags = 0;
    r1.arg = 1;
    r1.in_ptr = 0;
    r1.in_len = MAX_REQ_BYTES + 1;
    r1.out_cap = 0;
    r1.out_ptr = 0;
    if submit((&r1) as usize) != E_NOCAP {
        passed = false;
    }

    // (2) result capacity over the hard result-byte quota -> E_NOCAP.
    var r2: ToolReq = uninit;
    r2.op = TOOL_OP_SUM;
    r2.flags = 0;
    r2.arg = 1;
    r2.in_ptr = 0;
    r2.in_len = 0;
    r2.out_cap = MAX_RES_BYTES + 1;
    r2.out_ptr = 0;
    if submit((&r2) as usize) != E_NOCAP {
        passed = false;
    }

    // (3) an unknown op selector -> E_DENIED (policy).
    var r3: ToolReq = uninit;
    r3.op = 999;
    r3.flags = 0;
    r3.arg = 1;
    r3.in_ptr = 0;
    r3.in_len = 0;
    r3.out_cap = 0;
    r3.out_ptr = 0;
    if submit((&r3) as usize) != E_DENIED {
        passed = false;
    }

    // (4) fill the in-flight ring with MAX_INFLIGHT valid requests, then one more -> E_AGAIN.
    var r4: ToolReq = uninit;
    r4.op = TOOL_OP_SUM;
    r4.flags = 0;
    r4.arg = 1;
    r4.in_ptr = 0;
    r4.in_len = 0;
    r4.out_cap = 0;
    r4.out_ptr = 0;
    var i: u32 = 0;
    while i < MAX_INFLIGHT {
        let id: i64 = submit((&r4) as usize);
        if id < 0 {
            passed = false;
        }
        i = i + 1;
    }
    if submit((&r4) as usize) != E_AGAIN {
        passed = false;
    }

    if passed {
        puts("QUOTA-PROBE: PASS\n", 18);
    } else {
        puts("QUOTA-PROBE: FAIL\n", 18);
    }
    return 0;
}
