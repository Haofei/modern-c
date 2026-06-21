// Bare-metal riscv64 platform runtime for the QuickJS agent bring-up — in PURE MC.
// The all-MC replacement for kernel/arch/riscv64/qjs_runtime.c. This is the platform glue
// (the analogue of crt0 + the syscall shim) the vendored QuickJS engine + the all-MC libc
// need: the console/write hooks (-> UART), the stdio stream DATA symbols, FPU enablement
// (QuickJS computes on doubles), and the entry that calls the agent's main().
//
// QuickJS itself (third_party/quickjs) + openlibm stay vendored C, linked alongside. The
// mc_trap_* checked-arithmetic hooks are NOT defined here: MC's emit-c already emits a
// per-unit `static inline mc_trap_*` (-> __builtin_trap()), so every MC unit is
// self-contained for traps and the QuickJS C objects never reference them.

const UART_THR: usize = 0x1000_0000;
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// stdio stream objects: QuickJS passes these to fprintf, which (in the all-MC libc's
// stdio) ignores the stream — so the VALUE (0) is never dereferenced; only the external
// symbol must resolve. `export global` gives them C-visible external linkage.
export global stdout: usize = 0;
export global stderr: usize = 0;
export global stdin: usize = 0;

// Console hook used by stdio (printf family).
export fn mc_console_write(buf: usize, len: usize) -> void {
    var i: usize = 0;
    while i < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(buf + i)); }
        unsafe { raw.store<u8>(phys(UART_THR), b); }
        i = i + 1;
    }
}

// The write syscall used by the agent (fd ignored; everything goes to the UART).
export fn sys_write(fd: u64, buf: usize, len: u64) -> i64 {
    var i: u64 = 0;
    while i < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(buf + (i as usize))); }
        unsafe { raw.store<u8>(phys(UART_THR), b); }
        i = i + 1;
    }
    return len as i64;
}

// The confined agent front-end's entry (examples/apps/qjs_agent.c).
extern fn main() -> i32;

fn emit(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        unsafe { raw.store<u8>(phys(UART_THR), b); }
        i = i + 1;
    }
}

export fn boot_main() -> void {
    emit("qjs: booting agent\n");
    let rc: i32 = main();
    if rc == 0 { emit("qjs: agent exited 0\n"); }
    else { emit("qjs: agent exited nonzero\n"); }
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. Enable the FPU (mstatus.FS = Initial;
// JS numbers are doubles) before calling in.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n li t0, 0x2000\n csrs mstatus, t0\n call boot_main\n 1: j 1b"
    }
}
