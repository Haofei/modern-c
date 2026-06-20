// user/libc/stubs — the small C-ABI surface QuickJS references but that has no real behavior in
// a confined agent: process control (abort/assert -> trap), wall-clock time (epoch stubs; Date
// is not yet wired to a capability clock), and the stdio stream objects. All in MC.

import "std/addr.mc";
import "std/mem.mc";
import "user/libc/lcommon.mc";

// abort()/assert-failure are unrecoverable: diverge into the MC trap path (the runtime's
// mc_trap_Unreachable handler halts the agent). Both are C `noreturn`.
export fn abort() -> void {
    unreachable;
}

export fn __assert_fail(expr: *const u8, file: *const u8, line: i32, func: *const u8) -> void {
    unreachable;
}

// exit(code): a confined agent has no host process to exit; treat as abort for now (Phase 6
// routes this to SYS_EXIT via the agent runtime).
export fn exit(code: i32) -> void {
    unreachable;
}

// ---- wall-clock time: epoch stubs (Date evaluates; values are not real time yet) ----

export fn clock_gettime(clk_id: i32, tp: *mut u8) -> i32 {
    mem_set(pa(tp as usize), 0, 16); // struct timespec { long tv_sec, tv_nsec; }
    return 0;
}

export fn gettimeofday(tv: *mut u8, tz: *mut u8) -> i32 {
    mem_set(pa(tv as usize), 0, 16); // struct timeval { long tv_sec, tv_usec; }
    return 0;
}

export fn time(t: *mut u8) -> i64 {
    if (t as usize) != 0 {
        unsafe {
            raw.store<i64>(pa(t as usize), 0);
        }
    }
    return 0;
}

export fn localtime_r(timep: *const u8, result: *mut u8) -> *mut u8 {
    mem_set(pa(result as usize), 0, 56); // struct tm (zeroed -> epoch fields)
    return lc_as_ptr(result as usize);
}

export fn gmtime_r(timep: *const u8, result: *mut u8) -> *mut u8 {
    return localtime_r(timep, result);
}

// NOTE: the stdio stream objects (stdout/stderr/stdin) and the console/syscall hooks
// (mc_console_write/sys_write) are PLATFORM symbols provided by the agent runtime (the crt/
// syscall layer), not the libc — QuickJS only passes the streams to fprintf, which ignores them.
