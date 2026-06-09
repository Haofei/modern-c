// The shell as a real USER-MODE process: the REPL (line discipline + parser + core
// builtins) runs in U-mode and reaches the kernel only through syscalls — SYS_GETC /
// SYS_PUTC for console I/O, SYS_PROC_* for process introspection, SYS_EXIT to quit. The
// kernel mediates all hardware; the shell touches no MMIO. `top` is dispatched here, in
// the user shell layer (not baked into the generic parser), and reads the real ProcTable.

import "kernel/core/shell.mc";
import "kernel/core/tty.mc";
import "kernel/core/syscall.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/lib/proc_snapshot.mc"; // proc_info_encode/pid/state (named SYS_PROC_INFO ABI)
import "kernel/core/heap.mc";
import "kernel/arch/riscv64/csr.mc"; // wait_for_interrupt + enable_external_interrupt (MC asm)
import "std/addr.mc";

const SYS_GETC: usize = 5;
const SYS_PUTC: usize = 6;
const SYS_PROC_COUNT: usize = 7; // -> number of processes
const SYS_PROC_INFO: usize = 8;  // (i) -> (pid << 4) | state_code
const SYS_WAIT: usize = 9;       // kernel idles on wfi (in M-mode) until an interrupt
const SYS_EXIT: usize = 3; // handled by the trap (returns to the kernel)

const UART_DR: usize = 0x1000_0000;
const UART_LSR: usize = 0x1000_0005;
const CR: u8 = 0x0D;
const LF: u8 = 0x0A;
const DEL: u8 = 0x7F;
const BS: u8 = 0x08;
const STACK_SIZE: usize = 4096;
const NOTFOUND: u32 = 127;

// the user-mode program reaches the kernel through this (defined in usermode_runtime.c)
extern fn do_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64;
// pop a byte the UART RX interrupt buffered (0x100 if empty); defined in usermode_runtime
extern fn uart_rx_pop() -> u64;

const RX_EMPTY: u64 = 0x100;

// PLIC + UART registers (QEMU virt) for routing the UART RX interrupt.
const UART_IER: usize = 0x1000_0001;
const PLIC_PRIORITY_UART: usize = 0x0C00_0028; // priority[10]
const PLIC_ENABLE_CTX0: usize = 0x0C00_2000;
const PLIC_THRESHOLD_CTX0: usize = 0x0C20_0000;
const UART_IRQ_BIT: u32 = 0x400; // 1 << 10

global g_sys: SyscallTable;
global g_sh: Shell;
global g_tty: Tty;
global g_line: [64]u8;

// A real process table the kernel maintains; `top` reads it through SYS_PROC_*.
global g_procs: ProcTable;
global g_heap: Heap;
global g_heapmem: [65536]u8;

fn dummy_task() -> void {} // spawned to populate the table (never scheduled here)

