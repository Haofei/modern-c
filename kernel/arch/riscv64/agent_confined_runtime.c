// Bring-up for the confined-agent step-0 test. Builds a tiny in-memory ELF64
// whose single PT_LOAD segment is hand-assembled RV64 that prints a marker ("42")
// via syscalls and exits, then:
//   1. loads the segment into a physical landing frame (elf_load_run);
//   2. asks the MC layer to build an ISOLATED Sv39 address space that maps ONLY
//      the agent's code (U|R|X) and stack (U|R|W) — NOT the kernel;
//   3. proves confinement structurally (kernel VA unmapped, code page user-only);
//   4. activates that satp and drops to U-mode at the agent's VA.
// Because the agent's code VA (0x4000_0000) is valid ONLY through its page table,
// the marker printing at all is itself evidence the satp activated and the agent
// ran translated inside its isolated space. UART/_start come from
// context_runtime.c; the U-mode trap path + enter_user from usermode_runtime.c;
// the syscall table from the MC syscall demo.
#include <stdint.h>
#include <stddef.h>

void puts_(const char *s);
void mc_halt(void);
void usermode_setup(void);
void enter_user(uintptr_t entry, uintptr_t user_sp);
uint64_t elf_load_run(uintptr_t elf_base, uintptr_t elf_len, uintptr_t dst);

uint64_t agent_confined_build(uintptr_t region_base, uintptr_t region_len,
                              uintptr_t code_phys, uintptr_t code_len,
                              uintptr_t stack_phys, uintptr_t stack_len);
uint64_t agent_code_va(void);
uint64_t agent_stack_top_va(uintptr_t stack_len);
uint32_t agent_kernel_unmapped(uintptr_t kernel_va);
uint32_t agent_code_is_user(void);

static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put_u32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put_u64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

#define VADDR 0x40000000ULL // must match AGENT_CODE_VA in agent_confined_demo.mc
#define KERNEL_VA 0x80000000ULL
#define EH 64
#define PH 56
#define CODE 28 // 7 instructions

static uint8_t user_elf[EH + PH + CODE];
__attribute__((aligned(4096))) static uint8_t load_buf[4096];     // segment landing zone (exec in U)
__attribute__((aligned(16))) static uint8_t user_stack[8192];     // the agent's user stack frames
__attribute__((aligned(4096))) static uint8_t heap_region[262144]; // page tables for the agent's space

// A user program: SYS_PUTC '4'; SYS_PUTC '2'; SYS_EXIT. (SYS_PUTC=2, SYS_EXIT=3.)
static void build_elf(void) {
    for (unsigned i = 0; i < sizeof(user_elf); i++) user_elf[i] = 0;
    user_elf[0] = 0x7F; user_elf[1] = 'E'; user_elf[2] = 'L'; user_elf[3] = 'F';
    user_elf[4] = 2; user_elf[5] = 1; // ELFCLASS64, little-endian
    put_u64(&user_elf[24], VADDR);    // e_entry
    put_u64(&user_elf[32], EH);       // e_phoff
    put_u16(&user_elf[54], PH);       // e_phentsize
    put_u16(&user_elf[56], 1);        // e_phnum

    uint8_t *ph = &user_elf[EH];
    put_u32(&ph[0], 1);               // p_type = PT_LOAD
    put_u32(&ph[4], 5);               // p_flags = R|X
    put_u64(&ph[8], EH + PH);         // p_offset (code follows the program header)
    put_u64(&ph[16], VADDR);          // p_vaddr (== entry, so entry offset is 0)
    put_u64(&ph[32], CODE);           // p_filesz
    put_u64(&ph[40], CODE);           // p_memsz

    uint8_t *code = &user_elf[EH + PH];
    put_u32(&code[0],  0x00200893);   // li a7, 2     (SYS_PUTC)
    put_u32(&code[4],  0x03400513);   // li a0, '4'
    put_u32(&code[8],  0x00000073);   // ecall
    put_u32(&code[12], 0x03200513);   // li a0, '2'
    put_u32(&code[16], 0x00000073);   // ecall
    put_u32(&code[20], 0x00300893);   // li a7, 3     (SYS_EXIT)
    put_u32(&code[24], 0x00000073);   // ecall
}

__attribute__((used)) void test_main(void) {
    puts_("kernel: confined agent bring-up\n");
    build_elf();
    usermode_setup();

    // Load the agent's segment into a physical frame; the agent will run it
    // through its OWN page table at AGENT_CODE_VA, not at this physical address.
    elf_load_run((uintptr_t)user_elf, (uintptr_t)sizeof(user_elf), (uintptr_t)load_buf);
    __asm__ volatile("fence.i"); // the loaded bytes are instructions

    uint64_t satp = agent_confined_build((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region),
                                         (uintptr_t)load_buf, (uintptr_t)CODE,
                                         (uintptr_t)user_stack, (uintptr_t)sizeof(user_stack));

    // Prove confinement BEFORE handing control to the agent.
    if (agent_kernel_unmapped((uintptr_t)KERNEL_VA))
        puts_("CONFINED: kernel unmapped in agent space\n");
    else
        puts_("LEAK: kernel mapped in agent space\n");
    if (agent_code_is_user())
        puts_("CONFINED: agent code is U-only\n");
    else
        puts_("LEAK: agent code not user\n");

    puts_("kernel: entering confined U-mode agent\n");
    // Activate the agent's isolated address space, then drop to U-mode at its VA.
    // (M-mode ignores satp, so the kernel keeps running physically up to mret.)
    __asm__ volatile("csrw satp, %0\n sfence.vma" ::"r"(satp) : "memory");
    enter_user((uintptr_t)agent_code_va(), (uintptr_t)agent_stack_top_va((uintptr_t)sizeof(user_stack)));
    mc_halt(); // not reached
}
