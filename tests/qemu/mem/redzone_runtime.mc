// Bare-metal riscv64 M-mode runtime for the D2.4 redzone + stack-canary demo —
// in PURE MC (no C). The all-MC replacement for kernel/arch/riscv64/redzone_runtime.c.
//
// No paging is needed: we run in M-mode, hand the MC heap a real writable pool, and
// drive the demo entry points. The MC `unreachable` that the redzone/canary check
// raises on corruption lowers to `__builtin_trap()` — a riscv illegal instruction.
// We install an M-mode trap vector that catches it, prints a "DETECTED" marker, and
// halts via the QEMU test finisher. So the trap is observable and proves the
// redzone/canary check actually fired on a real out-of-bounds write / smashed frame:
// the clean path returns normally and never reaches the trap vector, so it never
// prints DETECTED.
//
// Two scenarios, selected at LINK time (the harness links exactly one scenario unit
// that DEFINES `rt_scenario`) so each produces a clean transcript:
//   overflow : clean alloc/use/free (prints D2.4-OK), then a REAL one-past-the-end
//              write into the trailing redzone is caught on free -> DETECTED
//   canary   : clean alloc/use/free (prints D2.4-OK), then a smashed stack guard is
//              caught by guard_check -> DETECTED
//
// The demo (tests/qemu/mem/redzone_demo.mc) does NOT define console_putc, so this
// runtime writes the bare 16550 UART directly for its own markers.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const RT_FINISHER: usize = 0x0010_0000; // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;

// A real, writable backing pool for the kernel heap (64 KiB).
global g_pool: [65536]u8;

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

fn halt() -> void {
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// The clean redzone path (tests/qemu/mem/redzone_demo.mc).
extern fn redzone_clean(region: usize, len: usize) -> u32;

// The active scenario, DEFINED by exactly one linked scenario unit
// (redzone_scenario_overflow.mc / redzone_scenario_canary.mc). It performs the real
// corruption that the trap vector must catch (-> DETECTED), and prints the *-MISSED
// marker if the check failed to fire. Receives the heap pool (region, len) for the
// heap-overflow scenario; the canary scenario ignores them.
extern fn rt_scenario(region: usize, len: usize) -> void;

// Any trap arriving here is the `__builtin_trap()` raised by the MC redzone/canary
// `unreachable` (an illegal instruction). Report it and halt — the observable proof
// that the corruption check fired.
export fn on_trap() -> void {
    uputs("DETECTED\n");
    halt();
}

// Naked M-mode trap vector. Route all M-mode traps to on_trap. Pinned to .text.mtrap
// so virt.ld aligns it to a 4-byte boundary (mtvec Direct mode needs base[1:0]=0).
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "call on_trap"
    }
}

export fn m_main() -> void {
    // Route all M-mode traps (illegal instruction from __builtin_trap) to our vector.
    unsafe {
        asm opaque volatile {
            "la t0, trap_vector\n csrw mtvec, t0"
            clobber("t0"), clobber("memory")
        }
    }

    uputs("redzone demo booting (M-mode)\n");

    // 1. Clean path: a redzoned alloc used in-bounds, checked and freed without a trap.
    let pool_base: usize = (&g_pool[0]) as usize;
    let r: u32 = redzone_clean(pool_base, 65536);
    if r == 1 {
        uputs("D2.4-OK\n"); // clean alloc/use/free with redzones intact
    } else {
        uputs("D2.4-BAD\n");
        halt();
    }

    // 2. The selected corruption scenario: must trap (-> DETECTED). If it returns,
    //    the check failed to fire and the scenario unit prints its *-MISSED marker.
    rt_scenario(pool_base, 65536);
    halt();
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. Pin `_start` there, set the
// stack, and call into m_main; never returns.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
