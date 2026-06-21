// kernel/arch/aarch64/vm_runtime — the C boot + `vmmain` for the AArch64 paging proof.
//
// QEMU 'virt' with `-kernel` loads this flat image at RAM base 0x40000000 and (for cortex-a72)
// typically enters at EL1; if we find ourselves at EL2 we drop to EL1 via HCR_EL2 + an `eret`.
// We print over the PL011 UART @ 0x09000000, install a VBAR_EL1 exception vector (so a paging
// fault is DIAGNOSED with a marker + halt, not a silent loop), then:
//
//   1. set MAIR_EL1 (Attr0 = Normal WB, Attr1 = Device-nGnRE) + TCR_EL1 (T0SZ=16 => 48-bit VA,
//      4 KiB granule, inner/outer WB, inner-shareable; TTBR1/T1SZ left disabled);
//   2. call the MC `vm_arm_build`, which builds a FRESH page table (identity low RAM as 2 MiB
//      blocks + the UART page as Device + a translation-only sentinel VA) and software-walks it
//      (page_table_lookup) to assert the translation BEFORE the MMU turns on — that alone
//      satisfies ARM2's "software page-table walk" need;
//   3. load TTBR0_EL1 with the root, dsb/isb, enable the MMU (SCTLR_EL1.M=1 + C/I caches), isb
//      (the kernel stays mapped via the identity blocks, so the next fetch survives);
//   4. read the sentinel back THROUGH the test VA — reachable ONLY through the new tables'
//      translation — and compare to the known sentinel.
//
// Print ARM64-VM-OK iff the software walk AND the live readback both match; else ARM64-VM-BAD.
#include <stdint.h>

