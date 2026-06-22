// Bare-metal riscv64 test entry for the hand-written user-mode task — in PURE MC
// (no C). The all-MC replacement for kernel/arch/riscv64/user_runtime.c.
//
// `_start`/`mc_halt`/`puts_` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c); the U-mode trap path (ecall dispatch +
// privilege drop), `do_ecall`/`enter_user`/`usermode_setup` come from the shared
// usermode runtime (kernel/arch/riscv64/usermode_runtime.c) — both linked beside
// this object. This unit supplies the U-mode program (`user_main`) that reaches the
// kernel only through ecalls, exactly as the C did.
//
// The demo this links against (tests/qemu/lang/syscall_demo.mc) imports
// kernel/core/console.mc (DEFINES console_putc); this runtime is linked beside it,
// so it does NOT import console.mc (that would duplicate the symbol). Kernel-side
// banners go out the bare 16550 UART directly; all U-mode I/O flows through do_ecall.

import "tests/qemu/lib/test_report.mc";

const RT_SYS_PUTC: u64 = 2;
const RT_SYS_WRITE: u64 = 4;
const RT_SYS_EXIT: u64 = 3;

const RT_NEG1: u64 = 0xFFFF_FFFF_FFFF_FFFF; // (u64)-1: copy_from_user rejection

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The shared U-mode trap bring-up (usermode_runtime.c): install the trap vector
// (ecall dispatch + SYS_EXIT) + PMP, then drop to U-mode at `entry` with `user_sp`.
// `do_ecall` issues an M/U environment call with the SBI-style integer ABI.
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn do_ecall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;

// A message in user memory, passed to the kernel by pointer (copied in via
// copy_from_user, which validates the range). Kernel-resident (the image loads at
// 0x8000_0000), so its address falls in the demo's user range and is accepted.
global g_user_msg: [8]u8;

// 8 KiB U-mode stack.
global g_user_stack: [8192]u8;

// The user program. Runs in U-mode; reaches the kernel only through ecalls. Its
// address is handed to enter_user, so it must be an emitted symbol — hence `export`.
export fn user_main() -> void {
    let _u: u64 = do_ecall(RT_SYS_PUTC, 'U' as u64, 0, 0);
    let _s: u64 = do_ecall(RT_SYS_PUTC, 'S' as u64, 0, 0);
    let _r: u64 = do_ecall(RT_SYS_PUTC, 'R' as u64, 0, 0);

    let msg_addr: usize = (&g_user_msg[0]) as usize;
    let _w: u64 = do_ecall(RT_SYS_WRITE, msg_addr as u64, 8, 0); // valid copy

    let bad: u64 = do_ecall(RT_SYS_WRITE, 0x10, 8, 0); // out of range
    var ch: u64 = 'X' as u64;
    if bad == RT_NEG1 {
        ch = 'R' as u64;
    }
    let _b: u64 = do_ecall(RT_SYS_PUTC, ch, 0, 0);

    let _e: u64 = do_ecall(RT_SYS_EXIT, 0, 0, 0);
    while true {}
}

export fn test_main() -> void {
    g_user_msg[0] = 'F' as u8;
    g_user_msg[1] = 'R' as u8;
    g_user_msg[2] = 'O' as u8;
    g_user_msg[3] = 'M' as u8;
    g_user_msg[4] = 'U' as u8;
    g_user_msg[5] = 'S' as u8;
    g_user_msg[6] = 'E' as u8;
    g_user_msg[7] = 'R' as u8;

    uputs("kernel: configuring user mode\n");
    usermode_setup();
    uputs("kernel: entering user\n");
    let entry: usize = (&user_main) as usize;
    let sp_top: usize = (&g_user_stack[0]) as usize + 8192;
    enter_user(entry, sp_top);
    mc_halt(); // not reached
}
