// Bare-metal riscv64 test entry for ELF load-and-run (tests/qemu/lang/elf_run_demo.mc)
// — in PURE MC (no C). The all-MC replacement for kernel/arch/riscv64/elf_run_runtime.c.
//
// Builds a tiny in-memory ELF64 whose single PT_LOAD segment is hand-assembled RV64
// code that prints "OK" and exits via syscalls. The MC loader (elf_load_run) parses +
// loads it; usermode_setup + enter_user run it in U-mode.
//
// `_start`/`mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c); the user-mode trap path from
// usermode_runtime.c; the syscall table + elf_load_run from the MC demo. All linked
// beside this object.
//
// The demo imports kernel/core/console.mc (defines `console_putc`); to avoid a
// duplicate definition this unit does NOT import console.mc — it writes the bare 16550
// UART directly for diagnostics.

import "tests/qemu/lib/test_report.mc";

const RT_VADDR: u64 = 0x8000_0000;
const RT_EH: usize = 64;   // ELF64 header size
const RT_PH: usize = 56;   // program-header size
const RT_CODE: usize = 28; // 7 instructions
const RT_ELF_LEN: usize = 148; // EH + PH + CODE

// Shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;
// User-mode trap path (usermode_runtime.c).
extern fn usermode_setup() -> void;
extern fn enter_user(entry: u64, user_sp: u64) -> void;
// The ELF loader from the demo (elf_run_demo.mc): parse + load the first PT_LOAD
// segment to `dst`, returning the user entry physical address (0 on invalid image).
extern fn elf_load_run(elf_base: usize, elf_len: usize, dst: usize) -> u64;

global g_user_elf: [148]u8;     // hand-assembled ELF
global g_load_buf: [4096]u8;    // segment landing zone (page-aligned by linker)
global g_user_stack: [8192]u8;

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

// A user program: SYS_PUTC 'O'; SYS_PUTC 'K'; SYS_EXIT. (SYS_PUTC=2, SYS_EXIT=3.)
fn build_elf() -> void {
    let base: usize = (&g_user_elf) as usize;
    var i: usize = 0;
    while i < RT_ELF_LEN {
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
    put_u32(base, code + 4,  0x04f0_0513); // li a0, 'O'
    put_u32(base, code + 8,  0x0000_0073); // ecall
    put_u32(base, code + 12, 0x04b0_0513); // li a0, 'K'
    put_u32(base, code + 16, 0x0000_0073); // ecall
    put_u32(base, code + 20, 0x0030_0893); // li a7, 3 (SYS_EXIT)
    put_u32(base, code + 24, 0x0000_0073); // ecall
}

export fn test_main() -> void {
    uputs("kernel: loading user ELF\n");
    build_elf();
    usermode_setup();
    let entry: u64 = elf_load_run((&g_user_elf) as usize, RT_ELF_LEN, (&g_load_buf) as usize);
    // the loaded bytes are instructions — flush the instruction cache.
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "fence.i"
                clobber("memory")
            }
        }
    }
    uputs("kernel: running loaded ELF\n");
    let sp: u64 = (((&g_user_stack) as usize) as u64) + 8192;
    enter_user(entry, sp);
    mc_halt(); // not reached
}
