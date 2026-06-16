// exec: a running U-mode program asks the kernel to load and run another program.
// `sys_exec(elf_ptr, len)` parses + loads the ELF's PT_LOAD segment into the kernel's
// load area and enters U-mode at its entry — replacing the caller's image (the call
// never returns). Composes the ELF loader + user mode + the syscall path.

import "kernel/core/syscall.mc";
import "kernel/core/elf.mc";
import "kernel/core/console.mc";
import "std/bytes.mc";
import "std/addr.mc";

const SYS_PUTC: usize = 2;
const SYS_EXEC: usize = 10;
const EXEC_FAIL: u64 = 0xFFFF_FFFF_FFFF_FFFF;

global g_syscalls: SyscallTable;
global g_load_addr: usize; // where exec lands the new image
global g_user_sp: u64;     // the stack the new image runs on

extern fn enter_user(entry: u64, user_sp: u64) -> void;
extern fn icache_flush() -> void; // fence.i after loading code

fn sys_putc(ch: u64, a: u64, b: u64) -> u64 {
    console_putc(ch as u8);
    return 0;
}

fn sys_exec(elf_ptr: u64, len: u64, c: u64) -> u64 {
    var r: ByteReader = byte_reader(pa(elf_ptr as usize), len as usize);
    switch elf_parse_header(&r) {
        ok(h) => {
            var i: u16 = 0;
            while i < h.phnum {
                var ph: ProgramHeader = elf_program_header(&r, h.phoff as usize, h.phentsize as usize, i as usize);
                if ph_is_load(&ph) {
                    switch elf_load_segment(&r, &ph, pa(g_load_addr)) {
                        ok(u) => {}
                        err(e) => { return 1; } // hostile filesz/offset: reject, don't run
                    }
                    icache_flush();
                    let entry: u64 = (g_load_addr as u64) + (h.entry - ph.vaddr);
                    enter_user(entry, g_user_sp); // replaces the caller; never returns
                    return 0;
                }
                i = i + 1;
            }
        }
        err(e) => {}
    }
    return EXEC_FAIL; // bad image: control returns to the caller
}

// usermode_setup() calls this to install the syscall table.
export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_PUTC, sys_putc);
    syscall_register(&g_syscalls, SYS_EXEC, sys_exec);
}

export fn set_exec_target(load_addr: usize, user_sp: u64) -> void {
    g_load_addr = load_addr;
    g_user_sp = user_sp;
}

export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}
