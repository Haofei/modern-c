// Bring-up for the confined-agent-drives-capability-stack test. Same isolation
// path as agent_confined_runtime.c, but the agent ELF issues SYS_TOOL calls
// (instead of just printing): one benign write under /workspace and one forbidden
// write under /etc, both routed by the kernel through the capability front door.
// The kernel prints ">A<" for the allowed call and ">D<" for the denied one.
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

static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put_u32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put_u64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

#define VADDR 0x40000000ULL // must match AGENT_CODE_VA in the MC demo
#define KERNEL_VA 0x80000000ULL
#define EH 64
#define PH 56
#define CODE 40 // 10 instructions

static uint8_t user_elf[EH + PH + CODE];
__attribute__((aligned(4096))) static uint8_t load_buf[4096];
__attribute__((aligned(16))) static uint8_t user_stack[8192];
__attribute__((aligned(4096))) static uint8_t heap_region[262144];

// The agent: SYS_TOOL(write, /workspace); SYS_TOOL(write, /etc); SYS_EXIT.
// SYS_TOOL=5, args a0=tool_id (0=write), a1=path_id (0=workspace, 1=etc). SYS_EXIT=3.
static void build_elf(void) {
    for (unsigned i = 0; i < sizeof(user_elf); i++) user_elf[i] = 0;
    user_elf[0] = 0x7F; user_elf[1] = 'E'; user_elf[2] = 'L'; user_elf[3] = 'F';
    user_elf[4] = 2; user_elf[5] = 1;
    put_u64(&user_elf[24], VADDR);
    put_u64(&user_elf[32], EH);
    put_u16(&user_elf[54], PH);
    put_u16(&user_elf[56], 1);

    uint8_t *ph = &user_elf[EH];
    put_u32(&ph[0], 1);          // PT_LOAD
    put_u32(&ph[4], 5);          // R|X
    put_u64(&ph[8], EH + PH);    // p_offset
    put_u64(&ph[16], VADDR);     // p_vaddr
    put_u64(&ph[32], CODE);      // p_filesz
    put_u64(&ph[40], CODE);      // p_memsz

    uint8_t *code = &user_elf[EH + PH];
    put_u32(&code[0],  0x00500893); // li a7, 5   (SYS_TOOL)
    put_u32(&code[4],  0x00000513); // li a0, 0   (tool = write)
    put_u32(&code[8],  0x00000593); // li a1, 0   (path = workspace)
    put_u32(&code[12], 0x00000073); // ecall      -> benign, ALLOWED
    put_u32(&code[16], 0x00500893); // li a7, 5
    put_u32(&code[20], 0x00000513); // li a0, 0
    put_u32(&code[24], 0x00100593); // li a1, 1   (path = etc)
    put_u32(&code[28], 0x00000073); // ecall      -> forbidden, DENIED
    put_u32(&code[32], 0x00300893); // li a7, 3   (SYS_EXIT)
    put_u32(&code[36], 0x00000073); // ecall
}

__attribute__((used)) void test_main(void) {
    puts_("kernel: confined agent (capability tools) bring-up\n");
    build_elf();
    usermode_setup(); // also builds the tree + agent authority (syscall_setup)

    elf_load_run((uintptr_t)user_elf, (uintptr_t)sizeof(user_elf), (uintptr_t)load_buf);
    __asm__ volatile("fence.i");

    uint64_t satp = agent_confined_build((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region),
                                         (uintptr_t)load_buf, (uintptr_t)CODE,
                                         (uintptr_t)user_stack, (uintptr_t)sizeof(user_stack));

    if (agent_kernel_unmapped((uintptr_t)KERNEL_VA))
        puts_("CONFINED: kernel unmapped in agent space\n");
    else
        puts_("LEAK: kernel mapped in agent space\n");

    puts_("kernel: agent issuing capability tool calls\n");
    __asm__ volatile("csrw satp, %0\n sfence.vma" ::"r"(satp) : "memory");
    enter_user((uintptr_t)agent_code_va(), (uintptr_t)agent_stack_top_va((uintptr_t)sizeof(user_stack)));
    mc_halt();
}
