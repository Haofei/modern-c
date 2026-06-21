// Bare-metal riscv64 M-mode copy-on-write runtime — in PURE MC (no C). M-mode builds two
// address spaces sharing a read-only frame with the SAME existing MC `cow_setup`
// (kernel/core/cow), delegates traps + opens PMP, and `mret`s into S-mode with a page-fault
// vector installed. A store in the parent space faults (the page is RO+shared); the handler
// copies the frame and remaps it writable for the parent, then the store retries. The child
// space, read afterward, still sees the original — copy-on-write divergence.
//
// Replaces cow_runtime.c: the boot seam, bare-UART console, the M->S privilege drop, AND the
// S-mode trap entry/dispatch are all pure MC now; the real work (build two spaces / copy the
// frame on fault) is the unchanged MC cow module.

import "kernel/core/cow.mc";             // cow_setup ; cow_satp_parent/child ; cow_handle_fault ; COW_VA
import "tests/qemu/mem/mmode_sdrop.mc";  // M->S privilege drop + satp activation
import "kernel/core/mmio_console.mc";    // put_str over the bare 16550 UART
import "kernel/core/console.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;

global g_heap_region: [262144]u8;
global g_parent_satp: u64;
global g_child_satp: u64;

// S-mode trap dispatch. On a page fault (scause 12/13/15) copy + remap the COW page via the
// MC cow handler and fence; any other trap fails closed.
export fn s_trap_handler(scause: u64, stval: u64) -> void {
    if scause == 12 || scause == 13 || scause == 15 {
        cow_handle_fault(stval as usize);
        unsafe { asm opaque volatile { "sfence.vma" clobber("memory") } }
    } else {
        put_str("UNEXPECTED-TRAP\n");
        unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
        while true {}
    }
}

// Naked S-mode trap vector (see demand_runtime.mc for the frame layout rationale). Lives in
// `.text.mtrap` so virt.ld pins it to a 4-byte boundary (stvec Direct mode = 0).
#[naked]
#[section(".text.mtrap")]
export fn s_trap() -> void {
    asm opaque volatile {
        "addi sp, sp, -128\n sd ra,0(sp)\n sd t0,8(sp)\n sd t1,16(sp)\n sd t2,24(sp)\n sd t3,32(sp)\n sd t4,40(sp)\n sd t5,48(sp)\n sd t6,56(sp)\n sd a0,64(sp)\n sd a1,72(sp)\n sd a2,80(sp)\n sd a3,88(sp)\n sd a4,96(sp)\n sd a5,104(sp)\n sd a6,112(sp)\n sd a7,120(sp)\n csrr a0, scause\n csrr a1, stval\n call s_trap_handler\n ld ra,0(sp)\n ld t0,8(sp)\n ld t1,16(sp)\n ld t2,24(sp)\n ld t3,32(sp)\n ld t4,40(sp)\n ld t5,48(sp)\n ld t6,56(sp)\n ld a0,64(sp)\n ld a1,72(sp)\n ld a2,80(sp)\n ld a3,88(sp)\n ld a4,96(sp)\n ld a5,104(sp)\n ld a6,112(sp)\n ld a7,120(sp)\n addi sp, sp, 128\n sret"
    }
}

// S-mode entry (reached via `mret`): install the vector, then exercise COW divergence.
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
    // parent space: the write faults (RO+shared) -> COW -> private writable copy
    activate_satp(g_parent_satp);
    var pv: u32 = 0;
    unsafe {
        raw.store<u32>(phys(COW_VA), 0x2222_2222);
        pv = raw.load<u32>(phys(COW_VA));
    }
    // child space: must still observe the original shared value
    activate_satp(g_child_satp);
    var cv: u32 = 0;
    unsafe { cv = raw.load<u32>(phys(COW_VA)); }
    put_str("COW parent=");
    put_hex(pv as u64);
    put_str(" child=");
    put_hex(cv as u64);
    console_putc(10);
    if pv == 0x2222_2222 && cv == 0x1111_1111 {
        put_str("COW-OK\n");
    } else {
        put_str("COW-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build two spaces sharing a RO frame (MC), then drop to S-mode.
export fn m_main() -> void {
    put_str("cow booting (M-mode)\n");
    cow_setup((&g_heap_region) as usize, 262144);
    g_parent_satp = cow_satp_parent();
    g_child_satp = cow_satp_child();
    put_str("cow: two spaces sharing a RO frame, dropping to S-mode\n");
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
