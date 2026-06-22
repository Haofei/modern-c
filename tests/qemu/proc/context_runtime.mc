// Shared bring-up runtime for the context-switch demos — in PURE MC (replaces
// kernel/arch/riscv64/context_runtime.c). The callee-saved register save/restore (naked riscv
// asm), thread priming, a minimal UART, and the `.text.start` entry. The typed surface (Context,
// mc_switch_context/_vm, mc_thread_init) is declared in kernel/arch/riscv64/context.mc; each test
// provides its own `test_main`. This unit does NOT import context.mc (that would duplicate the
// `extern fn` decls of the very symbols it defines); the Context layout is mirrored locally.

const UART_THR: usize = 0x1000_0000;
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// Frame offsets inside Context (ra@0, sp@8, s0@16, s1..s11 @24..104; 14 x u64 = 112 bytes).
const C_RA: usize = 0;
const C_SP: usize = 8;
const C_S0: usize = 16;

extern fn test_main() -> void;

export fn putc_(c: u8) -> void {
    unsafe { raw.store<u8>(phys(UART_THR), c); }
}
export fn puts_(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        putc_(b);
        i = i + 1;
    }
}
export fn mc_halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

// Save the current callee-saved registers into *old (a0), load *new (a1), `ret` into new's ra.
#[naked]
export fn mc_switch_context() -> void {
    asm opaque volatile {
        "sd ra, 0(a0)\n sd sp, 8(a0)\n sd s0, 16(a0)\n sd s1, 24(a0)\n sd s2, 32(a0)\n sd s3, 40(a0)\n sd s4, 48(a0)\n sd s5, 56(a0)\n sd s6, 64(a0)\n sd s7, 72(a0)\n sd s8, 80(a0)\n sd s9, 88(a0)\n sd s10, 96(a0)\n sd s11, 104(a0)\n ld ra, 0(a1)\n ld sp, 8(a1)\n ld s0, 16(a1)\n ld s1, 24(a1)\n ld s2, 32(a1)\n ld s3, 40(a1)\n ld s4, 48(a1)\n ld s5, 56(a1)\n ld s6, 64(a1)\n ld s7, 72(a1)\n ld s8, 80(a1)\n ld s9, 88(a1)\n ld s10, 96(a1)\n ld s11, 104(a1)\n ret"
    }
}

// As mc_switch_context, but also load new_satp (a2) into satp + sfence.vma between save and restore.
#[naked]
export fn mc_switch_context_vm() -> void {
    asm opaque volatile {
        "sd ra, 0(a0)\n sd sp, 8(a0)\n sd s0, 16(a0)\n sd s1, 24(a0)\n sd s2, 32(a0)\n sd s3, 40(a0)\n sd s4, 48(a0)\n sd s5, 56(a0)\n sd s6, 64(a0)\n sd s7, 72(a0)\n sd s8, 80(a0)\n sd s9, 88(a0)\n sd s10, 96(a0)\n sd s11, 104(a0)\n csrw satp, a2\n sfence.vma\n ld ra, 0(a1)\n ld sp, 8(a1)\n ld s0, 16(a1)\n ld s1, 24(a1)\n ld s2, 32(a1)\n ld s3, 40(a1)\n ld s4, 48(a1)\n ld s5, 56(a1)\n ld s6, 64(a1)\n ld s7, 72(a1)\n ld s8, 80(a1)\n ld s9, 88(a1)\n ld s10, 96(a1)\n ld s11, 104(a1)\n ret"
    }
}

// Trampoline a fresh thread starts on: enable machine interrupts (it was switched in from inside
// an interrupt handler, MIE cleared), then jump to the real entry held in s0. Never returns.
#[naked]
export fn thread_trampoline() -> void {
    asm opaque volatile {
        "csrsi mstatus, 8\n jr s0"
    }
}

// Prime a fresh context: the first switch into it `ret`s to the trampoline (with the entry in s0)
// on the given stack. Callee-saved registers start zeroed.
export fn mc_thread_init(ctx: usize, stack_top: usize, entry: usize) -> void {
    var i: usize = 0;
    while i < 14 {
        unsafe { raw.store<u64>(phys(ctx + i * 8), 0); }
        i = i + 1;
    }
    unsafe {
        raw.store<u64>(phys(ctx + C_RA), (&thread_trampoline) as usize as u64);
        raw.store<u64>(phys(ctx + C_S0), entry as u64);
        raw.store<u64>(phys(ctx + C_SP), stack_top as u64);
    }
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. `.text.start` pins `_start` there; set the
// stack and call into the test's `test_main`; never returns.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
