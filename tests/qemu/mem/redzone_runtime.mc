// Bare-metal M-mode runtime for the D2.4 redzone + stack-canary demo, in PURE MC.
// (Replaces kernel/arch/riscv64/redzone_runtime.c.)
//
// The redzone/canary check in redzone_demo.mc (via heap.mc / canary.mc) raises
// `unreachable` on corruption, which lowers to an illegal instruction. This runtime
// installs an M-mode trap vector — pinned 4-byte aligned via `.text.mtrap` so mtvec
// stays in Direct mode (low 2 bits 0; MC's default 2-byte function alignment would
// otherwise corrupt the MODE field and misvector every trap) — that catches the trap,
// prints DETECTED, and halts. That is the observable proof the corruption check fired:
// the clean path returns normally and never reaches the trap vector, so it never prints
// DETECTED. If a check FAILS to fire, `rt_scenario_run` returns and we print MISSED.

import "kernel/core/mmio_console.mc"; // put_str over the bare 16550 UART (console_putc)

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;
const POOL_BYTES: usize = 64 * 1024;

// Defined in the separately-linked redzone_demo.mc (the demo logic) and the per-scenario
// unit (redzone_scenario_{overflow,canary}.mc). Declared extern here so this unit is
// import-free w.r.t. them (no E_DUPLICATE_DECLARATION with their definitions).
extern fn redzone_clean(region: usize, len: usize) -> u32;
extern fn rt_scenario_run(region: usize, len: usize) -> void;

// A real writable backing pool for the kernel heap. Over-allocated by 64 so the base
// rounds up to a 64-byte boundary at runtime (MC has no global-alignment attribute).
global rz_pool: [POOL_BYTES + 64]u8;

fn rz_halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); } // QEMU SiFive test finisher -> exit
}

// Any trap here is the illegal instruction raised by the redzone/canary `unreachable`.
// Report it and halt — the observable proof the corruption check fired.
export fn on_trap() -> void {
    put_str("DETECTED\n");
    rz_halt();
}

// Naked M-mode trap vector, 4-byte aligned by `.text.mtrap`. `call on_trap` never
// returns (on_trap halts via the finisher); the trailing spin is belt-and-suspenders.
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "call on_trap\n 1: j 1b"
    }
}

export fn m_main() -> void {
    // Route all M-mode traps (illegal instruction from `unreachable`) to our vector.
    let vec: usize = (&trap_vector) as usize;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw mtvec, %0"
                in("t0") vec: usize
            }
        }
    }

    put_str("redzone demo booting (M-mode)\n");

    // 64-byte-align the pool base (the redzone allocator expects aligned regions).
    let raw_base: usize = (&rz_pool[0]) as usize;
    let bumped: usize = raw_base + 63;
    let mask: usize = ~(63 as usize);
    let base: usize = bumped & mask;

    // 1. Clean path: a redzoned alloc used in-bounds, checked and freed without a trap.
    let clean_ok: u32 = redzone_clean(base, POOL_BYTES);
    if clean_ok == 1 {
        put_str("D2.4-OK\n");
    } else {
        put_str("D2.4-BAD\n");
        rz_halt();
    }

    // 2. The scenario's real corruption — must trap into on_trap (-> DETECTED). If the
    //    check fails to fire, the call returns here and we print the MISSED marker.
    rt_scenario_run(base, POOL_BYTES);
    put_str("MISSED\n");
    rz_halt();
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
