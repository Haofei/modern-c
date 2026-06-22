// Bare-metal riscv64 M-mode -> S-mode MMU crash-containment runtime — in PURE MC
// (no C). The all-MC replacement for kernel/arch/riscv64/contain_runtime.c.
//
// A buggy "server" dereferences an unmapped address. Instead of mapping it (demand
// paging) or panicking, the S-mode fault handler CONTAINS the fault — it redirects
// past the offending task to a recovery path (the equivalent of killing the faulting
// server), and the system keeps running. Reuses kernel/core/demand.mc's address space
// (dp_setup, linked beside this object) and the shared M->S privilege drop / satp
// activation (tests/qemu/mem/mmode_sdrop.mc) — which avoids open-coding `li t0` (a hard
// t0 clobber the C backend's clang rejects).
//
// The contain demo under test IS kernel/core/demand.mc (compiled as the sibling object,
// importing console.mc -> defining console_putc/put_str), so this runtime must NOT import
// console.mc; it writes the bare 16550 UART directly for diagnostics.

import "tests/qemu/lib/test_report.mc";
import "tests/qemu/mem/mmode_sdrop.mc"; // drop_to_smode + activate_satp (no console import)

const RT_FINISHER: usize = 0x0010_0000;  // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;
const RT_BAD_VA: usize = 0xD000_0000;

// kernel/core/demand.mc: build the address space (kernel mapped; region unmapped).
extern fn dp_setup(region_base: usize, region_len: usize) -> u64;

// 256 KiB backing store for the demand-paging address space.
global g_heap_region: [262144]u8;
global g_satp: u64 = 0;
global g_contained: atomic<u32> = atomic.init(0);

// The recovery path the handler redirects to: the faulting server is gone; carry on.
export fn recovery() -> void {
    if g_contained.load(.acquire) == 1 {
        uputs("CONTAINED-OK\n");
    } else {
        uputs("CONTAIN-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {
    }
}

// S-mode trap handler. A load/store/instruction page fault (scause 12/13/15) is
// contained: redirect sepc past the faulting instruction to recovery (kill the
// server). Anything else fails closed.
export fn s_trap_handler(scause: u64, stval: u64) -> void {
    let _ignore: u64 = stval;
    if scause == 12 || scause == 13 || scause == 15 {
        g_contained.store(1, .release);
        let target: usize = (&recovery) as usize;
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile {
                    "csrw sepc, %0"
                    in("r") target: usize,
                    clobber("memory")
                }
            }
        }
    } else {
        uputs("UNEXPECTED-TRAP\n");
        unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
        while true {
        }
    }
}

#[naked]
#[section(".text.mtrap")]
export fn s_trap() -> void {
    asm opaque volatile {
        "addi sp, sp, -128\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n csrr a0, scause\n csrr a1, stval\n call s_trap_handler\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n addi sp, sp, 128\n sret"
    }
}

export fn buggy_server() -> void {
    unsafe {
        raw.store<u32>(phys(RT_BAD_VA), 0xDEAD); // unmapped -> fault -> contained
    }
    uputs("CONTAIN-BAD\n"); // must not reach here
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {
    }
}

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
    buggy_server();
    while true {
    }
}

export fn m_main() -> void {
    uputs("contain booting (M-mode)\n");
    g_satp = dp_setup((&g_heap_region) as usize, 262144);
    drop_to_smode((&s_main) as usize);
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
