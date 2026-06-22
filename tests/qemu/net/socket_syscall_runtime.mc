// Bare-metal riscv64 M-mode test entry for the socket-syscall demo
// (tests/qemu/net/socket_syscall_demo.mc) — in PURE MC (no C). The all-MC replacement
// for kernel/arch/riscv64/socket_syscall_runtime.c.
//
// `_start`/`mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c); the U-mode trap path (ecall dispatch +
// privilege drop) and `do_ecall`/`enter_user`/`usermode_setup` come from the shared
// usermode runtime (kernel/arch/riscv64/usermode_runtime.c) — both linked beside this
// object. This unit supplies the U-mode program (`user_main`) that recvfrom's the
// datagram the kernel pre-delivered to its socket; the socket-backed syscall table
// comes from the existing MC socket_syscall_demo.
//
// The demo imports kernel/core/console.mc (DEFINES console_putc); this runtime is
// linked beside it, so it does NOT import console.mc — it would duplicate that symbol.
// U-mode output flows through `do_ecall` (SYS_PUTC); kernel banners go bare to UART.

import "tests/qemu/lib/test_report.mc";

const RT_SYS_PUTC: u64 = 2;
const RT_SYS_EXIT: u64 = 3;
const RT_SYS_RECVFROM: u64 = 9;

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The shared U-mode trap bring-up (usermode_runtime.c): install the trap vector
// (ecall dispatch + SYS_EXIT) + PMP, then drop to U-mode; do_ecall issues an
// environment call with the SBI-style integer ABI.
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn do_ecall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;

// 8 KiB U-mode stack.
global g_user_stack: [8192]u8;

// Runs in U-mode; its address is handed to enter_user, so it must be an emitted
// symbol — hence `export`.
export fn user_main() -> void {
    var buf: [16]u8 = uninit;
    let buf_addr: usize = (&buf[0]) as usize;
    var i: usize = 0;
    while i < 16 {
        unsafe { raw.store<u8>(phys(buf_addr + i), 0); }
        i = i + 1;
    }
    let n: u64 = do_ecall(RT_SYS_RECVFROM, 0, buf_addr as u64, 16); // socket 0

    let _r: u64 = do_ecall(RT_SYS_PUTC, 'R' as u64, 0, 0); // marker, then received bytes
    var j: u64 = 0;
    while j < n {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(buf_addr + (j as usize))); }
        let _p: u64 = do_ecall(RT_SYS_PUTC, b as u64, 0, 0);
        j = j + 1;
    }
    let _e: u64 = do_ecall(RT_SYS_EXIT, 0, 0, 0);
    while true {}
}

export fn test_main() -> void {
    uputs("socket-syscall booting\n");
    usermode_setup();
    uputs("entering user\n");
    let entry: usize = (&user_main) as usize;
    let sp_top: usize = (&g_user_stack[0]) as usize + 8192;
    enter_user(entry, sp_top);
    mc_halt();
}
