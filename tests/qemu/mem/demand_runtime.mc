// Bare-metal riscv64 M-mode demand-paging runtime — in PURE MC (no C). M-mode builds
// the address space with the SAME existing MC `dp_setup` (kernel/core/demand), leaving a
// region unmapped, delegates traps + opens PMP, and `mret`s into S-mode with a page-fault
// trap vector installed. S-mode activates satp and touches the unmapped region: the store
// faults; the S-mode handler calls `dp_handle_fault` to map a page; `sret` retries the
// faulting instruction transparently — demand paging is live.
//
// Replaces demand_runtime.c: the boot seam, bare-UART console, the M->S privilege drop,
// AND the S-mode trap entry/dispatch are all pure MC now; the real work (build AS / map a
// page on fault) is the unchanged MC demand module.

import "kernel/core/demand.mc";          // dp_setup -> satp ; dp_handle_fault(fault_va)
import "tests/qemu/mem/mmode_sdrop.mc";  // M->S privilege drop + satp activation
import "kernel/core/mmio_console.mc";    // put_str over the bare 16550 UART
import "kernel/core/console.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;
const DEMAND_VA: usize = 0xD000_0000;

global g_heap_region: [262144]u8;
global g_satp: u64;
global g_faults: u32;

// S-mode trap dispatch (called from the naked vector with mcause/mtval-equivalent
// scause/stval). On a page fault (scause 12 instr / 13 load / 15 store) map the faulting
// page via the MC demand handler and fence; any other trap fails closed.
export fn s_trap_handler(scause: u64, stval: u64) -> void {
    if scause == 12 || scause == 13 || scause == 15 {
        g_faults = g_faults + 1;
        dp_handle_fault(stval as usize);
        unsafe { asm opaque volatile { "sfence.vma" clobber("memory") } }
    } else {
        put_str("UNEXPECTED-TRAP\n");
        unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
        while true {}
    }
}

// Naked S-mode trap vector. A fault arrives at an arbitrary instruction boundary, so save
// the full caller-saved frame, read scause/stval, dispatch, restore, and `sret` (the
// faulting instruction retries). Lives in `.text.mtrap` so virt.ld pins it to a 4-byte
// boundary (stvec encodes the trap mode in its low 2 bits; Direct mode = 0).
#[naked]
#[section(".text.mtrap")]
export fn s_trap() -> void {
    asm opaque volatile {
        "addi sp, sp, -128\n sd ra,0(sp)\n sd t0,8(sp)\n sd t1,16(sp)\n sd t2,24(sp)\n sd t3,32(sp)\n sd t4,40(sp)\n sd t5,48(sp)\n sd t6,56(sp)\n sd a0,64(sp)\n sd a1,72(sp)\n sd a2,80(sp)\n sd a3,88(sp)\n sd a4,96(sp)\n sd a5,104(sp)\n sd a6,112(sp)\n sd a7,120(sp)\n csrr a0, scause\n csrr a1, stval\n call s_trap_handler\n ld ra,0(sp)\n ld t0,8(sp)\n ld t1,16(sp)\n ld t2,24(sp)\n ld t3,32(sp)\n ld t4,40(sp)\n ld t5,48(sp)\n ld t6,56(sp)\n ld a0,64(sp)\n ld a1,72(sp)\n ld a2,80(sp)\n ld a3,88(sp)\n ld a4,96(sp)\n ld a5,104(sp)\n ld a6,112(sp)\n ld a7,120(sp)\n addi sp, sp, 128\n sret"
    }
}

// S-mode entry (reached via `mret`): install the trap vector, turn paging on, then touch
// the unmapped demand region. The first store faults -> handler maps -> retry stores.
export fn s_main() -> void {
    let vec: usize = (&s_trap) as usize;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw stvec, %0"
                in("r") vec: usize
                clobber("memory")
            }
        }
    }
    activate_satp(g_satp);
    var v: u32 = 0;
    unsafe {
        raw.store<u32>(phys(DEMAND_VA), 0xD00D_1234); // unmapped -> fault -> map -> retry
        v = raw.load<u32>(phys(DEMAND_VA));           // now mapped
    }
    put_str("DEMAND faults=");
    put_hex(g_faults as u64);
    put_str(" val=");
    put_hex(v as u64);
    console_putc(10);
    if g_faults >= 1 && v == 0xD00D_1234 {
        put_str("DEMAND-OK\n");
    } else {
        put_str("DEMAND-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build the AS (MC, region left unmapped), then drop to S-mode.
export fn m_main() -> void {
    put_str("demand booting (M-mode)\n");
    g_satp = dp_setup((&g_heap_region) as usize, 262144);
    put_str("demand: AS built, dropping to S-mode\n");
    drop_to_smode((&s_main) as usize);
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode; `.text.start` pins `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
