// Kernel-side runtime that loads the CONFINED QuickJS agent (the qjs_agent U-mode ELF, embedded
// as app_image[]) into an ISOLATED Sv39 space and runs it in U-mode. Identical to app_runtime.c
// except the frame pool is sized for QuickJS (8 MiB heap arena + ~1.5 MiB engine + 512 KiB stack
// + page tables). The agent evaluates JS and prints via SYS_WRITE; the kernel is UNMAPPED in its
// address space — the MMU is the confinement boundary, and the agent reaches the kernel only via
// ecall (handled by app_run_demo.mc's syscall table, forwarded by usermode_runtime.c's trap).
#include <stdint.h>

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);

uint64_t app_build(uintptr_t image_base, uintptr_t image_len, uintptr_t region_base, uintptr_t region_len);
uint64_t app_entry(void);
uint32_t app_kernel_unmapped(uintptr_t kernel_va);

extern const unsigned char app_image[];
extern const unsigned int app_image_len;

// Weak default for the §0 ingress (SYS_READ): no embedded agent source. A test that serves an
// agent.js via SYS_READ links a STRONG mc_agent_source (its embedded JS) that overrides this.
__attribute__((weak)) uintptr_t mc_agent_source(uintptr_t *out_len) {
    *out_len = 0;
    return 0;
}

#define KERNEL_VA 0x80000000ULL

// Backing store for the agent's page tables + the per-page frames the loader allocates. QuickJS
// needs MiB: 8 MiB malloc arena + the engine's text/rodata/data + the 512 KiB user stack.
__attribute__((aligned(4096))) static uint8_t region[16u << 20]; // 16 MiB

__attribute__((used)) void test_main(void) {
    puts_("kernel: loading confined QuickJS agent\n");
    usermode_setup(); // trap vector (ecall dispatch + SYS_EXIT) + PMP

    uint64_t satp = app_build((uintptr_t)app_image, (uintptr_t)app_image_len,
                              (uintptr_t)region, (uintptr_t)sizeof(region));
    if (satp == 0) {
        puts_("APP-LOAD-FAIL\n");
        mc_halt();
    }

    if (app_kernel_unmapped((uintptr_t)KERNEL_VA))
        puts_("CONFINED: kernel unmapped in agent space\n");
    else
        puts_("LEAK: kernel mapped in agent space\n");

    puts_("kernel: entering confined QuickJS agent\n");
    uint64_t entry = app_entry();

    // Activate the agent's isolated address space, then drop to U-mode at the app entry. The user
    // sp is set by crt0's _start (la sp, __user_stack_top), so the value here is overwritten.
    __asm__ volatile("csrw satp, %0\n sfence.vma" ::"r"(satp) : "memory");
    enter_user((uintptr_t)entry, (uintptr_t)entry);
    mc_halt(); // not reached
}
