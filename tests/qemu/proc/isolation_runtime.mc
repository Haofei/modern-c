// Bare-metal riscv64 runtime for the per-process-address-space scheduler — in PURE
// MC (no C). The all-MC replacement for kernel/arch/riscv64/isolation_runtime.c.
//
// M-mode builds the process table + page tables (MC isolation_setup), drops to
// S-mode, activates the kernel map, and runs the scheduler — whose context switch
// (mc_switch_context_vm) loads each process's satp. This unit provides the
// context-switch primitives (incl. the vm-aware one) the scheduler calls, the heap
// region, and the M->S boot drop.
//
// `mc_switch_context`/`mc_switch_context_vm`/`mc_thread_init` are declared `extern fn`
// by kernel/arch/riscv64/context.mc (imported transitively by the demo) and DEFINED
// here; so this is its own import-free linked unit, linked beside the demo object.
// The demo defines console_putc (via its imports), so this runtime writes the bare
// 16550 UART directly for its own banners.

import "tests/qemu/lib/test_report.mc";
const RT_FINISHER: usize = 0x0010_0000; // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;

// The callee-saved register frame, matching kernel/arch/riscv64/context.mc's
// `Context` (ra, sp, s0-s11 — 14 contiguous u64s).
struct Context {
    ra: u64,
    sp: u64,
    s0: u64, s1: u64, s2: u64, s3: u64, s4: u64, s5: u64,
    s6: u64, s7: u64, s8: u64, s9: u64, s10: u64, s11: u64,
}

fn halt() -> void {
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// Plain context switch (referenced by proc_yield/proc_exit; unused in this demo).
#[naked]
export fn mc_switch_context(old: *mut Context, new: *Context) -> void {
    asm opaque volatile {
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret"
    }
}

// Context switch that also swaps the address space (satp in a2).
#[naked]
export fn mc_switch_context_vm(old: *mut Context, new: *Context, new_satp: u64) -> void {
    asm opaque volatile {
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n csrw satp, a2\n sfence.vma\n ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret"
    }
}

// First-switch trampoline: jump to the entry parked in s0.
#[naked]
fn trampoline() -> void {
    asm opaque volatile {
        "jr s0"
    }
}

// Prime `ctx` so the first switch into it starts running `entry` on `stack_top`.
// Writes the 14 contiguous u64 slots (ra, sp, s0-s11) by raw store at their byte
// offsets — the Context layout matches kernel/arch/riscv64/context.mc.
export fn mc_thread_init(ctx: *mut Context, stack_top: usize, entry: fn() -> void) -> void {
    let base: usize = ctx as usize;
    unsafe {
        // Zero all 14 slots first (s0-s11 must start clear).
        var i: usize = 0;
        while i < 14 {
            raw.store<u64>(phys(base + i * 8), 0);
            i = i + 1;
        }
        raw.store<u64>(phys(base + 0), (&trampoline) as usize as u64); // ra
        raw.store<u64>(phys(base + 8), stack_top as u64);              // sp
        raw.store<u64>(phys(base + 16), entry as usize as u64);        // s0
    }
}

// The demo (tests/qemu/proc/isolation_demo.mc).
extern fn isolation_setup(region: usize, len: usize) -> void;
extern fn isolation_kernel_satp() -> u64;
extern fn isolation_run() -> u32;

// 512 KiB physical heap region.
global g_heap_region: [524288]u8;

export fn s_main() -> void {
    let ks: u64 = isolation_kernel_satp();
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw satp, %0\n sfence.vma"
                in("r") ks: u64
                clobber("memory")
            }
        }
    }
    if isolation_run() == 1 {
        uputs("ISO-OK\n");
    } else {
        uputs("ISO-BAD\n");
    }
    halt();
}

export fn m_main() -> void {
    uputs("isolation booting (M-mode)\n");
    let base: usize = (&g_heap_region[0]) as usize;
    isolation_setup(base, 524288);
    uputs("processes + page tables built, dropping to S-mode\n");
    let target: usize = (&s_main) as usize;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "li t0, 0xffff\n csrw medeleg, t0\n csrw mideleg, t0\n li t0, -1\n csrw pmpaddr0, t0\n li t0, 0x1f\n csrw pmpcfg0, t0\n li t0, 0x1800\n csrc mstatus, t0\n li t0, 0x800\n csrs mstatus, t0\n csrw mepc, %0\n mret"
                in("r") target: usize
                clobber("t0"), clobber("memory")
            }
        }
    }
    while true {}
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
