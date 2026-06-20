// examples/apps/fault_probe — a confined U-mode MC app that deliberately hands the kernel BAD
// user pointers and asserts the syscall ABI fails closed with -E_FAULT. This proves the most
// important confinement guarantee at RUNTIME (under QEMU, through the real page-table-aware
// uaccess path), not by static review of the kernel source.
//
// Each probe passes an address far above the agent's mapped region (0x4000_0000, ~1 GiB — well
// past USER_LIMIT), so copy_{from,to}_user_pt rejects it. The app prints FAULT-PROBE: PASS only
// if all three syscalls returned exactly -E_FAULT; the harness greps for that marker.
//
// SYS_READ needs the kernel to hold an agent source (otherwise it returns 0/EOF before the copy),
// so the harness links a STRONG mc_agent_source into the kernel. SYS_POLL needs a queued
// completion before it attempts the copy-out, so we SYS_SUBMIT first.

import "user/sys.mc";
import "user/abi.mc";

// Write a string literal of known length to stdout. (Lengths are counted literally; the strings
// below are fixed.) Casting a *const u8 to usize at the syscall boundary mirrors qjs_host.mc.
fn puts(s: *const u8, len: usize) -> void {
    let ignored: i64 = write(FD_STDOUT, s as usize, len);
}

export fn main() -> i32 {
    puts("FAULT-PROBE: start\n", 19);

    let bad: usize = 0x4000_0000; // unmapped in the agent's address space (above USER_LIMIT)
    var passed: bool = true;

    // (1) SYS_WRITE with a bad SOURCE pointer must return -E_FAULT (copy_from_user_pt fails closed).
    let w: i64 = write(FD_STDOUT, bad, 8);
    if w != E_FAULT {
        passed = false;
        puts("FAULT-PROBE: write not E_FAULT\n", 31);
    }

    // (2) SYS_READ into a bad DESTINATION pointer must return -E_FAULT. The kernel holds an agent
    //     source (strong mc_agent_source linked by the harness), so it reaches the copy-out.
    let r: i64 = read(bad, 8);
    if r != E_FAULT {
        passed = false;
        puts("FAULT-PROBE: read not E_FAULT\n", 30);
    }

    // (3) SYS_SUBMIT a completion, then SYS_POLL into a bad DESTINATION — must return -E_FAULT,
    //     and (per the copy-before-dequeue fix) the completion is NOT lost.
    let id: i64 = submit(99);
    if id < 0 {
        passed = false;
        puts("FAULT-PROBE: submit failed\n", 27);
    }
    let p: i64 = poll(bad);
    if p != E_FAULT {
        passed = false;
        puts("FAULT-PROBE: poll not E_FAULT\n", 30);
    }

    if passed {
        puts("FAULT-PROBE: PASS\n", 18);
    } else {
        puts("FAULT-PROBE: FAIL\n", 18);
    }
    return 0;
}