// Freestanding C runtime helpers the MC-emitted code may reference for struct init / copies.
void *memset(void *dst, int c, unsigned long n) {
    unsigned char *p = (unsigned char *)dst;
    for (unsigned long i = 0; i < n; i++) p[i] = (unsigned char)c;
    return dst;
}
void *memcpy(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

#define PL011 ((volatile uint32_t *)0x09000000UL)
static void putc_(char c) { *PL011 = (uint32_t)(unsigned char)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

static void halt_forever(void) { for (;;) __asm__ volatile("wfe"); }

// ---- minimal EL1 exception vector table (16 entries x 0x80 bytes) ----
// On any taken exception we print a marker + ESR_EL1/ELR_EL1/FAR_EL1 and halt, so a paging bug
// is diagnosed rather than silently looping. The table must be 2 KiB-aligned (VBAR_EL1).
__attribute__((used)) void arm_on_exception(uint64_t kind) {
    uint64_t esr, elr, far;
    __asm__ volatile("mrs %0, esr_el1" : "=r"(esr));
    __asm__ volatile("mrs %0, elr_el1" : "=r"(elr));
    __asm__ volatile("mrs %0, far_el1" : "=r"(far));
    puts_("\nARM64-VM-BAD exception kind="); puthex64(kind);
    puts_(" ESR="); puthex64(esr);
    puts_(" ELR="); puthex64(elr);
    puts_(" FAR="); puthex64(far); putc_('\n');
    halt_forever();
}

// Each vector entry: stash a kind id in x0, branch to a common trampoline. 0x80 bytes/entry.
__attribute__((naked, aligned(2048), used, section(".text.vectors")))
void arm_vectors(void) {
    __asm__ volatile(
        // --- Current EL with SP0 ---
        ".balign 0x80\n mov x0, #0\n b arm_exc_common\n"   // sync
        ".balign 0x80\n mov x0, #1\n b arm_exc_common\n"   // irq
        ".balign 0x80\n mov x0, #2\n b arm_exc_common\n"   // fiq
        ".balign 0x80\n mov x0, #3\n b arm_exc_common\n"   // serror
        // --- Current EL with SPx ---
        ".balign 0x80\n mov x0, #4\n b arm_exc_common\n"   // sync
        ".balign 0x80\n mov x0, #5\n b arm_exc_common\n"   // irq
        ".balign 0x80\n mov x0, #6\n b arm_exc_common\n"   // fiq
        ".balign 0x80\n mov x0, #7\n b arm_exc_common\n"   // serror
        // --- Lower EL using AArch64 ---
        ".balign 0x80\n mov x0, #8\n b arm_exc_common\n"
        ".balign 0x80\n mov x0, #9\n b arm_exc_common\n"
        ".balign 0x80\n mov x0, #10\n b arm_exc_common\n"
        ".balign 0x80\n mov x0, #11\n b arm_exc_common\n"
        // --- Lower EL using AArch32 ---
        ".balign 0x80\n mov x0, #12\n b arm_exc_common\n"
        ".balign 0x80\n mov x0, #13\n b arm_exc_common\n"
        ".balign 0x80\n mov x0, #14\n b arm_exc_common\n"
        ".balign 0x80\n mov x0, #15\n b arm_exc_common\n");
}

__attribute__((naked, used)) void arm_exc_common(void) {
    __asm__ volatile("bl arm_on_exception\n 1: wfe\n b 1b\n");
}

static void install_vbar(void) {
    extern void arm_vectors(void);
    uint64_t base = (uint64_t)(uintptr_t)&arm_vectors;
    __asm__ volatile("msr vbar_el1, %0\n isb\n" : : "r"(base));
}

// MC builds the table, writes TTBR0 + test frame phys through out-pointers, returns the
// software-walk verdict (1 = ok). Out-pointers (not a struct return) keep the FFI ABI simple
// and identical across MC's C and LLVM backends.
extern uint32_t vm_arm_build(uintptr_t region, uintptr_t len, uint64_t *out_ttbr0, uint64_t *out_test_phys);

// Page-table backing store: 4 MiB, 4 KiB-aligned, well within the identity-mapped low RAM.
__attribute__((aligned(4096))) static uint8_t heap_region[4 * 1024 * 1024];

#define TEST_VA 0x1000000000UL  /* 64 GiB — translation-only (matches vm_arm_demo.mc) */
#define TEST_VALUE 0xCAFEBABEu

static void config_mair_tcr(void) {
    // MAIR_EL1: Attr0 = 0xFF (Normal, WB non-transient RW-alloc, inner+outer),
    //           Attr1 = 0x04 (Device-nGnRE).
    uint64_t mair = (0xFFUL << 0) | (0x04UL << 8);
    __asm__ volatile("msr mair_el1, %0" : : "r"(mair));

    // TCR_EL1: T0SZ=16 (48-bit VA for TTBR0), 4 KiB granule (TG0=0b00), inner+outer WB
    // cacheable (IRGN0=ORGN0=0b01), inner-shareable (SH0=0b11). Disable TTBR1 walks
    // (EPD1=1). IPS=0b101 (48-bit PA). T1SZ left 0 but EPD1 disables the TTBR1 region.
    uint64_t tcr =
        (16UL << 0)    |   // T0SZ = 16
        (0UL  << 14)   |   // TG0 = 4 KiB
        (1UL  << 8)    |   // IRGN0 = WB
        (1UL  << 10)   |   // ORGN0 = WB
        (3UL  << 12)   |   // SH0 = inner shareable
        (1UL  << 23)   |   // EPD1 = 1 (no TTBR1 walks)
        (5UL  << 32);      // IPS = 48-bit PA
    __asm__ volatile("msr tcr_el1, %0" : : "r"(tcr));
    __asm__ volatile("isb");
}

static void enable_mmu(uint64_t ttbr0) {
    __asm__ volatile("msr ttbr0_el1, %0" : : "r"(ttbr0));
    __asm__ volatile("dsb ish\n isb\n");
    // Invalidate TLB for EL1 before turning translation on.
    __asm__ volatile("tlbi vmalle1\n dsb ish\n isb\n");
    uint64_t sctlr;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    sctlr |= (1UL << 0);   // M  = 1 (MMU enable)
    sctlr |= (1UL << 2);   // C  = 1 (data cache)
    sctlr |= (1UL << 12);  // I  = 1 (instruction cache)
    __asm__ volatile("msr sctlr_el1, %0\n isb\n" : : "r"(sctlr) : "memory");
}

// Called from _start once SP is set. Drops EL2->EL1 if needed, then runs the VM proof.
__attribute__((used)) void vmmain(void) {
    // Enable EL1/EL0 access to Advanced SIMD/FP (CPACR_EL1.FPEN = 0b11). The LLVM backend may
    // emit SIMD/FP instructions for struct init / large copies; without this they trap (ESR
    // EC=0x07). The C-backend path emits no FP but enabling it is harmless there.
    {
        uint64_t cpacr;
        __asm__ volatile("mrs %0, cpacr_el1" : "=r"(cpacr));
        cpacr |= (3UL << 20); // FPEN = 0b11: no trapping of FP/SIMD at EL0/EL1
        __asm__ volatile("msr cpacr_el1, %0\n isb\n" : : "r"(cpacr));
    }

    puts_("aarch64 VM demo boot\n");

    uint64_t cel;
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(cel));
    uint64_t el = (cel >> 2) & 3;
    puts_("vm: CurrentEL="); puthex64(el); putc_('\n');

    install_vbar();
    puts_("vm: VBAR_EL1 installed\n");

    config_mair_tcr();
    puts_("vm: MAIR/TCR configured\n");

    uint64_t ttbr0 = 0, test_phys = 0;
    uint32_t sw_ok = vm_arm_build((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region), &ttbr0, &test_phys);
    puts_("vm: table built, ttbr0="); puthex64(ttbr0);
    puts_(" test_phys="); puthex64(test_phys);
    puts_(" sw_ok="); puthex64((uint64_t)sw_ok); putc_('\n');

    if (sw_ok != 1) {
        puts_("ARM64-VM-BAD (software walk)\n");
        halt_forever();
    }

    enable_mmu(ttbr0);
    puts_("vm: MMU enabled (SCTLR_EL1.M=1)\n");

    // Read the sentinel back THROUGH the test VA — reachable only via translation.
    volatile uint32_t *p = (volatile uint32_t *)TEST_VA;
    uint32_t got = *p;
    puts_("vm: readback through TEST_VA "); puthex64((uint64_t)got); putc_('\n');

    if (got == TEST_VALUE) {
        puts_("ARM64-VM-OK\n");
    } else {
        puts_("ARM64-VM-BAD (readback)\n");
    }
    halt_forever();
}

// EL2->EL1 drop helper: if we boot at EL2, configure HCR_EL2 (EL1 is AArch64), set a sane
// SPSR_EL2 (EL1h, all interrupts masked), point ELR_EL2 at the EL1 continuation, and eret.
// Called only from _start. Returns normally if already at EL1.
__attribute__((naked, used, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "ldr x1, =_stack_top\n"
        "mov sp, x1\n"
        "mrs x0, CurrentEL\n"
        "lsr x0, x0, #2\n"
        "and x0, x0, #3\n"
        "cmp x0, #2\n"
        "b.ne 2f\n"
        // --- at EL2: drop to EL1 ---
        "mov x0, #(1 << 31)\n"     // HCR_EL2.RW = 1 (EL1 is AArch64)
        "msr hcr_el2, x0\n"
        "mov x0, #0x3c5\n"         // SPSR_EL2: D,A,I,F masked + mode EL1h (M[3:0]=0b0101)
        "msr spsr_el2, x0\n"
        "adr x0, 1f\n"
        "msr elr_el2, x0\n"
        "isb\n"
        "eret\n"
        "1:\n"
        "ldr x1, =_stack_top\n"    // re-establish SP at EL1 (SP_EL1 is a separate register)
        "mov sp, x1\n"
        "2:\n"
        "bl vmmain\n"
        "3: wfe\n b 3b\n");
}
