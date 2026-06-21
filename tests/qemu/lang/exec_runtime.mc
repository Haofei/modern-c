// Bare-metal riscv64 test entry for the sys_exec demo (tests/qemu/lang/exec_demo.mc)
// — in PURE MC (no C). The all-MC replacement for kernel/arch/riscv64/exec_runtime.c.
//
// Program A (U-mode) prints 'A', then calls sys_exec on a tiny hand-assembled ELF
// (program B) that prints 'B' and exits — so the kernel loads B and runs it in U-mode
// in place of A.
//
// `_start`/`mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c); the user-mode trap path (usermode_setup /
// enter_user) from usermode_runtime.c; the syscall table + set_exec_target from the MC
// exec demo. All three are linked beside this object.
//
// The exec demo imports kernel/core/console.mc (defines `console_putc`); to avoid a
// duplicate definition this unit does NOT import console.mc — it writes the bare 16550
// UART directly for diagnostics.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

const RT_SYS_PUTC: u64 = 2;
const RT_SYS_EXIT: u64 = 3;
const RT_SYS_EXEC: u64 = 10;

const RT_VADDR: u64 = 0x8000_0000;
const RT_EH: usize = 64;  // ELF64 header size
const RT_PH: usize = 56;  // program-header size
const RT_CODE: usize = 20; // 5 instructions
const RT_PROG_LEN: usize = 140; // EH + PH + CODE

fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

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

// Shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;
// User-mode trap path (usermode_runtime.c).
extern fn usermode_setup() -> void;
extern fn enter_user(entry: u64, user_sp: u64) -> void;
// The exec demo (exec_demo.mc): do_ecall issues a syscall from U-mode;
// set_exec_target tells sys_exec where to land the new image + its stack.
extern fn do_ecall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;
extern fn set_exec_target(load_addr: usize, user_sp: u64) -> void;

// Flush the instruction cache after writing code bytes (referenced by exec_demo).
export fn icache_flush() -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "fence.i"
                clobber("memory")
            }
        }
    }
}

global g_prog_b: [140]u8;           // hand-assembled ELF (program B)
global g_load_buf: [4096]u8;        // exec landing zone (page-aligned by linker)
global g_stack_a: [8192]u8;
global g_stack_b: [8192]u8;

fn store8(base: usize, off: usize, v: u8) -> void {
    unsafe { raw.store<u8>(phys(base + off), v); }
}

fn put_u16(base: usize, off: usize, v: u16) -> void {
    store8(base, off, (v & 0xFF) as u8);
    store8(base, off + 1, ((v >> 8) & 0xFF) as u8);
}

fn put_u32(base: usize, off: usize, v: u32) -> void {
    var i: usize = 0;
    while i < 4 {
        store8(base, off + i, ((v >> ((8 * i) as u32)) & 0xFF) as u8);
        i = i + 1;
    }
}

fn put_u64(base: usize, off: usize, v: u64) -> void {
    var i: usize = 0;
    while i < 8 {
        store8(base, off + i, ((v >> ((8 * i) as u64)) & 0xFF) as u8);
        i = i + 1;
    }
}

// Program B: SYS_PUTC 'B'; SYS_EXIT.
fn build_prog_b() -> void {
    let base: usize = (&g_prog_b) as usize;
    var i: usize = 0;
    while i < RT_PROG_LEN {
        store8(base, i, 0);
        i = i + 1;
    }
    store8(base, 0, 0x7F);
    store8(base, 1, 69); // 'E'
    store8(base, 2, 76); // 'L'
    store8(base, 3, 70); // 'F'
    store8(base, 4, 2);  // ELFCLASS64
    store8(base, 5, 1);  // little-endian
    put_u64(base, 24, RT_VADDR);      // e_entry
    put_u64(base, 32, RT_EH as u64);  // e_phoff
    put_u16(base, 54, RT_PH as u16);  // e_phentsize
    put_u16(base, 56, 1);             // e_phnum

    let ph: usize = RT_EH;
    put_u32(base, ph + 0, 1);                      // p_type = PT_LOAD
    put_u32(base, ph + 4, 5);                      // p_flags = R|X
    put_u64(base, ph + 8, (RT_EH + RT_PH) as u64); // p_offset
    put_u64(base, ph + 16, RT_VADDR);              // p_vaddr
    put_u64(base, ph + 32, RT_CODE as u64);        // p_filesz
    put_u64(base, ph + 40, RT_CODE as u64);        // p_memsz

    let code: usize = RT_EH + RT_PH;
    put_u32(base, code + 0,  0x0020_0893); // li a7, 2 (SYS_PUTC)
    put_u32(base, code + 4,  0x0420_0513); // li a0, 'B' (0x42)
    put_u32(base, code + 8,  0x0000_0073); // ecall
    put_u32(base, code + 12, 0x0030_0893); // li a7, 3 (SYS_EXIT)
    put_u32(base, code + 16, 0x0000_0073); // ecall
}

// Program A: print 'A', then exec program B (never returns here on success).
fn user_main_a() -> void {
    do_ecall(RT_SYS_PUTC, 65, 0, 0); // 'A'
    do_ecall(RT_SYS_EXEC, ((&g_prog_b) as usize) as u64, RT_PROG_LEN as u64, 0);
    do_ecall(RT_SYS_PUTC, 88, 0, 0); // 'X' — only if exec failed
    while true {}
}

export fn test_main() -> void {
    uputs("exec booting\n");
    build_prog_b();
    usermode_setup();
    let sp_b: u64 = (((&g_stack_b) as usize) as u64) + 8192;
    set_exec_target((&g_load_buf) as usize, sp_b);
    uputs("entering program A\n");
    let sp_a: u64 = (((&g_stack_a) as usize) as u64) + 8192;
    enter_user(((&user_main_a) as usize) as u64, sp_a);
    mc_halt(); // not reached
}
