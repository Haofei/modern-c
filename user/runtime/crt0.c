// user/runtime/crt0.c — the userspace C runtime for an MC app (Phase 1 of the QuickJS
// agent plan). Two things only:
//   - mc_ecall: the single syscall primitive. MC's `asm precise` uses generic register
//     constraints and cannot pin the RISC-V syscall ABI registers (a7=number, a0..a2=args),
//     so the ecall lives here in C where the registers can be pinned. user/sys.mc's wrappers
//     call this.
//   - _start: the ELF entry. Sets the user stack (mapped R|W|U by the loader from the app's
//     bss), calls `main`, then exits with main's return code via SYS_EXIT.
//
// Freestanding: no libc, no globals beyond the linker-defined stack symbol.

#include <stdint.h>

// One syscall: a7=number, a0..a2=args, `ecall`, result in a0.
uint64_t mc_ecall(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2) {
    register uint64_t r_a7 asm("a7") = number;
    register uint64_t r_a0 asm("a0") = a0;
    register uint64_t r_a1 asm("a1") = a1;
    register uint64_t r_a2 asm("a2") = a2;
    asm volatile("ecall"
                 : "+r"(r_a0)
                 : "r"(r_a7), "r"(r_a1), "r"(r_a2)
                 : "memory");
    return r_a0;
}

// The MC entry point (an `export fn main() -> i32`).
int32_t main(void);

// SYS_EXIT = 1 (see user/abi.mc). Keep in sync.
#define SYS_EXIT 1

// crt0: the ELF entry. __user_stack_top is defined by user/runtime/user.ld at the top of
// the app's in-image stack (a NOBITS region the loader maps R|W|U and zeroes).
__attribute__((naked, used, section(".text.start"))) void _start(void) {
    asm volatile(
        "la sp, __user_stack_top\n" // user stack (mapped by the loader from .bss)
        "call main\n"               // int32_t main(void) -> a0
        "li a7, %0\n"               // SYS_EXIT
        "ecall\n"                   // exit(main's return code in a0)
        "1: j 1b\n" ::"i"(SYS_EXIT));
}
