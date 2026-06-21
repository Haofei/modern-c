// user/runtime/crt0_aarch64.c — the AArch64 userspace C runtime for an MC/QuickJS agent (M9).
//
// The AArch64 sibling of user/runtime/crt0_x86.c (M7) and user/runtime/crt0.c (RISC-V). Two
// things only:
//   - mc_ecall: the single syscall primitive. The libc's I/O (user/libc/syscall_user.mc) routes
//     every syscall through this EXTERN. On AArch64 the convention matches the M8 kernel EL1 SVC
//     dispatcher (kernel/arch/aarch64/user_runtime.c + qjs_user_runtime.c): x8 = number,
//     x0/x1/x2 = args, `svc #0`, result in x0.
//   - _start: the ELF entry. The elf_loader maps the in-image stack (.bss, EL0 R|W) and the
//     linker symbol __user_stack_top marks its top. Set SP there, align the stack, call `main`,
//     then exit with main's return code via SYS_EXIT.
//
// Freestanding: no libc, no globals beyond the linker-defined stack symbol. Identical in SHAPE
// to the RISC-V / x86 crt0 — only the svc/_start asm is AArch64-specific (the one arch piece the
// M9 plan calls out on the user side).

#include <stdint.h>

// One syscall: x8 = number, x0/x1/x2 = args, `svc #0`, result in x0. Pins the registers the M8/M9
// kernel SVC dispatcher reads from the saved trapframe (struct trapframe in the kernel runtime).
uint64_t mc_ecall(uint64_t number, uint64_t a0, uint64_t a1, uint64_t a2) {
    register uint64_t x8 asm("x8") = number;
    register uint64_t x0 asm("x0") = a0;
    register uint64_t x1 asm("x1") = a1;
    register uint64_t x2 asm("x2") = a2;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2)
                     : "memory");
    return x0;
}

// The host entry point (examples/apps/qjs_host.c — `int main(void)`).
int main(void);

// SYS_EXIT = 3 (see user/abi.mc; the same ABI the RISC-V/x86 crt0 use). The abi-consistency
// gate (tools/check/abi-consistency-test.sh) fails the build if this drifts from abi.mc.
#define SYS_EXIT 3
// Stringify so the `svc` immediate below is the SAME macro, not a second hardcoded literal.
#define MC_STR_(x) #x
#define MC_STR(x) MC_STR_(x)

// crt0: the ELF entry. __user_stack_top is defined by the link script (user_qjs_aarch64.ld) at
// the top of the app's in-image stack (a NOBITS region the loader maps EL0 R|W and zeroes). Set
// SP, keep it 16-byte aligned (AAPCS64), call main, then SYS_EXIT(main()).
__attribute__((naked, used, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "ldr x0, =__user_stack_top\n"
        "and x0, x0, #-16\n"     // 16-byte align the stack (AAPCS64); SP can't be an AND operand
        "mov sp, x0\n"           // SP_EL0 = top of the loader-mapped user stack
        "mov x29, #0\n"          // terminate the frame chain
        "mov x30, #0\n"          // terminate the return chain
        "bl main\n"              // int main(void) -> w0
        "sxtw x0, w0\n"          // exit code = sign-extended main() return
        "mov x8, #" MC_STR(SYS_EXIT) "\n" // SYS_EXIT (stringified from the macro above)
        "svc #0\n"
        "1: wfe\n b 1b\n");
}
