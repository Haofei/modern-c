// user/runtime/crt0_x86.c — the x86-64 userspace C runtime for an MC/QuickJS agent (M7).
//
// The x86-64 sibling of user/runtime/crt0.c. Two things only:
//   - mc_ecall: the single syscall primitive. The libc's I/O (user/libc/syscall_user.mc)
//     routes every syscall through this EXTERN. On x86-64 the convention matches the M6
//     kernel trap entry (kernel/arch/x86_64/user_runtime.c): RAX = number, RDI/RSI/RDX =
//     args, `int $0x80`, result in RAX.
//   - _start: the ELF entry. The elf_loader maps the in-image stack (.bss, R|W|U) and the
//     linker symbol __user_stack_top marks its top. Set RSP there, align the stack, call
//     `main`, then exit with main's return code via SYS_EXIT.
//
// Freestanding: no libc, no globals beyond the linker-defined stack symbol. Identical in
// SHAPE to the RISC-V crt0.c — only the ecall/_start asm is x86-specific (the one arch piece
// the M7 plan calls out on the user side).

#include <stdint.h>

// One syscall: RAX=number, RDI/RSI/RDX=args, `int $0x80`, result in RAX. Pins the registers
// the M6 kernel trap dispatcher reads from the saved frame (struct regs in user_runtime.c).
uint64_t mc_ecall(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2) {
    uint64_t ret;
    __asm__ volatile("int $0x80"
                     : "=a"(ret)
                     : "a"(number), "D"(a0), "S"(a1), "d"(a2)
                     : "rcx", "r11", "memory");
    return ret;
}

// The host entry point (examples/apps/qjs_host.c — `int main(void)`).
int main(void);

// SYS_EXIT = 3 (see user/abi.mc; the same ABI the RISC-V crt0.c uses). Keep in sync.
#define SYS_EXIT 3

// crt0: the ELF entry. __user_stack_top is defined by the link script (user_qjs_x86.ld) at the
// top of the app's in-image stack (a NOBITS region the loader maps R|W|U and zeroes). Set RSP,
// keep it 16-byte aligned at the call boundary (System V ABI), call main, then SYS_EXIT(main()).
__attribute__((naked, used, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "lea __user_stack_top(%%rip), %%rsp\n"
        "and $-16, %%rsp\n"      // 16-byte align the stack
        "xor %%rbp, %%rbp\n"     // terminate the frame chain
        "call main\n"            // int main(void) -> EAX
        "movslq %%eax, %%rdi\n"  // exit code = sign-extended main() return
        "mov %0, %%rax\n"        // SYS_EXIT
        "int $0x80\n"
        "1: hlt\n jmp 1b\n"
        : : "i"(SYS_EXIT) : "memory");
}
