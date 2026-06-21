// Bare-metal riscv64 M-mode test entry for the file-syscall demo
// (tests/qemu/fs/fs_syscall_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/fs_syscall_runtime.c.
//
// `_start`/`mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c); the U-mode trap path (ecall dispatch +
// privilege drop) and `puts_`/`do_ecall`/`enter_user`/`usermode_setup` come from the
// shared usermode runtime (kernel/arch/riscv64/usermode_runtime.c) — both linked
// beside this object. This unit supplies the U-mode program (`user_main`) that writes
// a file and reads it back entirely through ecalls, and the VFS-backed syscall table
// comes from the existing MC fs_syscall_demo.
//
// The demo imports kernel/core/console.mc (DEFINES console_putc); this runtime is
// linked beside it, so it does NOT import console.mc — it would duplicate that symbol.
// All U-mode I/O here flows through `do_ecall` (SYS_PUTC); the only direct UART writes
// are the kernel-side banners, done bare on the 16550 transmit register.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

const RT_SYS_PUTC: u64 = 2;
const RT_SYS_EXIT: u64 = 3;
const RT_SYS_OPEN: u64 = 5;
const RT_SYS_FWRITE: u64 = 6;
const RT_SYS_FREAD: u64 = 7;
const RT_SYS_FCLOSE: u64 = 8;

// Write one byte to the bare 16550 UART transmit register.
fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

// Write a NUL-terminated string over the bare UART.
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The shared U-mode trap bring-up (usermode_runtime.c): install the trap vector
// (ecall dispatch + SYS_EXIT) + PMP, then drop to U-mode at `entry` with `user_sp`.
// `do_ecall` issues an M/U environment call with the SBI-style integer ABI.
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn do_ecall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;

// The file path + content the U-mode program writes/reads. Kernel-resident (the
// image loads at 0x8000_0000), so their addresses fall in the demo's user range
// [USER_BASE, USER_LIMIT) and copy_from_user accepts them — matching the C statics.
global g_fname: [1]u8;
global g_content: [2]u8;

// 8 KiB U-mode stack (16-byte aligned by the [N]u8 .bss placement is not guaranteed;
// the demo never relies on >8-byte alignment, and enter_user receives the top).
global g_user_stack: [8192]u8;

// Runs in U-mode; touches the filesystem only through syscalls. Its address is
// handed to enter_user, so it must be an emitted symbol — hence `export`.
export fn user_main() -> void {
    let fname_addr: usize = (&g_fname[0]) as usize;
    let content_addr: usize = (&g_content[0]) as usize;

    let fd: u64 = do_ecall(RT_SYS_OPEN, fname_addr as u64, 1, 0);
    let _w: u64 = do_ecall(RT_SYS_FWRITE, fd, content_addr as u64, 2);
    let _c: u64 = do_ecall(RT_SYS_FCLOSE, fd, 0, 0);

    let rfd: u64 = do_ecall(RT_SYS_OPEN, fname_addr as u64, 1, 0); // fresh fd at pos 0
    var buf: [8]u8 = uninit;
    let buf_addr: usize = (&buf[0]) as usize;
    let n: u64 = do_ecall(RT_SYS_FREAD, rfd, buf_addr as u64, 8);

    let _f: u64 = do_ecall(RT_SYS_PUTC, 'F' as u64, 0, 0); // marker, then bytes read back
    var i: u64 = 0;
    while i < n {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(buf_addr + (i as usize))); }
        let _p: u64 = do_ecall(RT_SYS_PUTC, b as u64, 0, 0);
        i = i + 1;
    }
    let _e: u64 = do_ecall(RT_SYS_EXIT, 0, 0, 0);
    while true {}
}

export fn test_main() -> void {
    g_fname[0] = 'f' as u8;
    g_content[0] = 'H' as u8;
    g_content[1] = 'I' as u8;

    uputs("fs-syscall booting\n");
    usermode_setup();
    uputs("entering user\n");
    let entry: usize = (&user_main) as usize;
    let sp_top: usize = (&g_user_stack[0]) as usize + 8192;
    enter_user(entry, sp_top);
    mc_halt(); // not reached
}
