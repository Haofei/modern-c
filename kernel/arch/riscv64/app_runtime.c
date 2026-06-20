// Kernel-side runtime that loads a REAL confined app ELF (built by tools/user/build-app.sh,
// embedded as app_image[]) into an isolated U-mode address space and runs it. Mirrors the
// confined-agent bring-up, but instead of a hand-assembled single-segment ELF it loads a real
// multi-segment app via the MC `app_build` (elf_load_image), wires SYS_WRITE through
// page-table-aware uaccess, proves the kernel is unmapped in the agent's space, activates the
// agent's satp, and drops to U-mode at the app's entry. SYS_EXIT returns control to the
// kernel via the shared trap (usermode_runtime.c). The trap path + enter_user come from
// usermode_runtime.c; UART/_start/mc_halt from context_runtime.c.
#include <stdint.h>

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);

uint64_t app_build(uintptr_t image_base, uintptr_t image_len, uintptr_t region_base, uintptr_t region_len);
uint64_t app_entry(void);
uint32_t app_kernel_unmapped(uintptr_t kernel_va);

// The app ELF bytes, embedded by the harness (od/xxd of build-app.sh's output).
extern const unsigned char app_image[];
extern const unsigned int app_image_len;

// Weak default for the §0 ingress (SYS_READ): these apps embed no agent source.
__attribute__((weak)) uintptr_t mc_agent_source(uintptr_t *out_len) {
    *out_len = 0;
    return 0;
}

#define KERNEL_VA 0x80000000ULL

// Backing store for the agent's page tables + the per-page frames the loader allocates.
__attribute__((aligned(4096))) static uint8_t region[1u << 20]; // 1 MiB

__attribute__((used)) void test_main(void) {
    puts_("kernel: loading confined app\n");
    usermode_setup(); // trap vector (ecall dispatch + SYS_EXIT) + PMP

    uint64_t satp = app_build((uintptr_t)app_image, (uintptr_t)app_image_len,
                              (uintptr_t)region, (uintptr_t)sizeof(region));
    if (satp == 0) {
        puts_("APP-LOAD-FAIL\n");
        mc_halt();
    }

    if (app_kernel_unmapped((uintptr_t)KERNEL_VA))
        puts_("CONFINED: kernel unmapped in app space\n");
    else
        puts_("LEAK: kernel mapped in app space\n");

    puts_("kernel: entering confined app\n");
    uint64_t entry = app_entry();

    // Activate the agent's isolated address space (M-mode ignores satp, so the kernel keeps
    // running physically up to mret), then drop to U-mode at the app entry. The user sp is set
    // by crt0's _start (la sp, __user_stack_top), so the value passed here is overwritten
    // before any stack access — pass the entry VA, which is mapped.
    __asm__ volatile("csrw satp, %0\n sfence.vma" ::"r"(satp) : "memory");
    enter_user((uintptr_t)entry, (uintptr_t)entry);
    mc_halt(); // not reached
}
