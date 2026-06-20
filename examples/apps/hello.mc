// examples/apps/hello — the first MC "app": a confined U-mode program that prints a line
// through the syscall ABI and exits. It imports ONLY the user SDK (user/sys.mc); it never
// touches the kernel or MMIO. Built into an isolated ELF by tools/user/build-app.sh and run
// confined by kernel/arch/riscv64/app_runtime.c. `main` returns 0 on success.

import "user/sys.mc";

global g_msg: [6]u8;

export fn main() -> i32 {
    g_msg[0] = 0x68; // 'h'
    g_msg[1] = 0x65; // 'e'
    g_msg[2] = 0x6C; // 'l'
    g_msg[3] = 0x6C; // 'l'
    g_msg[4] = 0x6F; // 'o'
    g_msg[5] = 0x0A; // '\n'
    let n: i64 = write(FD_STDOUT, (&g_msg[0]) as usize, 6);
    if n != 6 {
        return 1;
    }
    return 0;
}