fn alloc_stack() -> usize {
    let base: PAddr = heap_alloc(&g_heap, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

// ---- kernel side: privileged syscall handlers (run in the trap, not in U-mode) ----
// Non-blocking: return a byte the UART RX interrupt buffered, or RX_EMPTY.
fn sys_getc(a: u64, b: u64, c: u64) -> u64 {
    return uart_rx_pop();
}
// Idle the CPU until an interrupt is pending. Runs in the M-mode trap (wfi is illegal in
// U-mode on this core), so the shell must reach it via this syscall, not call wfi itself.
fn sys_wait(a: u64, b: u64, c: u64) -> u64 {
    wait_for_interrupt(); // MC inline asm (kernel/arch/riscv64/csr.mc)
    return 0;
}

// Route the UART RX interrupt to this hart: enable it in the UART + PLIC, then unmask
// the machine external interrupt. All in MC — MMIO via raw stores, mie via csr.mc.
export fn shell_irq_setup() -> void {
    unsafe {
        raw.store<u8>(phys(UART_IER), 0x01);            // UART RX-available interrupt
        raw.store<u32>(phys(PLIC_PRIORITY_UART), 1);    // source priority
        let en: u32 = raw.load<u32>(phys(PLIC_ENABLE_CTX0));
        raw.store<u32>(phys(PLIC_ENABLE_CTX0), en | UART_IRQ_BIT); // enable source 10
        raw.store<u32>(phys(PLIC_THRESHOLD_CTX0), 0);   // threshold 0
    }
    enable_external_interrupt(); // csrs mie, MEIE (MC asm)
}
fn sys_putc(ch: u64, b: u64, c: u64) -> u64 {
    unsafe {
        raw.store<u8>(phys(UART_DR), ch as u8);
    }
    return 0;
}
fn sys_proc_count(a: u64, b: u64, c: u64) -> u64 {
    return proc_count(&g_procs) as u64;
}
fn sys_proc_info(idx: u64, b: u64, c: u64) -> u64 {
    let i: usize = idx as usize;
    if i < proc_count(&g_procs) {
        return proc_info_encode(proc_pid_at(&g_procs, i), proc_state_code(&g_procs, i));
    }
    return 0;
}

export fn syscall_setup() -> void {
    syscall_init(&g_sys);
    syscall_register(&g_sys, SYS_GETC, sys_getc);
    syscall_register(&g_sys, SYS_PUTC, sys_putc);
    syscall_register(&g_sys, SYS_PROC_COUNT, sys_proc_count);
    syscall_register(&g_sys, SYS_PROC_INFO, sys_proc_info);
    syscall_register(&g_sys, SYS_WAIT, sys_wait);
    // Build a real ProcTable: slot 0 is the running bootstrap; spawn a few more so `top`
    // reflects actual scheduler state (Running for the active slot, Ready for spawned).
    g_heap = heap_new(phys_range(pa((&g_heapmem[0]) as usize), 65536));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    proc_spawn(&g_procs, alloc_stack(), dummy_task);
    proc_spawn(&g_procs, alloc_stack(), dummy_task);
    proc_spawn(&g_procs, alloc_stack(), dummy_task);
}
export fn mc_syscall(number: u64, a0: u64, a1: u64, a2: u64) -> u64 {
    return syscall_dispatch(&g_sys, number, a0, a1, a2);
}

// ---- user side: the REPL, all via syscalls ----
fn u_putc(ch: u8) -> void {
    let r: u64 = do_ecall(SYS_PUTC as u64, ch as u64, 0, 0);
    if r != 0 {
        return; // ignore result (keeps it "used")
    }
}
fn u_prompt() -> void {
    u_putc(0x24); // '$'
    u_putc(0x20);
}
// Block until input is available: the kernel wfi's (in M-mode) until the UART IRQ.
fn u_wait() -> void {
    let w: u64 = do_ecall(SYS_WAIT as u64, 0, 0, 0);
    if w != 0 {
        return; // ignore result
    }
}
fn u_print_dec(n: u64) -> void {
    if n >= 10 {
        u_print_dec(n / 10);
    }
    u_putc((0x30 + (n % 10)) as u8);
}
// state_code (process.mc): 0=Unused 1=Ready 2=Running 3=Blocked 4=Zombie
fn u_state_letter(st: u64) -> u8 {
    if st == 2 {
        return 0x52; // 'R' running
    }
    if st == 1 {
        return 0x72; // 'r' ready
    }
    if st == 3 {
        return 0x42; // 'B' blocked
    }
    if st == 4 {
        return 0x5A; // 'Z' zombie
    }
    return 0x2D; // '-'
}

// `top`: ask the kernel for the process list (via syscalls) and print a PID/ST table.
fn u_top() -> void {
    u_putc(0x50); u_putc(0x49); u_putc(0x44); u_putc(0x20); u_putc(0x53); u_putc(0x54); // "PID ST"
    u_putc(LF);
    let n: u64 = do_ecall(SYS_PROC_COUNT as u64, 0, 0, 0);
    var i: u64 = 0;
    while i < n {
        let info: u64 = do_ecall(SYS_PROC_INFO as u64, i, 0, 0);
        let pid: u64 = proc_info_pid(info) as u64;
        let st: u64 = proc_info_state(info) as u64;
        u_print_dec(pid);
        u_putc(0x20);
        u_putc(0x20);
        u_putc(u_state_letter(st));
        u_putc(LF);
        i = i + 1;
    }
}

fn print_output() -> void {
    var i: usize = 0;
    while i < sh_out_len(&g_sh) {
        u_putc(sh_out_byte(&g_sh, i));
        i = i + 1;
    }
    if sh_out_len(&g_sh) > 0 {
        u_putc(LF);
    }
}

export fn shell_user() -> u32 {
    sh_init(&g_sh);
    tty_init(&g_tty);
    u_prompt();
    var running: bool = true;
    while running {
        // Block for a keystroke: ask for a buffered byte; while none, wfi (the UART RX
        // interrupt wakes us and its ISR fills the ring). No busy spin.
        var got: u64 = do_ecall(SYS_GETC as u64, 0, 0, 0);
        while got == RX_EMPTY {
            u_wait(); // kernel idles on wfi (M-mode) until a keystroke interrupt
            got = do_ecall(SYS_GETC as u64, 0, 0, 0);
        }
        var c: u8 = got as u8;
        if c == CR {
            c = LF;
        }
        if c == DEL {
            c = BS;
        }
        if c == BS {
            u_putc(BS);
            u_putc(0x20);
            u_putc(BS);
        } else {
            u_putc(c);
        }
        tty_input(&g_tty, c);
        if tty_ready(&g_tty) {
            let n: usize = tty_readline(&g_tty, pa((&g_line[0]) as usize), 64);
            sh_run(&g_sh, pa((&g_line[0]) as usize), n);
            // The shell handled a core builtin (echo/true/false/exit); unknown commands
            // fall through to this user shell layer, which dispatches `top` itself.
            var top_lit: [3]u8 = .{ 0x74, 0x6F, 0x70 };
            if sh_code(&g_sh) == NOTFOUND {
                if sh_arg_eq(0, pa((&top_lit[0]) as usize), 3) {
                    u_top();
                }
            } else {
                print_output();
            }
            if sh_is_exit(&g_sh) {
                running = false;
            } else {
                u_prompt();
            }
        }
    }
    u_putc(LF);
    let e: u64 = do_ecall(SYS_EXIT as u64, 0, 0, 0); // returns control to the kernel
    if e != 0 {
        return 1;
    }
    return 0;
}
