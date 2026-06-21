// Bare-metal riscv64 M-mode context-switch-with-address-space runtime — in PURE MC
// (no C). The all-MC replacement for kernel/arch/riscv64/vmctx_runtime.c.
//
// A context switch that swaps the address space. `ctx_switch_vm` saves the old
// thread's callee-saved registers, loads the new thread's satp (+ sfence.vma), then
// loads its registers — so changing threads changes the active page table. Two S-mode
// threads each read the same VA and see their own frame, proving satp is part of the
// switched context (what a real scheduler does with proc_satp).
//
// The boot seam, bare-UART console, and the M->S privilege drop are shared MC
// (mmode_sdrop.mc); building the per-thread address spaces is the unchanged MC vmctx
// module (vmctx_demo.mc). The naked context switch + trampoline are local to this
// runtime (the C version's static mc_switch_context_vm/trampoline).

import "tests/qemu/mem/mmode_sdrop.mc";  // M->S privilege drop + satp activation
import "kernel/core/mmio_console.mc";    // put_str/put_hex over the bare 16550 UART
import "kernel/core/console.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;
const RT_TEST_VA: usize = 0xC000_0000;

// The vmctx demo (tests/qemu/mem/vmctx_demo.mc): builds two thread address spaces +
// the kernel/bootstrap mapping over the physical region; returns each thread's satp.
extern fn vmctx_setup(region_base: usize, region_len: usize) -> void;
extern fn vmctx_satp_a() -> u64;
extern fn vmctx_satp_b() -> u64;
extern fn vmctx_satp_kernel() -> u64;

// Callee-saved-register context frame: ra, sp, s0-s11 (14 words). Field order matches
// the byte offsets the naked switch loads/stores (ra=0, sp=8, s0=16, s1=24, ...).
struct Context {
    ra: u64, sp: u64,
    s0: u64, s1: u64, s2: u64, s3: u64, s4: u64, s5: u64,
    s6: u64, s7: u64, s8: u64, s9: u64, s10: u64, s11: u64,
}

// Prefixed to avoid colliding with the demo's named LLVM symbols (the LLVM backend
// emits module globals as external symbols; the demo already defines rt_satp_a/b/kernel).
global rt_boot_ctx: Context;
global rt_a_ctx: Context;
global rt_b_ctx: Context;
global rt_satp_a: u64;
global rt_satp_b: u64;
global rt_satp_kernel: u64;
global rt_stack_a: [8192]u8;
global rt_stack_b: [8192]u8;

// Naked address-space-switching context switch. Save *old (a0), switch satp to a2
// (+ sfence.vma), load *new (a1), and `ret` into the new thread's saved ra. The field
// offsets match the Context struct above.
#[naked]
fn ctx_switch_vm(old: *mut Context, next: *mut Context, new_satp: u64) -> void {
    asm opaque volatile {
        "sd ra, 0(a0)\n sd sp, 8(a0)\n sd s0, 16(a0)\n sd s1, 24(a0)\n sd s2, 32(a0)\n sd s3, 40(a0)\n sd s4, 48(a0)\n sd s5, 56(a0)\n sd s6, 64(a0)\n sd s7, 72(a0)\n sd s8, 80(a0)\n sd s9, 88(a0)\n sd s10, 96(a0)\n sd s11, 104(a0)\n csrw satp, a2\n sfence.vma\n ld ra, 0(a1)\n ld sp, 8(a1)\n ld s0, 16(a1)\n ld s1, 24(a1)\n ld s2, 32(a1)\n ld s3, 40(a1)\n ld s4, 48(a1)\n ld s5, 56(a1)\n ld s6, 64(a1)\n ld s7, 72(a1)\n ld s8, 80(a1)\n ld s9, 88(a1)\n ld s10, 96(a1)\n ld s11, 104(a1)\n ret"
    }
}

// Naked trampoline: the first switch into a fresh thread `ret`s here; jump to the
// entry point parked in s0 by ctx_init.
#[naked]
fn trampoline() -> void {
    asm opaque volatile {
        "jr s0"
    }
}

// Prime a fresh context: zero it, then park ra=trampoline (the first switch returns
// there), s0=entry (trampoline jumps to it), sp=stack_top.
fn ctx_init(ctx: *mut Context, stack_top: usize, entry: usize) -> void {
    ctx.ra = 0; ctx.sp = 0;
    ctx.s0 = 0; ctx.s1 = 0; ctx.s2 = 0; ctx.s3 = 0; ctx.s4 = 0; ctx.s5 = 0;
    ctx.s6 = 0; ctx.s7 = 0; ctx.s8 = 0; ctx.s9 = 0; ctx.s10 = 0; ctx.s11 = 0;
    ctx.ra = (&trampoline) as usize as u64;
    ctx.s0 = entry as u64;
    ctx.sp = stack_top as u64;
}

export fn thread_a() -> void {
    var v: u32 = 0;
    unsafe { v = raw.load<u32>(phys(RT_TEST_VA)); } // resolves in A's address space
    put_str("A sees ");
    put_hex(v as u64);
    console_putc(10);
    ctx_switch_vm(&rt_a_ctx, &rt_b_ctx, rt_satp_b); // hand off to B (its address space)
}

export fn thread_b() -> void {
    var v: u32 = 0;
    unsafe { v = raw.load<u32>(phys(RT_TEST_VA)); } // resolves in B's address space
    put_str("B sees ");
    put_hex(v as u64);
    console_putc(10);
    ctx_switch_vm(&rt_b_ctx, &rt_boot_ctx, rt_satp_kernel); // back to the bootstrap
}

// S-mode entry (reached via `mret`): turn on the kernel mapping, prime the two thread
// contexts, then switch into A; A hands to B, B returns here.
export fn s_main() -> void {
    rt_satp_kernel = vmctx_satp_kernel();
    rt_satp_a = vmctx_satp_a();
    rt_satp_b = vmctx_satp_b();
    activate_satp(rt_satp_kernel);

    ctx_init(&rt_a_ctx, (&rt_stack_a) as usize + 8192, (&thread_a) as usize);
    ctx_init(&rt_b_ctx, (&rt_stack_b) as usize + 8192, (&thread_b) as usize);

    put_str("bootstrap -> A\n");
    ctx_switch_vm(&rt_boot_ctx, &rt_a_ctx, rt_satp_a); // A runs, hands to B, B returns here
    put_str("VMCTX-OK\n");
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build the thread address spaces (MC), then drop to S-mode.
export fn m_main() -> void {
    put_str("vmctx booting (M-mode)\n");
    vmctx_setup((&rt_heap_region) as usize, 262144);
    put_str("thread address spaces built, dropping to S-mode\n");
    drop_to_smode((&s_main) as usize);
}

global rt_heap_region: [262144]u8;

// QEMU `-bios none` jumps to 0x80000000 in M-mode; `.text.start` pins `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
