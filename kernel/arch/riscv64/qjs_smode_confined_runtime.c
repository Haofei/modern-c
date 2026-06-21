// S-mode bring-up for the CONFINED QuickJS agent under REAL OpenSBI (the M3a path).
//
// The S-mode analogue of qjs_confined_runtime.c: load the QuickJS U-mode ELF (embedded as
// app_image[]) into an ISOLATED Sv39 space and run it in U-mode. The differences from the
// M-mode path are exactly the S-mode ones:
//   - OpenSBI enters us in S-mode at 0x80200000 (a0=hartid, a1=dtb); console + power go
//     through the SBI ecall, not the bare UART/finisher;
//   - satp IS effective in S-mode, so the agent's space ALSO maps the kernel as a
//     supervisor-only gigapage (qjs_smode_build) — the S-mode trap handler keeps running
//     after satp activation, while the kernel stays unreachable from U (no PTE_U);
//   - the confinement proof is "kernel mapped but NOT user" (qjs_smode_kernel_not_user),
//     not "kernel unmapped".
// The trap vector + syscall dispatch + privilege drop are in smode_usermode_runtime.c; the
// loader + QuickJS ABI in app_run_demo.mc (both reused unchanged across M/S).
#include <stdint.h>

void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);

uint64_t qjs_smode_build(uintptr_t image_base, uintptr_t image_len, uintptr_t region_base, uintptr_t region_len);
uint32_t qjs_smode_kernel_not_user(uint64_t satp, uintptr_t kernel_va);
uint32_t app_build_status(void); // typed LoadError class (LS_*) of the last app_build
uint64_t app_entry(void);

// ---- SBI console + power (legacy SBI: putchar EID=1, shutdown EID=8) ----
static void sbi_putchar(char c) {
    register long a0 __asm__("a0") = (unsigned char)c;
    register long a7 __asm__("a7") = 1;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}
static void sbi_puts(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void sbi_shutdown(void) {
    register long a7 __asm__("a7") = 8;
    __asm__ volatile("ecall" : : "r"(a7) : "memory");
    for (;;) {}
}

static const char *load_status_str(uint32_t s) {
    switch (s) {
        case 1: return "APP-LOAD-FAIL: BadElf\n";
        case 2: return "APP-LOAD-FAIL: TooManyPages\n";
        case 3: return "APP-LOAD-FAIL: NoFrame\n";
        case 4: return "APP-LOAD-FAIL: BadSegment\n";
        default: return "APP-LOAD-FAIL: unknown\n";
    }
}

extern const unsigned char app_image[];
extern const unsigned int app_image_len;

// Weak default for the §0 ingress (SYS_READ): no embedded agent source. A test that serves
// an agent.js via SYS_READ links a STRONG mc_agent_source overriding this.
__attribute__((weak)) uintptr_t mc_agent_source(uintptr_t *out_len) {
    *out_len = 0;
    return 0;
}

#define KERNEL_VA 0x80000000ULL

// Backing store for the agent's page tables + per-page frames the loader allocates. QuickJS
// needs MiB: 8 MiB malloc arena + the engine's text/rodata/data + the 512 KiB user stack.
// Lives in .bss within the kernel's 0x8000_0000 gigapage (mapped supervisor-only).
__attribute__((aligned(4096))) static uint8_t region[16u << 20]; // 16 MiB

__attribute__((used)) void s_entry(void) {
    sbi_puts("kernel up in S-mode under OpenSBI: loading confined QuickJS agent\n");
    usermode_setup(); // S-mode trap vector (ecall dispatch + SYS_EXIT) + syscall table

    uint64_t satp = qjs_smode_build((uintptr_t)app_image, (uintptr_t)app_image_len,
                                    (uintptr_t)region, (uintptr_t)sizeof(region));
    if (satp == 0) {
        sbi_puts(load_status_str(app_build_status()));
        sbi_shutdown();
    }

    // Confinement proof (S-mode): the kernel is mapped (so the trap path survives satp) but
    // is NOT user-accessible — a direct kernel touch from U-mode would fault.
    if (qjs_smode_kernel_not_user(satp, (uintptr_t)KERNEL_VA))
        sbi_puts("CONFINED: kernel not user-accessible in agent space\n");
    else
        sbi_puts("LEAK: kernel user-accessible in agent space\n");

    sbi_puts("kernel: entering confined QuickJS agent\n");
    uint64_t entry = app_entry();

    // Activate the agent's isolated address space, then drop to U-mode at the app entry. The
    // user sp is set by crt0's _start (la sp, __user_stack_top), so the value here is
    // overwritten. In S-mode satp IS effective immediately; the kernel's supervisor gigapage
    // (added by qjs_smode_build) keeps this code + the trap path running.
    __asm__ volatile("csrw satp, %0\n sfence.vma" ::"r"(satp) : "memory");
    enter_user((uintptr_t)entry, (uintptr_t)entry);
    sbi_shutdown(); // not reached
}

// OpenSBI enters here in S-mode (a0=hartid, a1=dtb). Preserve a0/a1 across the stack setup
// (s_entry takes no args today, but the boot contract hands them in registers — keep them
// intact, matching smode_user_runtime.c / sbi_boot_runtime.c).
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
