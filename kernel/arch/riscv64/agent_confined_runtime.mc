// Bare-metal riscv64 M-mode bring-up for the confined-agent step-0 test — in PURE
// MC (no C). The all-MC replacement for kernel/arch/riscv64/agent_confined_runtime.c.
//
// Builds a tiny in-memory ELF64 whose single PT_LOAD segment is hand-assembled RV64
// that prints a marker ("42") via syscalls and exits, then:
//   1. loads the segment into a physical landing frame (elf_load_run);
//   2. asks the MC layer to build an ISOLATED Sv39 address space that maps ONLY the
//      agent's code (U|R|X) and stack (U|R|W) — NOT the kernel;
//   3. proves confinement structurally (kernel VA unmapped, code page user-only);
//   4. activates that satp and drops to U-mode at the agent's VA.
// Because the agent's code VA (0x4000_0000) is valid ONLY through its page table, the
// marker printing at all is itself evidence the satp activated and the agent ran
// translated inside its isolated space. `_start`/mc_halt come from context_runtime.c;
// the U-mode trap path + enter_user from usermode_runtime.c; the syscall table from
// the MC confined demo. Diagnostics go out the bare 16550 UART directly.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const RT_VADDR: u32 = 0x4000_0000;      // must match AGENT_CODE_VA in the MC demo
const RT_KERNEL_VA: usize = 0x8000_0000;
const RT_PAGE: usize = 4096;
const RT_EH: usize = 64; // ELF header size
const RT_PH: usize = 56; // program header size
const RT_CODE: usize = 28; // 7 instructions

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

// The shared U-mode trap bring-up (usermode_runtime.c): install the trap vector
// (ecall dispatch + SYS_EXIT) + PMP, then drop to U-mode at `entry` with `user_sp`.
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;

// The MC confined demo (tests/qemu/proc/agent_confined_demo.mc).
extern fn elf_load_run(elf_base: usize, elf_len: usize, dst: usize) -> u64;
extern fn agent_confined_build(region_base: usize, region_len: usize, code_phys: usize, code_len: usize, stack_phys: usize, stack_len: usize) -> u64;
extern fn agent_code_va() -> u64;
extern fn agent_stack_top_va(stack_len: usize) -> u64;
extern fn agent_kernel_unmapped(kernel_va: usize) -> u32;
extern fn agent_code_is_user() -> u32;

// In-memory ELF image: header + program header + code.
global g_user_elf: [148]u8; // RT_EH + RT_PH + RT_CODE
// Page-aligned landing/stack/heap regions: over-allocated by a page so the base can
// be rounded up to a 4 KiB boundary at runtime (MC has no align attribute).
global g_load_buf: [8192]u8;    // segment landing zone (exec in U); 4 KiB usable
global g_user_stack: [12288]u8; // the agent's user stack frames; 8 KiB usable
global g_heap_region: [266240]u8; // page tables for the agent's space; 256 KiB usable
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

// A user program: SYS_PUTC '4'; SYS_PUTC '2'; SYS_EXIT. (SYS_PUTC=2, SYS_EXIT=3.)
fn build_elf() -> void {
    var i: usize = 0;
    while i < 148 {
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
    elf_put_u32(ph + 0, 1);               // p_type = PT_LOAD
    elf_put_u32(ph + 4, 5);               // p_flags = R|X
    elf_put_u64(ph + 8, (RT_EH + RT_PH) as u64); // p_offset (code follows the program header)
    elf_put_u64(ph + 16, RT_VADDR as u64);// p_vaddr (== entry, so entry offset is 0)
    elf_put_u64(ph + 32, RT_CODE as u64); // p_filesz
    elf_put_u64(ph + 40, RT_CODE as u64); // p_memsz

    let code: usize = RT_EH + RT_PH;
    elf_put_u32(code + 0,  0x0020_0893);  // li a7, 2     (SYS_PUTC)
    elf_put_u32(code + 4,  0x0340_0513);  // li a0, '4'
    elf_put_u32(code + 8,  0x0000_0073);  // ecall
    elf_put_u32(code + 12, 0x0320_0513);  // li a0, '2'
    elf_put_u32(code + 16, 0x0000_0073);  // ecall
    elf_put_u32(code + 20, 0x0030_0893);  // li a7, 3     (SYS_EXIT)
    elf_put_u32(code + 24, 0x0000_0073);  // ecall
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

// Activate the agent's isolated address space. M-mode ignores satp for its own
// fetches, so the kernel keeps running physically up to `mret` (enter_user); the
// satp takes effect for the U-mode agent. sfence.vma flushes stale TLB entries.
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
    uputs("kernel: confined agent bring-up\n");
    build_elf();
    usermode_setup();

    let elf_base: usize = (&g_user_elf) as usize;
    let load_buf: usize = page_align((&g_load_buf) as usize);
    let user_stack: usize = page_align((&g_user_stack) as usize);
    let heap_region: usize = page_align((&g_heap_region) as usize);

    // Load the agent's segment into a physical frame; the agent will run it through
    // its OWN page table at AGENT_CODE_VA, not at this physical address.
    let r: u64 = elf_load_run(elf_base, 148, load_buf);
    fence_i();

    let satp: u64 = agent_confined_build(heap_region, 262144, load_buf, RT_CODE, user_stack, RT_STACK_LEN);

    // Prove confinement BEFORE handing control to the agent.
    if agent_kernel_unmapped(RT_KERNEL_VA) == 1 {
        uputs("CONFINED: kernel unmapped in agent space\n");
    } else {
        uputs("LEAK: kernel mapped in agent space\n");
    }
    if agent_code_is_user() == 1 {
        uputs("CONFINED: agent code is U-only\n");
    } else {
        uputs("LEAK: agent code not user\n");
    }

    uputs("kernel: entering confined U-mode agent\n");
    // Activate the agent's isolated address space, then drop to U-mode at its VA.
    activate_satp(satp);
    enter_user(agent_code_va() as usize, agent_stack_top_va(RT_STACK_LEN) as usize);
    mc_halt(); // not reached
}
