// Bare-metal riscv64 test entry for the U-mode server demo
// (tests/qemu/lang/userserver_demo.mc) — in PURE MC (no C). The all-MC replacement
// for kernel/arch/riscv64/userserver_runtime.c.
//
// The server runs in USER mode and reaches the kernel only through ecalls;
// usermode_setup (shared usermode_runtime.c) wires the M-mode trap vector + the MC
// syscall table, then enter_user drops to U-mode at server_main. `_start`, `mc_halt`,
// `puts_`, `usermode_setup`, `enter_user`, and `do_ecall` come from the shared
// runtimes linked beside this object (context_runtime.c + usermode_runtime.c).

// Module consts emit as EXTERNAL LLVM symbols, so prefix RT_ to avoid colliding
// with the same-named consts in userserver_demo.mc linked beside this object.
const RT_SYS_RECV: u64 = 5;
const RT_SYS_REPLY: u64 = 6;
const RT_SYS_VERIFY: u64 = 7;
const RT_SYS_EXIT: u64 = 3;
const RT_DONE: u64 = 0xFFFF_FFFF_FFFF_FFFF;

// Shared runtime seam (context_runtime.c / usermode_runtime.c).
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn do_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64;

// U-mode task stack (8 KiB). 16-byte aligned for the RISC-V ABI.
global g_user_stack: [8192]u8;

// Runs in U-mode: pull requests, reply doubled, then ask the kernel to verify + exit.
// Every effect crosses the syscall gate (do_ecall) — the task cannot touch kernel
// memory directly.
fn server_main() -> void {
    while true {
        let r: u64 = do_ecall(RT_SYS_RECV, 0, 0, 0);
        if r == RT_DONE {
            break;
        }
        let _ignored: u64 = do_ecall(RT_SYS_REPLY, r * 2, 0, 0);
    }
    let _v: u64 = do_ecall(RT_SYS_VERIFY, 0, 0, 0);
    let _e: u64 = do_ecall(RT_SYS_EXIT, 0, 0, 0);
    while true {}
}

export fn test_main() -> void {
    puts_("userserver booting\n");
    usermode_setup(); // installs trap vector, PMP, and the MC syscall table
    puts_("kernel: entering U-mode server\n");
    let sp: usize = (&g_user_stack) as usize + 8192;
    enter_user((&server_main) as usize, sp);
    mc_halt();
}
