// Bare-metal riscv64 M-mode bring-up for the confined-agent-drives-capability-stack
// test — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/agent_confined_tool_runtime.c.
//
// Same isolation path as agent_confined_runtime.mc, but the agent ELF issues SYS_TOOL
// calls (instead of just printing): one benign write under /workspace and one
// forbidden write under /etc, both routed by the kernel through the capability front
// door. The kernel prints ">A<" for the allowed call and ">D<" for the denied one.
// `_start`/mc_halt come from context_runtime.c; the U-mode trap path + enter_user from
// usermode_runtime.c; the tree + agent authority from the MC tool demo.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const RT_VADDR: u32 = 0x4000_0000;      // must match AGENT_CODE_VA in the MC demo
const RT_KERNEL_VA: usize = 0x8000_0000;
const RT_PAGE: usize = 4096;
const RT_EH: usize = 64; // ELF header size
const RT_PH: usize = 56; // program header size
const RT_CODE: usize = 40; // 10 instructions

// Write one byte to the bare 16550 UART transmit register.
fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

// Write a NUL-terminated string over the bare UART.
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The shared U-mode trap bring-up (usermode_runtime.c).
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;

// The MC tool demo (tests/qemu/proc/agent_confined_tool_demo.mc).
extern fn elf_load_run(elf_base: usize, elf_len: usize, dst: usize) -> u64;
extern fn agent_confined_build(region_base: usize, region_len: usize, code_phys: usize, code_len: usize, stack_phys: usize, stack_len: usize) -> u64;
extern fn agent_code_va() -> u64;
extern fn agent_stack_top_va(stack_len: usize) -> u64;
extern fn agent_kernel_unmapped(kernel_va: usize) -> u32;

// In-memory ELF image: header + program header + code.
global g_user_elf: [160]u8; // RT_EH + RT_PH + RT_CODE
// Page-aligned landing/stack/heap regions: over-allocated by a page so the base can
// be rounded up to a 4 KiB boundary at runtime (MC has no align attribute).
global g_load_buf: [8192]u8;    // 4 KiB usable
global g_user_stack: [12288]u8; // 8 KiB usable
global g_heap_region: [266240]u8; // 256 KiB usable
const RT_STACK_LEN: usize = 8192;

// Round a base address up to the next 4 KiB page boundary.
fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}

// ----- little-endian byte writers into the in-memory ELF -----

fn elf_put_u8(off: usize, v: u8) -> void {
    let base: usize = (&g_user_elf) as usize;
    unsafe { raw.store<u8>(phys(base + off), v); }
}
fn elf_put_u16(off: usize, v: u16) -> void {
    elf_put_u8(off, v as u8);
    elf_put_u8(off + 1, (v >> 8) as u8);
}
fn elf_put_u32(off: usize, v: u32) -> void {
    var i: usize = 0;
    while i < 4 {
        elf_put_u8(off + i, (v >> ((8 * i) as u32)) as u8);
        i = i + 1;
    }
}
fn elf_put_u64(off: usize, v: u64) -> void {
    var i: usize = 0;
    while i < 8 {
        elf_put_u8(off + i, (v >> ((8 * i) as u32)) as u8);
        i = i + 1;
    }
}

// The agent: SYS_TOOL(write, /workspace); SYS_TOOL(write, /etc); SYS_EXIT.
// SYS_TOOL=5, args a0=tool_id (0=write), a1=path_id (0=workspace, 1=etc). SYS_EXIT=3.
fn build_elf() -> void {
    var i: usize = 0;
    while i < 160 {
        elf_put_u8(i, 0);
        i = i + 1;
    }
    elf_put_u8(0, 0x7f);
    elf_put_u8(1, 69); // 'E'
    elf_put_u8(2, 76); // 'L'
    elf_put_u8(3, 70); // 'F'
    elf_put_u8(4, 2);  // ELFCLASS64
    elf_put_u8(5, 1);  // little-endian
    elf_put_u64(24, RT_VADDR as u64);     // e_entry
    elf_put_u64(32, RT_EH as u64);        // e_phoff
    elf_put_u16(54, RT_PH as u16);        // e_phentsize
    elf_put_u16(56, 1);                   // e_phnum

    let ph: usize = RT_EH;
    elf_put_u32(ph + 0, 1);               // PT_LOAD
    elf_put_u32(ph + 4, 5);               // R|X
    elf_put_u64(ph + 8, (RT_EH + RT_PH) as u64); // p_offset
    elf_put_u64(ph + 16, RT_VADDR as u64);// p_vaddr
    elf_put_u64(ph + 32, RT_CODE as u64); // p_filesz
    elf_put_u64(ph + 40, RT_CODE as u64); // p_memsz

    let code: usize = RT_EH + RT_PH;
    elf_put_u32(code + 0,  0x0050_0893);  // li a7, 5   (SYS_TOOL)
    elf_put_u32(code + 4,  0x0000_0513);  // li a0, 0   (tool = write)
    elf_put_u32(code + 8,  0x0000_0593);  // li a1, 0   (path = workspace)
    elf_put_u32(code + 12, 0x0000_0073);  // ecall      -> benign, ALLOWED
    elf_put_u32(code + 16, 0x0050_0893);  // li a7, 5
    elf_put_u32(code + 20, 0x0000_0513);  // li a0, 0
    elf_put_u32(code + 24, 0x0010_0593);  // li a1, 1   (path = etc)
    elf_put_u32(code + 28, 0x0000_0073);  // ecall      -> forbidden, DENIED
    elf_put_u32(code + 32, 0x0030_0893);  // li a7, 3   (SYS_EXIT)
    elf_put_u32(code + 36, 0x0000_0073);  // ecall
}

// The loaded bytes are instructions: synchronize the instruction stream.
fn fence_i() -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "fence.i"
                clobber("memory")
            }
        }
    }
}

// Activate the agent's isolated address space, then enter_user drops to U-mode.
fn activate_satp(satp: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw satp, %0\n sfence.vma"
                in("t0") satp: u64,
                clobber("memory")
            }
        }
    }
}

export fn test_main() -> void {
    uputs("kernel: confined agent (capability tools) bring-up\n");
    build_elf();
    usermode_setup(); // also builds the tree + agent authority (syscall_setup)

    let elf_base: usize = (&g_user_elf) as usize;
    let load_buf: usize = page_align((&g_load_buf) as usize);
    let user_stack: usize = page_align((&g_user_stack) as usize);
    let heap_region: usize = page_align((&g_heap_region) as usize);

    let r: u64 = elf_load_run(elf_base, 160, load_buf);
    fence_i();

    let satp: u64 = agent_confined_build(heap_region, 262144, load_buf, RT_CODE, user_stack, RT_STACK_LEN);

    if agent_kernel_unmapped(RT_KERNEL_VA) == 1 {
        uputs("CONFINED: kernel unmapped in agent space\n");
    } else {
        uputs("LEAK: kernel mapped in agent space\n");
    }

    uputs("kernel: agent issuing capability tool calls\n");
    activate_satp(satp);
    enter_user(agent_code_va() as usize, agent_stack_top_va(RT_STACK_LEN) as usize);
    mc_halt();
}
