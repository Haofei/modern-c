// kernel/core/syscall — a syscall dispatch table keyed by number, backed by a
// function-pointer table. The trap path reads the syscall number and arguments
// from an `ecall` and calls `syscall_dispatch`. Unregistered numbers fail closed
// (ENOSYS) rather than calling through an empty slot — no silent ignore, no
// unchecked jump. This is the dispatch skeleton; privilege separation (user mode)
// and the full ABI come later.

const SYS_MAX: usize = 16;
const SYS_ENOSYS: u64 = 0xFFFF_FFFF_FFFF_FFFF; // (u64)-1: no such syscall

struct SyscallTable {
    handlers: [SYS_MAX]fn(u64, u64, u64) -> u64,
    registered: [SYS_MAX]bool,
}

export fn syscall_init(t: *mut SyscallTable) -> void {
    var i: usize = 0;
    while i < SYS_MAX {
        t.registered[i] = false;
        i = i + 1;
    }
}

export fn syscall_register(t: *mut SyscallTable, number: usize, handler: fn(u64, u64, u64) -> u64) -> void {
    if number >= SYS_MAX {
        unreachable; // syscall number out of range
    }
    t.handlers[number] = handler;
    t.registered[number] = true;
}

// Dispatch one syscall (a0/a1/a2). Bounds- and registration-checked; an unknown
// number returns ENOSYS instead of trapping or calling a null handler.
export fn syscall_dispatch(t: *mut SyscallTable, number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    let idx: usize = number as usize;
    if idx >= SYS_MAX {
        return SYS_ENOSYS;
    }
    if !t.registered[idx] {
        return SYS_ENOSYS;
    }
    let handler: fn(u64, u64, u64) -> u64 = t.handlers[idx];
    return handler(arg0, arg1, arg2);
}
